// Emails a client their one-time testimonial link. Called by the studio
// dashboard ("Send for testimonial"). Checks the caller is the studio admin
// (verify_jwt alone would also let the public anon key through).
// Email is best-effort: if RESEND_API_KEY is missing or Resend fails, the link
// is still returned so the artist can copy it and send it manually.
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const asCaller = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    // Must be a signed-in studio user (the anon key alone is not enough).
    const { data: userData } = await asCaller.auth.getUser();
    if (!userData?.user) return json({ error: "Sign in to the studio dashboard first" }, 401);
    // If the stricter is_studio_admin() helper exists, enforce it too.
    const { data: isAdmin, error: adminErr } = await asCaller.rpc("is_studio_admin");
    const helperMissing = adminErr && (adminErr.code === "PGRST202" || /could not find the function/i.test(adminErr.message ?? ""));
    if (!helperMissing && !isAdmin) return json({ error: "Studio admin access required" }, 403);

    // SITE_URL if set, otherwise the origin the admin page is served from.
    const siteUrl = (Deno.env.get("SITE_URL") ?? req.headers.get("origin") ?? "").replace(/\/$/, "");
    if (!siteUrl) return json({ error: "SITE_URL is not set and the request had no Origin header" }, 500);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { commission_id } = await req.json();
    if (!commission_id) return json({ error: "commission_id required" }, 400);

    const { data: c, error } = await admin
      .from("commissions")
      .select("id, client:clients(name, email, book_title)")
      .eq("id", commission_id)
      .single();
    if (error || !c) return json({ error: "Commission not found" }, 404);

    let { data: t } = await admin
      .from("testimonials").select("*").eq("commission_id", commission_id).maybeSingle();
    if (!t) {
      const ins = await admin.from("testimonials").insert({ commission_id }).select("*").single();
      if (ins.error) return json({ error: ins.error.message }, 500);
      t = ins.data;
    }
    if (t.submitted_at) return json({ error: "This client has already submitted a testimonial." }, 400);

    const url = `${siteUrl}/site/testimonial.html?t=${t.token}`;
    const client = (c as any).client;

    let emailed = false;
    let emailError: string | undefined;
    const resendKey = Deno.env.get("RESEND_API_KEY");
    if (resendKey && client?.email) {
      try {
        const book = client.book_title ? ` for ${escapeHtml(client.book_title)}` : "";
        const r = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            from: Deno.env.get("EMAIL_FROM") ?? Deno.env.get("FROM_EMAIL") ?? "studio@crowsquill.art",
            to: client.email,
            subject: "How did we do? A quick testimonial for The Crow's Quill",
            html:
              `<p>Hi ${escapeHtml(client.name ?? "there")},</p>` +
              `<p>Thank you so much for commissioning The Crow's Quill${book}. ` +
              `If you have a minute, I'd be so grateful for a star rating and a few words about your experience:</p>` +
              `<p><a href="${url}">${url}</a></p>` +
              `<p>It takes under a minute, and your words help other authors find the studio.</p>` +
              `<p>With thanks,<br>The Crow's Quill</p>`,
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

    if (emailed) {
      await admin.from("testimonials").update({ emailed_at: new Date().toISOString() }).eq("id", t.id);
    }
    return json({ url, emailed, emailError });
  } catch (err) {
    console.error(err);
    return json({ error: err instanceof Error ? err.message : String(err) }, 500);
  }
});

function escapeHtml(s: string) {
  return s.replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]!));
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}
