// =====================================================================
// MyTunigo — Edge Function "notify-booking"
// E-mails liés aux décisions sur une réservation de logement.
//
// Actions (POST JSON, avec le JWT de l'utilisateur connecté) :
//   { type: "declined",  reservation_id, host_message? }
//       -> appelant = HÔTE du logement, statut 'refusée'
//       -> e-mail au voyageur : demande non retenue
//   { type: "cancelled", reservation_id }
//       -> appelant = VOYAGEUR de la réservation, statut 'annulée'
//       -> e-mail à l'hôte (dates libérées, motif) + confirmation au voyageur
//          (motif, montant remboursable calculé en base)
//
// Sécurité : les destinataires et le contenu (nom du logement, dates,
// montant, motif…) sont lus en base. Le navigateur n'envoie qu'un
// identifiant : impossible d'utiliser la fonction pour écrire à une adresse
// arbitraire. L'hôte ne voit jamais le montant payé par le voyageur.
//
// Les autres e-mails du parcours (demande envoyée, alerte hôte, demande
// acceptée, paiement, expiration) sont gérés par "reservation-flow".
//
// Secrets (Supabase > Edge Functions > Secrets) : RESEND_API_KEY,
// SB_SERVICE_ROLE_KEY (ou SUPABASE_SERVICE_ROLE_KEY, fourni par défaut).
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

// ---------- formatage ----------
const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const fmtDate = (d: string | null) => {
  if (!d) return "—";
  const [y, m, dd] = String(d).slice(0, 10).split("-");
  return `${dd}/${m}/${y}`;
};
const fmtAmount = (n: unknown) => Number(n ?? 0).toLocaleString("fr-FR", { maximumFractionDigits: 2 });

function layout(title: string, intro: string, recap: string, cta?: { label: string; url: string }, outro = "") {
  return `<!doctype html><html><body style="margin:0;background:#f3f6fa;font-family:-apple-system,'Segoe UI',Arial,sans-serif;color:#212529;">
  <div style="max-width:560px;margin:0 auto;padding:24px 16px;">
    <div style="background:#003580;color:#fff;border-radius:12px 12px 0 0;padding:20px 24px;">
      <div style="font-size:20px;font-weight:800;">My<span style="color:#FEBB02;">Tunigo</span></div>
      <div style="font-size:18px;font-weight:700;margin-top:8px;">${title}</div>
    </div>
    <div style="background:#fff;border-radius:0 0 12px 12px;padding:24px;border:1px solid #e9ecef;border-top:none;">
      <div style="font-size:15px;line-height:1.65;margin-bottom:18px;">${intro}</div>
      ${recap}
      ${cta ? `<div style="text-align:center;margin:24px 0 8px;"><a href="${cta.url}" style="display:inline-block;background:#0071c2;color:#fff;text-decoration:none;font-weight:800;font-size:16px;padding:13px 28px;border-radius:8px;">${cta.label}</a></div>` : ""}
      ${outro ? `<div style="font-size:13px;color:#6c757d;line-height:1.6;margin-top:16px;">${outro}</div>` : ""}
    </div>
    <div style="text-align:center;font-size:12px;color:#adb5bd;margin-top:14px;">MyTunigo — mytunigo.com</div>
  </div></body></html>`;
}

// Récapitulatif. withTotal = false pour l'hôte : il ne voit pas ce que paie le voyageur.
// deno-lint-ignore no-explicit-any
function recapBlock(r: any, propName: string, withTotal = true) {
  const row = (k: string, v: string) =>
    `<tr><td style="padding:5px 0;color:#6c757d;">${k}</td><td style="padding:5px 0;text-align:right;font-weight:600;">${v}</td></tr>`;
  return `<table style="width:100%;border-collapse:collapse;font-size:14px;background:#f8f9fa;border-radius:8px;">
    <tbody style="display:block;padding:12px 14px;">
      ${row("Hébergement", esc(propName))}
      ${row("Arrivée", fmtDate(r.check_in))}
      ${row("Départ", fmtDate(r.check_out))}
      ${row("Voyageurs", String(r.guests_count ?? 1))}
      ${row("Référence", esc(r.reference ?? "—"))}
      ${withTotal ? row("Total", `<span style="color:#003580;font-size:16px;">${esc(r.total)}€</span>`) : ""}
    </tbody></table>`;
}

const reasonBlock = (reason: string | null | undefined) => reason
  ? `<div style="margin-top:14px;padding:10px 14px;border-left:3px solid #b42318;background:#fff5f5;"><strong>Motif :</strong> ${esc(reason)}</div>`
  : "";

async function sendMail(to: string | null | undefined, subject: string, html: string) {
  if (!to) { mailErrors.push(`destinataire vide pour « ${subject} »`); return; }
  if (!RESEND_API_KEY) { mailErrors.push("RESEND_API_KEY manquant dans les secrets"); return; }
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [to], subject, html }),
  });
  if (!r.ok) {
    const txt = await r.text();
    mailErrors.push(`Resend ${r.status} (to: ${to}) : ${txt}`);
    console.error("Resend", r.status, txt);
  }
}

// ---------- handler ----------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  mailErrors = [];

  try {
    // 1. Qui appelle ?
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: userData } = await admin.auth.getUser(token);
    const uid = userData?.user?.id;
    if (!uid) return json({ error: "unauthorized" }, 401);

    // deno-lint-ignore no-explicit-any
    let body: any = {};
    try { body = await req.json(); } catch { /* corps vide */ }
    const type = String(body.type ?? "");
    const id = String(body.reservation_id ?? "");
    if (!id) return json({ error: "reservation_id manquant" }, 400);

    // 2. Réservation + logement + voyageur, lus en base
    const { data: r, error: readErr } = await admin.from("reservations").select("*").eq("id", id).maybeSingle();
    if (readErr) return json({ error: readErr.message }, 500);
    if (!r) return json({ error: "not_found" }, 404);

    const [{ data: ann }, { data: guest }] = await Promise.all([
      admin.from("annonces").select("name,user_id,contact_email,contact_firstname").eq("id", r.logement_id).maybeSingle(),
      admin.from("profiles").select("email,first_name").eq("id", r.guest_id).maybeSingle(),
    ]);
    const propName = ann?.name ?? "votre hébergement";
    const guestName = guest?.first_name ?? "";

    // 3. Actions
    if (type === "declined") {
      if (ann?.user_id !== uid) return json({ error: "not_host" }, 403);
      if (r.status !== "refusée") return json({ error: "not_refusée" }, 409);
      const hostMsg = String(body.host_message ?? "").trim().slice(0, 1000);
      await sendMail(
        guest?.email,
        `Votre demande n'a pas été retenue — ${propName}`,
        layout("Demande non retenue",
          `Bonjour ${esc(guestName)},<br><br>L'hôte de <strong>${esc(propName)}</strong> n'a pas pu accepter votre demande de réservation. Aucun paiement n'a été effectué.
           ${hostMsg ? `<div style="margin-top:14px;padding:10px 14px;border-left:3px solid #0071c2;background:#f0f7ff;font-style:italic;">« ${esc(hostMsg)} »<br><span style="font-style:normal;font-size:12px;color:#6c757d;">— votre hôte</span></div>` : ""}`,
          recapBlock(r, propName),
          { label: "🔍 Trouver un autre logement", url: SITE }),
      );
    } else if (type === "cancelled") {
      if (r.guest_id !== uid) return json({ error: "not_guest" }, 403);
      if (r.status !== "annulée") return json({ error: "not_annulée" }, 409);
      // Réservation payée (confirmée) ou simple demande ?
      const wasPaid = !!r.paid_at;
      const refund = Number(r.refund_amount ?? 0);
      const money = !wasPaid
        ? "Aucun paiement n'avait été effectué : rien ne vous sera prélevé."
        : refund >= Number(r.total ?? 0) && refund > 0
          ? `Vous serez remboursé intégralement (${fmtAmount(refund)}€).`
          : refund > 0
            ? `Selon la politique d'annulation, vous serez remboursé de ${fmtAmount(refund)}€.`
            : "Selon la politique d'annulation de ce logement, cette réservation n'est pas remboursable.";
      await Promise.all([
        sendMail(
          ann?.contact_email,
          `❌ Réservation annulée par le voyageur — ${propName}`,
          layout("Réservation annulée",
            `Bonjour ${esc(ann?.contact_firstname ?? "")},<br><br><strong>${esc(guestName || "Le voyageur")}</strong> a annulé ${wasPaid ? "sa réservation" : "sa demande de réservation"} pour <strong>${esc(propName)}</strong>. Ces dates sont de nouveau disponibles sur votre calendrier.${reasonBlock(r.cancel_reason)}`,
            recapBlock(r, propName, false),
            { label: "📨 Gérer les réservations", url: SITE }),
        ),
        sendMail(
          guest?.email,
          `Votre annulation est confirmée — ${propName}`,
          layout("Annulation confirmée",
            `Bonjour ${esc(guestName)},<br><br>Nous confirmons l'annulation de votre réservation pour <strong>${esc(propName)}</strong>. ${money}${reasonBlock(r.cancel_reason)}`,
            recapBlock(r, propName),
            { label: "🔍 Trouver un autre logement", url: SITE }),
        ),
      ]);
    } else {
      return json({ error: "type invalide" }, 400);
    }

    if (mailErrors.length) return json({ error: "mail_failed" }, 502);
    return json({ ok: true });
  } catch (err) {
    console.error("notify-booking:", (err as Error).message);
    return json({ error: (err as Error).message }, 500);
  }
});
