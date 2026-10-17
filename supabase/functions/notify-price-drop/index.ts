// =====================================================================
// MyTunigo — Edge Function "notify-price-drop"
// Alertes de baisse de prix sur les logements suivis en favoris.
//
// Appel (POST JSON), par la tâche planifiée fn_check_price_alerts() :
//   { action: "check" }
//       -> pour chaque alerte (price_alerts) dont le logement publié coûte
//          maintenant moins cher que le prix suivi : e-mail au voyageur,
//          puis le prix suivi est mis à jour (pas de double alerte).
//
// Sécurité : aucun destinataire ni contenu n'est accepté depuis l'appel ;
// tout est relu en base. Le traitement est idempotent (chaque alerte est
// « réservée » avant l'envoi) : un appel en trop n'envoie rien de plus.
//
// Secrets : RESEND_API_KEY, SB_SERVICE_ROLE_KEY (ou SUPABASE_SERVICE_ROLE_KEY).
// Facultatifs : RESEND_FROM, SITE_URL.
// =====================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SB_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM = Deno.env.get("RESEND_FROM") ?? "MyTunigo <noreply@mytunigo.com>";
const SITE = (Deno.env.get("SITE_URL") ?? "https://mytunigo.com").replace(/\/$/, "");

const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

let mailErrors: string[] = [];

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(mailErrors.length ? { ...body, mail_errors: mailErrors } : body), {
    status, headers: { ...cors, "Content-Type": "application/json" },
  });

const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const money = (n: unknown) => {
  const v = Number(n);
  return Number.isFinite(v) ? (Number.isInteger(v) ? String(v) : v.toFixed(2)) : "—";
};

async function sendMail(to: string | null | undefined, subject: string, html: string): Promise<boolean> {
  if (!to) { mailErrors.push(`destinataire vide pour « ${subject} »`); return false; }
  if (!RESEND_API_KEY) { mailErrors.push("RESEND_API_KEY manquant dans les secrets"); return false; }
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [to], subject, html }),
  });
  if (!r.ok) {
    const txt = await r.text();
    mailErrors.push(`Resend ${r.status} (to: ${to}) : ${txt}`);
    console.error("Resend", r.status, txt);
    return false;
  }
  return true;
}

function priceDropHtml(firstName: string, propName: string, oldPrice: number, newPrice: number) {
  const pct = oldPrice > 0 ? Math.round(((oldPrice - newPrice) / oldPrice) * 100) : 0;
  return `<!doctype html><html><body style="margin:0;background:#f3f6fa;font-family:-apple-system,'Segoe UI',Arial,sans-serif;color:#212529;">
  <div style="max-width:560px;margin:0 auto;padding:24px 16px;">
    <div style="background:#003580;color:#fff;border-radius:12px 12px 0 0;padding:20px 24px;">
      <div style="font-size:20px;font-weight:800;">My<span style="color:#FEBB02;">Tunigo</span></div>
      <div style="font-size:18px;font-weight:700;margin-top:8px;">💰 Le prix a baissé !</div>
    </div>
    <div style="background:#fff;border-radius:0 0 12px 12px;padding:24px;border:1px solid #e9ecef;border-top:none;">
      <div style="font-size:15px;line-height:1.65;margin-bottom:18px;">Bonjour ${esc(firstName)},<br><br>Bonne nouvelle : le prix de l'un de vos favoris vient de baisser.</div>
      <div style="background:#f8f9fa;border-radius:8px;padding:16px;font-size:15px;">
        <div>🏠 <strong>${esc(propName)}</strong></div>
        <div style="margin-top:8px;">
          <span style="text-decoration:line-through;color:#888;">${money(oldPrice)} €</span>
          <span style="font-size:20px;font-weight:800;color:#0d9e6e;margin-left:8px;">${money(newPrice)} €</span>
          <span style="font-size:13px;color:#6c757d;"> / nuit</span>
          ${pct > 0 ? `<span style="background:#0d9e6e;color:#fff;font-size:12px;font-weight:800;padding:2px 8px;border-radius:12px;margin-left:8px;">-${pct}%</span>` : ""}
        </div>
      </div>
      <div style="text-align:center;margin:24px 0 8px;"><a href="${SITE}" style="display:inline-block;background:#0071c2;color:#fff;text-decoration:none;font-weight:800;font-size:16px;padding:13px 28px;border-radius:8px;">Voir l'annonce</a></div>
      <div style="font-size:13px;color:#6c757d;line-height:1.6;margin-top:16px;">Vous recevez cet e-mail car vous avez activé une alerte de prix sur vos favoris MyTunigo.</div>
    </div>
  </div></body></html>`;
}

async function checkAlerts() {
  const { data: alerts, error } = await admin.from("price_alerts").select("id,user_id,annonce_id,tracked_price");
  if (error) return json({ error: error.message }, 500);
  if (!alerts?.length) return json({ ok: true, sent: 0 });

  const annIds = [...new Set(alerts.map((a) => a.annonce_id))];
  const userIds = [...new Set(alerts.map((a) => a.user_id))];
  const [{ data: anns, error: annErr }, { data: profs, error: profErr }] = await Promise.all([
    admin.from("annonces").select("id,name,price_night,status").in("id", annIds),
    admin.from("profiles").select("id,email,first_name").in("id", userIds),
  ]);
  // Sans ces données, on n'envoie rien (et on ne touche pas aux prix suivis).
  if (annErr || profErr) return json({ error: (annErr ?? profErr)!.message }, 500);
  const annMap = Object.fromEntries((anns ?? []).map((a) => [a.id, a]));
  const profMap = Object.fromEntries((profs ?? []).map((p) => [p.id, p]));

  let sent = 0;
  for (const al of alerts) {
    const ann = annMap[al.annonce_id];
    if (!ann || ann.status !== "publiée") continue;
    const oldPrice = Number(al.tracked_price), newPrice = Number(ann.price_night);
    if (!(newPrice < oldPrice)) continue;

    // « Réserve » l'alerte : seul l'appel qui met à jour le prix suivi envoie l'e-mail.
    const { data: claimed, error: claimErr } = await admin.from("price_alerts")
      .update({ tracked_price: newPrice })
      .eq("id", al.id).eq("tracked_price", al.tracked_price).select("id");
    if (claimErr) return json({ error: claimErr.message, sent }, 500);
    if (!claimed?.length) continue;

    const prof = profMap[al.user_id];
    if (await sendMail(prof?.email,
      `💰 Baisse de prix sur ${ann.name ?? "un de vos favoris"} !`.slice(0, 150),
      priceDropHtml(prof?.first_name ?? "", ann.name ?? "", oldPrice, newPrice))) sent++;
  }
  return json({ ok: true, sent });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  mailErrors = [];
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* corps vide */ }
  try {
    if (body.action === "check") return await checkAlerts();
    return json({ error: "action invalide" }, 400);
  } catch (err) {
    console.error("notify-price-drop:", (err as Error).message);
    return json({ error: (err as Error).message }, 500);
  }
});
