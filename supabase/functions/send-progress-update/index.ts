// Emails a client to say the studio has posted a progress update on their commission.
// Admin only: verify_jwt alone isn't enough (the public anon key is a valid JWT), so the
// caller is checked against studio_admins. Always returns the plain-text message too.
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: userData } = await admin.auth.getUser(token);
    const callerId = userData?.user?.id;
    const { data: isAdmin } = callerId
      ? await admin.from("studio_admins").select("user_id").eq("user_id", callerId).maybeSingle()
      : { data: null };
    if (!isAdmin) return json({ error: "Only the studio account can send updates." }, 403);

    const { update_id } = await req.json();
    if (!update_id) return json({ error: "update_id required" }, 400);

    const { data: u, error } = await admin.from("commission_updates")
      .select("id, message, file_paths, commission:commissions(id, client:clients(name, email, book_title))")
      .eq("id", update_id).single();
    if (error || !u) return json({ error: "Update not found" }, 404);

    // deno-lint-ignore no-explicit-any
    const c: any = u.commission;
    const client = c?.client;
    const siteUrl = (Deno.env.get("SITE_URL") ?? req.headers.get("origin") ?? "https://crows-quill.vercel.app").replace(/\/$/, "");
    const portal = client?.email
      ? `${siteUrl}/site/track.html?cid=${c.id}&email=${encodeURIComponent(client.email)}` : "";
    const first = String(client?.name ?? "there").split(" ")[0];
    const title = client?.book_title ? ` for ${client.book_title}` : "";
    const nFiles = (u.file_paths ?? []).length;
    const note = String(u.message ?? "").trim();

    const text = [
      `Hi ${first},`, "",
      `There's a new progress update on your commission${title}.`, "",
      ...(note ? [note, ""] : []),
      ...(nFiles ? [`${nFiles} ${nFiles === 1 ? "image/file is" : "images/files are"} waiting for you on your portal.`, ""] : []),
      ...(portal ? [`See it here: ${portal}`, ""] : []),
      "If you have any thoughts or changes, just reply to this email.", "",
      "The Crow's Quill",
    ].join("\n");

    const html = `<div style="font-family:Arial,sans-serif;max-width:560px;line-height:1.5">
      <p>Hi ${esc(first)},</p>
      <p>There's a new progress update on your commission${client?.book_title ? ` for <strong>${esc(client.book_title)}</strong>` : ""}.</p>
      ${note ? `<blockquote style="margin:12px 0;padding:8px 14px;border-left:3px solid #c9a05f;background:#faf7f2">${esc(note).replace(/\n/g, "<br>")}</blockquote>` : ""}
      ${nFiles ? `<p>${nFiles} ${nFiles === 1 ? "image/file is" : "images/files are"} waiting for you on your portal.</p>` : ""}
      ${portal ? `<p><a href="${portal}" style="display:inline-block;padding:10px 18px;background:#5b2a3a;color:#fff;text-decoration:none;border-radius:6px">View the update</a></p>` : ""}
      <p>If you have any thoughts or changes, just reply to this email.</p>
      <p>The Crow's Quill</p></div>`;

    const resendKey = Deno.env.get("RESEND_API_KEY");
    if (!resendKey || !client?.email) {
      return json({ emailed: false, emailError: !resendKey ? "RESEND_API_KEY not set" : "Client has no email", message: text });
    }
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: Deno.env.get("EMAIL_FROM") ?? Deno.env.get("FROM_EMAIL") ?? "studio@crowsquill.art",
        to: client.email, subject: "A new update on your commission — The Crow's Quill", html, text,
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
