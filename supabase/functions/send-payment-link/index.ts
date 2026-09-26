// Creates a Stripe Checkout link for the outstanding deposit or balance on a
// commission, emails it to the client (if RESEND_API_KEY is set), and marks
// it as sent. Called by the studio dashboard — requires an authenticated
// (artist) session; see supabase/config.toml [functions.send-payment-link].
import { createClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2024-06-20" });
const siteUrl = Deno.env.get("SITE_URL") ?? "http://127.0.0.1:3000";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

Deno.serve(async (req) => {
  try {
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
    if (!amount || amount <= 0) return json({ error: "Nothing owed" }, 400);

    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      customer_email: c.client?.email,
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

    const resendKey = Deno.env.get("RESEND_API_KEY");
    if (resendKey && c.client?.email) {
      await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          from: Deno.env.get("EMAIL_FROM") ?? "studio@crowsquill.art",
          to: c.client.email,
          subject: `The Crow's Quill — ${label} link`,
          html: `<p>Hi ${c.client.name},</p><p>Here's your secure ${label.toLowerCase()} link: <a href="${session.url}">${session.url}</a></p>`,
        }),
      });
    }

    return json({ url: session.url });
  } catch (err) {
    console.error(err);
    return json({ error: "Internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
