// =====================================================================
// MyTunigo — Edge Function "notify-excursion-booking"
// E-mails des réservations d'excursions.
//
// Appel (POST JSON, avec le JWT de l'utilisateur connecté) :
//   { type: "created",   booking_id }                 (VOYAGEUR)
//       -> voyageur : réservation confirmée (réservation instantanée)
//                     ou demande envoyée (validation du prestataire)
//       -> prestataire : nouvelle réservation / nouvelle demande
//   { type: "decision",  booking_id, host_message? }  (PRESTATAIRE)
//       -> voyageur : demande acceptée ('confirmée') ou refusée ('refusée')
//   { type: "cancelled", booking_id }                 (VOYAGEUR)
//       -> prestataire : annulation + voyageur : confirmation d'annulation
//
// Appel par la tâche planifiée fn_auto_reject_expired_excursion_bookings() :
//   { type: "expire_pending" }
//       -> demandes restées 'en attente' dont la date d'excursion est passée
//          (heure de Tunis) : passage en 'refusée' + e-mail au voyageur.
//          Traitement par lot, idempotent, sans paramètre ni destinataire
//          fourni par l'appel : un appel en trop n'envoie rien de plus.
//
// Sécurité : destinataires et contenu lus en base ; l'appelant doit être
// le voyageur (created / cancelled) ou le propriétaire de l'excursion
// (decision), et le statut doit correspondre.
//
// Secrets : RESEND_API_KEY, SB_SERVICE_ROLE_KEY (ou SUPABASE_SERVICE_ROLE_KEY).
// =====================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SB_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM = Deno.env.get("RESEND_FROM") ?? "MyTunigo <noreply@mytunigo.com>";
const SITE = (Deno.env.get("SITE_URL") ?? "https://mytunigo.com").replace(/\/$/, "");
const CREATED_MAX_AGE_MS = 10 * 60 * 1000; // anti-renvoi pour "created"

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
const fmtDate = (d: string | null) => {
  if (!d) return "—";
  const [y, m, dd] = String(d).slice(0, 10).split("-");
  return `${dd}/${m}/${y}`;
};

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

// Récapitulatif. Pour le prestataire (hostNet fourni ou null), on n'affiche pas
// ce que le participant paie mais ce que le prestataire reçoit.
// deno-lint-ignore no-explicit-any
function recapBlock(b: any, title: string, hostNet?: number | null) {
  const row = (k: string, v: string) =>
    `<tr><td style="padding:5px 0;color:#6c757d;">${k}</td><td style="padding:5px 0;text-align:right;font-weight:600;">${v}</td></tr>`;
  return `<table style="width:100%;border-collapse:collapse;font-size:14px;background:#f8f9fa;border-radius:8px;">
    <tbody style="display:block;padding:12px 14px;">
      ${row("Excursion", esc(title))}
      ${row("Date", fmtDate(b.date))}
      ${row("Participants", String(b.participants ?? 1))}
      ${row("Paiement", esc(b.payment_method ?? "—"))}
      ${row("Référence", esc(b.reference ?? "—"))}
      ${hostNet === undefined
        ? row("Total", `<span style="color:#003580;font-size:16px;">${esc(b.total)}€</span>`)
        : hostNet === null ? "" : row("Vous recevez", `<span style="color:#0a8f5c;font-size:16px;">${esc(fmtAmount(hostNet))}€</span>`)}
    </tbody></table>`;
}

function fmtAmount(n: number) {
  return Number(n).toLocaleString("fr-FR", { maximumFractionDigits: 2 });
}

// Montant reçu par le prestataire : reversement figé à la confirmation s'il
// existe, sinon devis (12 % par défaut ou taux négocié). null si indisponible.
// deno-lint-ignore no-explicit-any
async function hostNetFor(b: any, ownerId: string | null | undefined): Promise<number | null> {
  const { data: pay } = await admin.from("booking_payouts").select("payout")
    .eq("kind", "excursion").eq("booking_id", b.id).maybeSingle();
  if (pay && pay.payout != null) return Number(pay.payout);
  if (!ownerId) return null;
  const { data: q, error } = await admin.rpc("fn_commission_quote", {
    p_kind: "excursion", p_booking: b.id,
  });
  if (error) { console.warn("devis commission :", error.message); return null; }
  const row = Array.isArray(q) ? q[0] : q;
  return row && row.payout != null ? Number(row.payout) : null;
}

// Code de réservation (6 caractères, créé en base à la confirmation).
// Contrôle à l'arrivée : ne prouve pas l'identité.
function codeBlock(code: string | null | undefined, who: "guest" | "host", kind: "logement" | "excursion") {
  if (!code) return "";
  const hint = who === "guest"
    ? (kind === "logement"
      ? "À communiquer à votre hôte à l'arrivée s'il vous le demande."
      : "À communiquer à l'organisateur s'il vous le demande. Vous réservez pour d'autres personnes ? Transmettez-leur ce code.")
    : (kind === "logement"
      ? "Demandez ce code au voyageur à son arrivée pour vérifier qu'il s'agit bien de cette réservation."
      : "Demandez ce code aux participants pour vérifier qu'il s'agit bien de cette réservation.");
  return `<div style="margin-top:16px;padding:14px 16px;background:#f3f0ff;border:1px solid #d9d0ff;border-radius:8px;text-align:center;">
    <div style="font-size:13px;font-weight:700;color:#5b3fc4;">🔐 Code de réservation</div>
    <div style="font-size:26px;font-weight:800;letter-spacing:6px;color:#3a2a8a;font-family:'Courier New',monospace;margin:6px 0;">${esc(code)}</div>
    <div style="font-size:12.5px;color:#6c757d;line-height:1.5;">${hint}</div>
  </div>`;
}

const hostNote = (msg: string) => msg
  ? `<div style="margin-top:14px;padding:10px 14px;border-left:3px solid #0071c2;background:#f0f7ff;font-style:italic;">« ${esc(msg)} »<br><span style="font-style:normal;font-size:12px;color:#6c757d;">— votre prestataire</span></div>`
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

// ---------- demandes expirées (tâche planifiée) ----------
async function expirePending() {
  const todayTn = new Date().toLocaleDateString("en-CA", { timeZone: "Africa/Tunis" }); // YYYY-MM-DD
  // La mise à jour sert de « réservation » : seules les lignes réellement
  // passées de 'en attente' à 'refusée' par cet appel reçoivent un e-mail.
  const { data: expired, error } = await admin.from("excursion_bookings")
    .update({ status: "refusée" })
    .eq("status", "en attente")
    .lt("date", todayTn)
    .select("*");
  if (error) return json({ error: error.message }, 500);

  for (const b of expired ?? []) {
    const [{ data: exc }, { data: guest }] = await Promise.all([
      admin.from("excursions").select("title").eq("id", b.excursion_id).maybeSingle(),
      admin.from("profiles").select("email,first_name").eq("id", b.guest_id).maybeSingle(),
    ]);
    const title = exc?.title ?? "votre excursion";
    await sendMail(guest?.email, `Votre demande pour ${title} a expiré`.slice(0, 150),
      layout("Demande expirée",
        `Bonjour ${esc(guest?.first_name ?? "")},<br><br>Le prestataire de <strong>${esc(title)}</strong> n'a pas répondu à votre demande avant la date de l'excursion. La demande est donc close.`,
        recapBlock(b, title), { label: "🔍 Voir d'autres excursions", url: SITE }));
  }
  return json({ ok: true, expired: (expired ?? []).length });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  mailErrors = [];

  try {
    // deno-lint-ignore no-explicit-any
    let body: any = {};
    try { body = await req.json(); } catch { /* corps vide */ }
    const type = String(body.type ?? "");

    if (type === "expire_pending") return await expirePending();

    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: userData } = await admin.auth.getUser(token);
    const uid = userData?.user?.id;
    if (!uid) return json({ error: "unauthorized" }, 401);

    const id = String(body.booking_id ?? "");
    if (!id) return json({ error: "booking_id manquant" }, 400);

    const { data: b, error: readErr } = await admin.from("excursion_bookings").select("*").eq("id", id).maybeSingle();
    if (readErr) return json({ error: readErr.message }, 500);
    if (!b) return json({ error: "not_found" }, 404);

    const [{ data: exc }, { data: guest }] = await Promise.all([
      admin.from("excursions").select("title,owner_id,contact_email,contact_firstname").eq("id", b.excursion_id).maybeSingle(),
      admin.from("profiles").select("email,first_name").eq("id", b.guest_id).maybeSingle(),
    ]);
    const title = exc?.title ?? "votre excursion";
    const guestName = guest?.first_name ?? "";
    const hostName = exc?.contact_firstname ?? "";
    const recap = recapBlock(b, title);
    const recapOwner = recapBlock(b, title, await hostNetFor(b, exc?.owner_id));
    // Réservation confirmée : on joint le code de réservation
    const recapGuest = b.status === "confirmée" ? recap + codeBlock(b.booking_code, "guest", "excursion") : recap;
    const recapHost = b.status === "confirmée" ? recapOwner + codeBlock(b.booking_code, "host", "excursion") : recapOwner;

    if (type === "created") {
      if (b.guest_id !== uid) return json({ error: "not_guest" }, 403);
      if (b.created_at && Date.now() - new Date(b.created_at).getTime() > CREATED_MAX_AGE_MS) return json({ error: "too_old" }, 409);
      const instant = b.status === "confirmée";
      if (!instant && b.status !== "en attente") return json({ error: "invalid_state" }, 409);
      await Promise.all([
        sendMail(guest?.email,
          instant ? `✅ Réservation confirmée — ${title}` : `📨 Demande envoyée — ${title}`,
          layout(instant ? "Réservation confirmée !" : "Demande envoyée !",
            `Bonjour ${esc(guestName)},<br><br>` + (instant
              ? `Votre réservation pour <strong>${esc(title)}</strong> est confirmée. Le prestataire a été prévenu.`
              : `Votre demande de réservation pour <strong>${esc(title)}</strong> a bien été transmise au prestataire. Vous recevrez un e-mail dès sa réponse.`),
            recapGuest, { label: "🧳 Voir mes voyages", url: SITE },
            "Pensez à vérifier vos spams si vous ne recevez pas nos e-mails.")),
        sendMail(exc?.contact_email,
          instant ? `🎉 Nouvelle réservation — ${title}` : `📨 Nouvelle demande de réservation — ${title}`,
          layout(instant ? "Nouvelle réservation" : "Nouvelle demande à traiter",
            `Bonjour ${esc(hostName)},<br><br><strong>${esc(guestName || "Un voyageur")}</strong> ` + (instant
              ? `a réservé <strong>${esc(title)}</strong> (réservation instantanée).`
              : `souhaite réserver <strong>${esc(title)}</strong>. Acceptez ou refusez la demande depuis votre espace, rubrique « Demandes d'excursions ».`),
            recapHost, { label: instant ? "Voir la réservation" : "Répondre à la demande", url: SITE })),
      ]);
    } else if (type === "decision") {
      if (exc?.owner_id !== uid) return json({ error: "not_owner" }, 403);
      if (b.status !== "confirmée" && b.status !== "refusée") return json({ error: "invalid_state" }, 409);
      const ok = b.status === "confirmée";
      const msg = String(body.host_message ?? "").trim().slice(0, 1000);
      await sendMail(guest?.email,
        ok ? `✅ Votre réservation est confirmée — ${title}` : `Votre demande n'a pas été retenue — ${title}`,
        layout(ok ? "Demande acceptée !" : "Demande non retenue",
          `Bonjour ${esc(guestName)},<br><br>` + (ok
            ? `Bonne nouvelle : le prestataire a accepté votre demande pour <strong>${esc(title)}</strong>. Votre réservation est confirmée.`
            : `Le prestataire n'a pas pu accepter votre demande pour <strong>${esc(title)}</strong>.`) + hostNote(msg),
          recapGuest, ok ? { label: "🧳 Voir mes voyages", url: SITE } : { label: "🔍 Voir d'autres excursions", url: SITE }));
    } else if (type === "cancelled") {
      if (b.guest_id !== uid) return json({ error: "not_guest" }, 403);
      if (b.status !== "annulée") return json({ error: "invalid_state" }, 409);
      // Motif et montant remboursable : lus en base (fn_guest_cancel_policy)
      const reason = b.cancel_reason
        ? `<div style="margin-top:14px;padding:10px 14px;border-left:3px solid #b42318;background:#fff5f5;"><strong>Motif :</strong> ${esc(b.cancel_reason)}</div>`
        : "";
      const onSite = /sur place/i.test(String(b.payment_method ?? ""));
      const refund = Number(b.refund_amount ?? 0);
      const money = onSite
        ? "Le paiement était prévu sur place : rien ne vous sera prélevé."
        : refund > 0
          ? `Vous serez remboursé de ${esc(Number(refund).toLocaleString("fr-FR", { maximumFractionDigits: 2 }))}€.`
          : "Selon la politique d'annulation de cette excursion, cette réservation n'est pas remboursable.";
      await Promise.all([
        sendMail(exc?.contact_email, `❌ Réservation annulée — ${title}`,
          layout("Réservation annulée",
            `Bonjour ${esc(hostName)},<br><br><strong>${esc(guestName || "Le voyageur")}</strong> a annulé sa réservation pour <strong>${esc(title)}</strong>. Les places sont de nouveau disponibles.${reason}`,
            recapBlock(b, title, null))),
        sendMail(guest?.email, `Votre annulation est confirmée — ${title}`,
          layout("Annulation confirmée",
            `Bonjour ${esc(guestName)},<br><br>Nous confirmons l'annulation de votre réservation pour <strong>${esc(title)}</strong>. ${money}${reason}`,
            recap, { label: "🔍 Voir d'autres excursions", url: SITE })),
      ]);
    } else {
      return json({ error: "type invalide" }, 400);
    }

    if (mailErrors.length) return json({ error: "mail_failed" }, 502);
    return json({ ok: true });
  } catch (err) {
    console.error("notify-excursion-booking:", (err as Error).message);
    return json({ error: (err as Error).message }, 500);
  }
});
