// =====================================================================
// MyTunigo — Edge Function "notify-deletion-request"
// Prévient l'administrateur qu'un hôte demande la suppression définitive
// d'une annonce ou d'une excursion.
//
// Appel (POST JSON, avec le JWT de l'hôte connecté) :
//   { item_type: "annonce" | "excursion", item_id }
//
// Sécurité : la demande doit exister dans la table deletion_requests
// (créée par l'hôte juste avant, statut 'en attente', il y a moins de
// 10 min). Le destinataire est toujours l'administrateur (ADMIN_EMAIL) et
// le contenu est relu en base : impossible d'écrire à une autre adresse.
//
// Secrets : RESEND_API_KEY, SB_SERVICE_ROLE_KEY (ou SUPABASE_SERVICE_ROLE_KEY).
// Facultatifs : ADMIN_EMAIL (défaut admin@mytunigo.com), RESEND_FROM, SITE_URL.
// =====================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SB_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM = Deno.env.get("RESEND_FROM") ?? "MyTunigo <noreply@mytunigo.com>";
const ADMIN_EMAIL = Deno.env.get("ADMIN_EMAIL") ?? "admin@mytunigo.com";
const SITE = (Deno.env.get("SITE_URL") ?? "https://mytunigo.com").replace(/\/$/, "");
const MAX_AGE_MS = 10 * 60 * 1000;

const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    // 1. Qui appelle ?
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: userData } = await admin.auth.getUser(token);
    const user = userData?.user;
    if (!user) return json({ error: "unauthorized" }, 401);

    // deno-lint-ignore no-explicit-any
    let body: any = {};
    try { body = await req.json(); } catch { /* corps vide */ }
    const itemType = body.item_type === "excursion" ? "excursion" : body.item_type === "annonce" ? "annonce" : "";
    const itemId = String(body.item_id ?? "");
    if (!itemType || !itemId) return json({ error: "item_type/item_id manquant" }, 400);

    // 2. La demande, enregistrée par cet hôte il y a moins de 10 min
    const { data: reqRow, error: readErr } = await admin.from("deletion_requests")
      .select("item_name,host_email,created_at")
      .eq("item_type", itemType).eq("item_id", itemId).eq("host_id", user.id).eq("status", "en attente")
      .order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (readErr) return json({ error: readErr.message }, 500);
    if (!reqRow) return json({ error: "not_found" }, 404);
    if (Date.now() - new Date(reqRow.created_at).getTime() > MAX_AGE_MS) return json({ error: "too_old" }, 409);

    // 3. Contexte, relu en base
    const isExc = itemType === "excursion";
    const [{ data: item }, { data: prof }] = await Promise.all([
      admin.from(isExc ? "excursions" : "annonces").select(isExc ? "title,ref" : "name,ref").eq("id", itemId).maybeSingle(),
      admin.from("profiles").select("first_name,last_name").eq("id", user.id).maybeSingle(),
    ]);
    // deno-lint-ignore no-explicit-any
    const it = item as any;
    const itemName = (isExc ? it?.title : it?.name) ?? reqRow.item_name ?? "—";
    const hostName = [prof?.first_name, prof?.last_name].filter(Boolean).join(" ") || "—";
    const row = (k: string, v: string) =>
      `<tr><td style="padding:6px 0;color:#6c757d;width:130px;vertical-align:top;">${k}</td><td style="padding:6px 0;font-weight:600;">${v}</td></tr>`;

    const html = `<!doctype html><html><body style="margin:0;background:#f3f6fa;font-family:-apple-system,'Segoe UI',Arial,sans-serif;color:#212529;">
  <div style="max-width:560px;margin:0 auto;padding:24px 16px;">
    <div style="background:#003580;color:#fff;border-radius:12px 12px 0 0;padding:20px 24px;">
      <div style="font-size:20px;font-weight:800;">My<span style="color:#FEBB02;">Tunigo</span></div>
      <div style="font-size:18px;font-weight:700;margin-top:8px;">🗑️ Demande de suppression</div>
    </div>
    <div style="background:#fff;border-radius:0 0 12px 12px;padding:24px;border:1px solid #e9ecef;border-top:none;">
      <div style="font-size:15px;line-height:1.65;margin-bottom:18px;">Un hôte demande la suppression définitive ${isExc ? "d'une excursion" : "d'une annonce (hébergement)"}.</div>
      <table style="width:100%;border-collapse:collapse;font-size:14px;background:#f8f9fa;border-radius:8px;"><tbody style="display:block;padding:12px 14px;">
        ${row("Élément", esc(itemName))}
        ${row("Référence", esc(it?.ref ?? itemId))}
        ${row("Demandé par", `${esc(hostName)}<br>${esc(user.email ?? reqRow.host_email ?? "—")}`)}
      </tbody></table>
      <div style="text-align:center;margin:24px 0 8px;"><a href="${SITE}/?admin=1" style="display:inline-block;background:#cc0000;color:#fff;text-decoration:none;font-weight:800;font-size:16px;padding:13px 28px;border-radius:8px;">Traiter la demande</a></div>
      <div style="font-size:13px;color:#6c757d;line-height:1.6;margin-top:16px;">Tableau de bord admin → ${isExc ? "Excursions" : "Annonces"} : la carte affiche un badge rouge « Suppression demandée par l'hôte ».</div>
    </div>
  </div></body></html>`;

    if (!RESEND_API_KEY) return json({ error: "RESEND_API_KEY manquant dans les secrets" }, 500);
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: FROM, to: [ADMIN_EMAIL], subject: `🗑️ Demande de suppression — ${itemName}`.slice(0, 150), html }),
    });
    if (!r.ok) {
      const txt = await r.text();
      console.error("Resend", r.status, txt);
      return json({ error: "mail_failed", detail: `Resend ${r.status}: ${txt}` }, 502);
    }
    return json({ ok: true });
  } catch (err) {
    console.error("notify-deletion-request:", (err as Error).message);
    return json({ error: (err as Error).message }, 500);
  }
});
