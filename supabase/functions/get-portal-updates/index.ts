// Returns the progress updates the studio has posted for ONE commission, with short-lived
// signed links to the (private) images. The caller must supply the commission reference AND
// the client's email, exactly like the portal lookup. Anything else gets a generic "not found".
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const BUCKET = "commission-files";
const IMAGE_RE = /\.(jpe?g|png|gif|webp|avif|bmp)$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const { commission_id, email } = await req.json();
    const id = String(commission_id ?? "").trim();
    const mail = String(email ?? "").trim().toLowerCase();
    if (!/^[0-9a-f-]{36}$/i.test(id) || !mail) return json({ error: "Not found" }, 404);

    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const { data: c } = await admin.from("commissions")
      .select("id, client:clients(email)").eq("id", id).maybeSingle();
    const owner = String((c as { client?: { email?: string } } | null)?.client?.email ?? "").trim().toLowerCase();
    if (!c || owner !== mail) return json({ error: "Not found" }, 404);

    const { data: rows } = await admin.from("commission_updates")
      .select("id, message, file_paths, created_at")
      .eq("commission_id", id).order("created_at", { ascending: false });
    const updates = rows ?? [];

    // Only ever sign files that live inside this commission's own folder.
    const prefix = `${id}/`;
    const paths = [...new Set(updates.flatMap((u) => u.file_paths ?? []).filter((p: string) => p.startsWith(prefix)))];
    const view = new Map<string, string>();
    const download = new Map<string, string>();
    if (paths.length) {
      const [v, d] = await Promise.all([
        admin.storage.from(BUCKET).createSignedUrls(paths, 3600),
        admin.storage.from(BUCKET).createSignedUrls(paths, 3600, { download: true }),
      ]);
      for (const s of v.data ?? []) if (s.signedUrl && s.path) view.set(s.path, s.signedUrl);
      for (const s of d.data ?? []) if (s.signedUrl && s.path) download.set(s.path, s.signedUrl);
    }

    return json({
      updates: updates.map((u) => ({
        id: u.id,
        message: u.message,
        created_at: u.created_at,
        files: (u.file_paths ?? [])
          .filter((p: string) => view.has(p))
          .map((p: string) => ({
            name: p.split("/").pop()!.replace(/^\d{10,}-/, ""),
            isImage: IMAGE_RE.test(p),
            url: view.get(p),
            downloadUrl: download.get(p),
          })),
      })),
    });
  } catch (err) {
    console.error(err);
    return json({ error: "Something went wrong" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}
