// Emails the artist when something needs attention (new enquiry, signed contract,
// client message or upload). Called by database triggers via pg_net, not by browsers,
// so it is protected by a shared secret instead of a user JWT (verify_jwt = false).
import { createClient } from "npm:@supabase/supabase-js@2";

const TITLES: Record<string, string> = {
  enquiry: "New commission enquiry",
  contract_signed: "Contract signed",
  client_note: "New message from a client",
  client_file: "A client uploaded a file",
};

Deno.serve(async (req) => {
  const secret = Deno.env.get("NOTIFY_SECRET");
  if (!secret || req.headers.get("x-notify-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }
  try {
    const { kind, commission_id } = await req.json();
    const title = TITLES[kind];
    if (!title || !commission_id) return new Response("bad request", { status: 400 });

    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: c } = await admin
      .from("commissions")
      .select("*, client:clients(*), slot:slots(*), commission_notes(note, created_by, created_at)")
      .eq("id", commission_id).single();
    if (!c) return new Response("not found", { status: 404 });

    const to = Deno.env.get("ARTIST_EMAIL");
    const resendKey = Deno.env.get("RESEND_API_KEY");
    if (!to || !resendKey) {
      console.error("ARTIST_EMAIL or RESEND_API_KEY not set; alert not sent");
      return new Response("not configured", { status: 200 });
    }

    const site = (Deno.env.get("SITE_URL") ?? "").replace(/\/$/, "");
    const money = (v: unknown) => (v == null ? "—" : `$${v}`);
    const lastNote = [...(c.commission_notes ?? [])].sort((a, b) => b.created_at.localeCompare(a.created_at))[0];
    const rows: [string, string][] = [
      ["Client", `${c.client?.name ?? "—"} (${c.client?.email ?? "—"})`],
      ["Book / series", c.client?.book_title ?? "—"],
      ["Commission", String(c.commission_type ?? "—")],
      ["Slot", c.slot?.slot_date ?? "—"],
      ["Estimate", money(c.total_price)],
    ];
    if (kind === "client_note" && lastNote) rows.push(["Message", lastNote.note]);
    if (kind === "enquiry" && c.brief) rows.push(["Brief", String(c.brief).slice(0, 600)]);

    const html = `<div style="font-family:Arial,sans-serif;max-width:560px">
      <h2 style="margin:0 0 12px">${esc(title)}</h2>
      <table style="border-collapse:collapse;width:100%">${rows.map(([k, v]) =>
        `<tr><td style="padding:6px 12px 6px 0;color:#666;vertical-align:top;white-space:nowrap">${esc(k)}</td><td style="padding:6px 0">${esc(v)}</td></tr>`).join("")}</table>
      ${site ? `<p style="margin-top:18px"><a href="${site}/admin/">Open the studio dashboard</a></p>` : ""}
    </div>`;

    const send = (from: string) => fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from, to, subject: `${title} — ${c.client?.name ?? ""}`.trim(), html }),
    });
    const configured = Deno.env.get("EMAIL_FROM") ?? Deno.env.get("FROM_EMAIL") ?? "studio@crowsquill.art";
    let r = await send(configured);
    // Until a domain is verified Resend only allows its own test sender
    if (!r.ok && configured !== "onboarding@resend.dev") r = await send("The Crow's Quill <onboarding@resend.dev>");
    if (!r.ok) console.error("Resend failed", r.status, (await r.text()).slice(0, 300));
    return new Response(r.ok ? "sent" : "email failed", { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response("error", { status: 500 });
  }
});

function esc(s: string) {
  return String(s).replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]!));
}
