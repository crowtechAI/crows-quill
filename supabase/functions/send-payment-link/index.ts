// Creates a Stripe Checkout link for the outstanding deposit or balance on a
// commission, emails it to the client (if RESEND_API_KEY is set), and marks
// it as sent. Called by the studio dashboard — requires an authenticated
// (artist) session; see supabase/config.toml [functions.send-payment-link].
import { createClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17";

// The dashboard calls this from the browser, so the CORS preflight (OPTIONS)
// must succeed and every response must carry these headers.
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    // Read secrets per request so a missing one gives a readable error
    // instead of crashing the function at boot.
    const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
    if (!stripeKey) return json({ error: "STRIPE_SECRET_KEY is not set on the function" }, 500);
    const siteUrl = Deno.env.get("SITE_URL");
    if (!siteUrl) return json({ error: "SITE_URL is not set on the function" }, 500);

    const stripe = new Stripe(stripeKey, { apiVersion: "2024-06-20" });
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { commission_id } = await req.json();
    if (!commission_id) return json({ error: "commission_id required" }, 400);

    const { data: c, error } = await admin
      .from("commissions")
      .select("*, client:clients(*)")
      .eq("id", commission_id)
      .single();
    if (error || !c) return json({ error: "Commission not found" }, 404);

    const payingBalance = c.deposit_paid && !c.balance_paid;
    const amount = payingBalance ? (c.total_price - c.deposit_amount) : c.deposit_amount;
    const label = payingBalance ? "Balance payment" : "Deposit";
    if (!amount || amount <= 0) {
      return json({ error: `No ${label.toLowerCase()} amount set on this commission` }, 400);
    }

    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      customer_email: c.client?.email || undefined,
      line_items: [{
        price_data: {
          currency: "gbp",
          unit_amount: Math.round(amount * 100),
          product_data: { name: `The Crow's Quill — ${label}` },
        },
        quantity: 1,
      }],
      metadata: { commission_id: c.id, payment_kind: payingBalance ? "balance" : "deposit" },
      success_url: `${siteUrl}/site/?paid=1`,
      cancel_url: `${siteUrl}/site/?cancelled=1`,
    });

    await admin.from("commissions").update({
      stripe_checkout_session_id: session.id,
      deposit_link_sent_at: new Date().toISOString(),
    }).eq("id", commission_id);

    // Email is best-effort: if it fails the link is still returned so the
    // artist can copy it and send it manually.
    let emailed = false;
    let emailError: string | undefined;
    const resendKey = Deno.env.get("RESEND_API_KEY");
    if (resendKey && c.client?.email) {
      try {
        const r = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            from: Deno.env.get("EMAIL_FROM") ?? "studio@crowsquill.art",
            to: c.client.email,
            subject: `The Crow's Quill — ${label} link`,
            html: `<p>Hi ${escapeHtml(c.client.name ?? "there")},</p><p>Here's your secure ${label.toLowerCase()} link: <a href="${session.url}">${session.url}</a></p>`,
          }),
        });
        emailed = r.ok;
        if (!r.ok) emailError = `Resend ${r.status}: ${(await r.text()).slice(0, 200)}`;
      } catch (e) {
        emailError = String(e);
      }
    } else if (!resendKey) {
      emailError = "RESEND_API_KEY not set";
    }

    return json({ url: session.url, emailed, emailError });
  } catch (err) {
    console.error(err);
    return json({ error: err instanceof Error ? err.message : String(err) }, 500);
  }
});

function escapeHtml(s: string) {
  return s.replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]!));
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
