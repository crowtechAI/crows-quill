// Emails the client their confirmed price, what changed from the original estimate, and why.
// Admin only (verify_jwt = true). Always returns the plain-text message too, so it can be
// copied and sent by hand if email isn't available.
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const siteUrl = (Deno.env.get("SITE_URL") ?? req.headers.get("origin") ?? "").replace(/\/$/, "");
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { commission_id } = await req.json();
    if (!commission_id) return json({ error: "commission_id required" }, 400);

    const { data: c, error } = await admin.from("commissions")
      .select("*, client:clients(*), quotes(*)").eq("id", commission_id).single();
    if (error || !c) return json({ error: "Commission not found" }, 404);
    const q = [...(c.quotes ?? [])].sort((a, b) => String(b.adjusted_at ?? b.sent_at).localeCompare(String(a.adjusted_at ?? a.sent_at)))[0];
    if (!q?.adjusted_at) return json({ error: "This quote has not been adjusted yet" }, 400);

    const m = (v: unknown) => `$${Number(v)}`;
    const first = String(c.client?.name ?? "there").split(" ")[0];
    const items: { label: string; amount: number }[] = q.line_items ?? [];
    const deposit = Number(c.deposit_amount ?? 0);
    const total = Number(q.total);
    const portal = siteUrl && c.client?.email
      ? `${siteUrl}/site/track.html?cid=${c.id}&email=${encodeURIComponent(c.client.email)}` : "";

    const dueLine = c.deposit_paid
      ? `Your deposit of ${m(deposit)} has already been received; the remaining balance is ${m(total - deposit)}.`
      : `Your deposit (50%) is ${m(deposit)}, with the remaining ${m(total - deposit)} due before final delivery.`;
    const text = [
      `Hi ${first},`, "",
      `I've reviewed your brief${c.client?.book_title ? ` for ${c.client.book_title}` : ""} and confirmed the final price for your commission.`, "",
      `Original estimate: ${m(q.original_total ?? total)}`,
      `Confirmed price: ${m(total)}`, "",
      "Breakdown:", ...items.map((i) => `  - ${i.label}: ${Number(i.amount) < 0 ? "-" : ""}$${Math.abs(Number(i.amount))}`), "",
      "Why it changed:", String(q.adjustment_reason ?? ""), "",
      dueLine, "",
      ...(portal ? [`You can view everything here: ${portal}`, ""] : []),
      "If you have any questions or would like to talk it through, just reply to this email.", "",
      "The Crow's Quill",
    ].join("\n");

    const html = `<div style="font-family:Arial,sans-serif;max-width:560px;line-height:1.5">
      <p>Hi ${esc(first)},</p>
      <p>I've reviewed your brief${c.client?.book_title ? ` for <strong>${esc(c.client.book_title)}</strong>` : ""} and confirmed the final price for your commission.</p>
      <p style="margin:0">Original estimate: <strong>${m(q.original_total ?? total)}</strong><br>Confirmed price: <strong>${m(total)}</strong></p>
      <table style="border-collapse:collapse;width:100%;margin:14px 0">${items.map((i) =>
        `<tr><td style="padding:5px 12px 5px 0;border-bottom:1px solid #eee">${esc(i.label)}</td><td style="padding:5px 0;border-bottom:1px solid #eee;text-align:right">${Number(i.amount) < 0 ? "-" : ""}$${Math.abs(Number(i.amount))}</td></tr>`).join("")}</table>
      <p><strong>Why it changed</strong><br>${esc(q.adjustment_reason ?? "").replace(/\n/g, "<br>")}</p>
      <p>${esc(dueLine)}</p>
      ${portal ? `<p><a href="${portal}">View your commission</a></p>` : ""}
      <p>If you have any questions or would like to talk it through, just reply to this email.</p>
      <p>The Crow's Quill</p></div>`;

    const resendKey = Deno.env.get("RESEND_API_KEY");
    if (!resendKey || !c.client?.email) {
      return json({ emailed: false, emailError: !resendKey ? "RESEND_API_KEY not set" : "Client has no email", message: text });
    }
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: Deno.env.get("EMAIL_FROM") ?? Deno.env.get("FROM_EMAIL") ?? "studio@crowsquill.art",
        to: c.client.email, subject: "Your commission price is confirmed — The Crow's Quill", html, text,
      }),
    });
    if (!r.ok) {
      const body = (await r.text()).slice(0, 300);
      console.error("Resend failed", r.status, body);
      return json({ emailed: false, emailError: `Resend ${r.status}: ${body}`, message: text });
    }
    return json({ emailed: true, message: text });
  } catch (err) {
    console.error(err);
    return json({ error: err instanceof Error ? err.message : String(err) }, 500);
  }
});

function esc(s: unknown) {
  return String(s ?? "").replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]!));
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}
