// =====================================================================
// MyTunigo — Edge Function "notify-excursion-booking"
// Réservations d'excursions : paiement en ligne et e-mails.
//
// Processus (18/10/2026, même principe que les logements) :
//   demande -> l'organisateur accepte -> le voyageur paie en ligne sous 24 h
//   -> réservation confirmée. Réservation instantanée : 30 min pour payer.
//   Excursion « paiement sur place » : acompte en ligne de 10 % (MyTunigo),
//   le reste se règle sur place. Sinon : prix + 8 % de taxes et frais en ligne.
//   Montants calculés en base (fn_excursion_booking_guard).
//
// Appel (POST JSON, avec le JWT de l'utilisateur connecté) :
//   { type: "created",   booking_id }                 (VOYAGEUR)
//       -> demande (en attente) : accusé au voyageur + alerte au prestataire.
//          Réservation instantanée (acceptée) : rien, le voyageur paie d'abord.
//   { type: "decision",  booking_id, host_message? }  (PRESTATAIRE)
//       -> voyageur : demande acceptée (lien de paiement, 24 h) ou refusée
//   { type: "confirm_payment", booking_id, method }   (VOYAGEUR)
//       -> vérifie voyageur + statut 'acceptée' + délai, passe en 'confirmée'
//          (mode test : aucun débit), e-mails voyageur + prestataire
//   { type: "cancelled", booking_id }                 (VOYAGEUR)
//       -> prestataire : annulation (motif) + voyageur : confirmation
//
// Appel par la tâche planifiée fn_auto_reject_expired_excursion_bookings()
// (toutes les 10 min) :
//   { type: "expire_pending" }
//       -> acceptées non payées dans le délai : 'expirée' + e-mail voyageur ;
//          demandes restées 'en attente' après la date : 'refusée' + e-mail.
//          Idempotent, sans paramètre ni destinataire fourni par l'appel.
//
// Sécurité : destinataires, montants et contenu lus en base ; l'appelant doit
// être le voyageur (created / confirm_payment / cancelled) ou le
// propriétaire de l'excursion (decision), et le statut doit correspondre.
// Le prestataire voit ce qu'il reçoit (et ce qu'il encaisse sur place),
// jamais les frais payés par le voyageur.
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
const fmtDateTime = (iso: string | null) =>
  iso
    ? new Date(iso).toLocaleString("fr-FR", {
        timeZone: "Africa/Tunis", day: "2-digit", month: "2-digit", year: "numeric",
        hour: "2-digit", minute: "2-digit",
      })
    : "—";
const money = (n: unknown) => `${Number(n ?? 0).toLocaleString("fr-FR", { maximumFractionDigits: 2 })}€`;

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

const row = (k: string, v: string) =>
  `<tr><td style="padding:5px 0;color:#6c757d;">${k}</td><td style="padding:5px 0;text-align:right;font-weight:600;">${v}</td></tr>`;
const table = (rows: string) =>
  `<table style="width:100%;border-collapse:collapse;font-size:14px;background:#f8f9fa;border-radius:8px;">
    <tbody style="display:block;padding:12px 14px;">${rows}</tbody></table>`;

// Récapitulatif voyageur : total, payé / à payer en ligne, reste sur place
// deno-lint-ignore no-explicit-any
function recapGuest(b: any, title: string) {
  const onSite = !!b.pay_on_site;
  const paid = !!b.paid_at;
  return table(
    row("Excursion", esc(title)) + row("Date", fmtDate(b.date)) +
    row("Participants", String(b.participants ?? 1)) + row("Référence", esc(b.reference ?? "—")) +
    (onSite
      ? row("Prix", money(b.total)) +
        row(paid ? "Acompte payé en ligne" : "Acompte à payer en ligne (10 %)", `<span style="color:#003580;">${money(b.online_amount)}</span>`) +
        row("Reste à payer sur place", `<span style="font-size:16px;color:#003580;">${money(b.on_site_amount)}</span>`)
      : row(paid ? "Total payé" : "Total à payer en ligne", `<span style="font-size:16px;color:#003580;">${money(b.total)}</span>`)),
  );
}

// Récapitulatif prestataire : ce qu'il reçoit (et encaisse sur place), sans les frais voyageur
// deno-lint-ignore no-explicit-any
function recapOwner(b: any, title: string, net: number | null, showMoney = true) {
  const onSite = !!b.pay_on_site;
  return table(
    row("Excursion", esc(title)) + row("Date", fmtDate(b.date)) +
    row("Participants", String(b.participants ?? 1)) + row("Référence", esc(b.reference ?? "—")) +
    (showMoney && onSite ? row("À encaisser sur place", `<span style="font-size:16px;color:#0a8f5c;">${money(b.on_site_amount)}</span>`) : "") +
    (showMoney && !onSite && net != null ? row("Vous recevez", `<span style="font-size:16px;color:#0a8f5c;">${money(net)}</span>`) : ""),
  );
}

// Montant reçu par le prestataire : reversement figé à la confirmation s'il
// existe, sinon devis calculé en base. null si indisponible.
// deno-lint-ignore no-explicit-any
async function hostNetFor(b: any): Promise<number | null> {
  const { data: pay } = await admin.from("booking_payouts").select("payout")
    .eq("kind", "excursion").eq("booking_id", b.id).maybeSingle();
  if (pay && pay.payout != null) return Number(pay.payout);
  const { data: q, error } = await admin.rpc("fn_commission_quote", { p_kind: "excursion", p_booking: b.id });
  if (error) { console.warn("devis commission :", error.message); return null; }
  const r = Array.isArray(q) ? q[0] : q;
  return r && r.payout != null ? Number(r.payout) : null;
}

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

const payUrl = (id: string) => `${SITE}/?payexc=${encodeURIComponent(id)}`;

// ---------- expirations (tâche planifiée) ----------
async function expirePending() {
  const nowIso = new Date().toISOString();
  const todayTn = new Date().toLocaleDateString("en-CA", { timeZone: "Africa/Tunis" }); // YYYY-MM-DD

  // 1. Acceptées non payées dans le délai -> 'expirée' (places libérées)
  const { data: unpaid, error: unpaidErr } = await admin.from("excursion_bookings")
    .update({ status: "expirée", expired_reason: "payment_timeout" })
    .eq("status", "acceptée")
    .lt("payment_deadline", nowIso)
    .select("*");
  if (unpaidErr) return json({ error: unpaidErr.message }, 500);

  // 2. Demandes restées 'en attente' après la date -> 'refusée'
  //    La mise à jour sert de « réservation » : seules les lignes réellement
  //    changées par cet appel reçoivent un e-mail.
  const { data: stale, error } = await admin.from("excursion_bookings")
    .update({ status: "refusée" })
    .eq("status", "en attente")
    .lt("date", todayTn)
    .select("*");
  if (error) return json({ error: error.message }, 500);

  for (const b of [...(unpaid ?? []), ...(stale ?? [])]) {
    const [{ data: exc }, { data: guest }] = await Promise.all([
      admin.from("excursions").select("title").eq("id", b.excursion_id).maybeSingle(),
      admin.from("profiles").select("email,first_name").eq("id", b.guest_id).maybeSingle(),
    ]);
    const title = exc?.title ?? "votre excursion";
    const isUnpaid = b.status === "expirée";
    await sendMail(guest?.email,
      (isUnpaid ? `⌛ Réservation annulée — paiement non effectué (${title})` : `Votre demande pour ${title} a expiré`).slice(0, 150),
      layout(isUnpaid ? "Délai de paiement dépassé" : "Demande expirée",
        `Bonjour ${esc(guest?.first_name ?? "")},<br><br>` + (isUnpaid
          ? `Le paiement de votre réservation pour <strong>${esc(title)}</strong> n'a pas été effectué dans le délai prévu. La réservation est annulée et les places ont été libérées. Aucun montant n'a été débité.`
          : `Le prestataire de <strong>${esc(title)}</strong> n'a pas répondu à votre demande avant la date de l'excursion. La demande est donc close.`),
        recapGuest(b, title), { label: "🔍 Voir d'autres excursions", url: SITE }));
  }
  return json({ ok: true, expired_unpaid: (unpaid ?? []).length, expired_pending: (stale ?? []).length });
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

    let { data: b, error: readErr } = await admin.from("excursion_bookings").select("*").eq("id", id).maybeSingle();
    if (readErr) return json({ error: readErr.message }, 500);
    if (!b) return json({ error: "not_found" }, 404);

    // ----- Paiement (mode test) -----
    if (type === "confirm_payment") {
      if (b.guest_id !== uid) return json({ error: "not_found" }, 404);
      if (b.status !== "acceptée") return json({ error: "not_acceptée" }, 409);
      const nowIso = new Date().toISOString();
      if (!b.payment_deadline || b.payment_deadline <= nowIso) return json({ error: "expired" }, 409);
      // TODO paiement réel : vérifier ici la transaction (ou la confirmer depuis
      // le webhook du prestataire de paiement). Mode test : aucun débit.
      const method = String(body.method ?? "card").replace(/[^a-z]/gi, "").slice(0, 12) || "card";
      const { data: upd, error: updErr } = await admin.from("excursion_bookings")
        .update({ status: "confirmée", paid_at: nowIso, payment_method: `${b.pay_on_site ? "Acompte en ligne + paiement sur place" : "en ligne"} (${method}, test)` })
        .eq("id", b.id).eq("status", "acceptée").gt("payment_deadline", nowIso)
        .select("*");
      if (updErr) return json({ error: updErr.message }, 500);
      if (!upd || !upd.length) return json({ error: "expired" }, 409);
      b = upd[0];
    }

    const [{ data: exc }, { data: guest }] = await Promise.all([
      admin.from("excursions").select("title,owner_id,contact_email,contact_firstname,instant_book").eq("id", b.excursion_id).maybeSingle(),
      admin.from("profiles").select("email,first_name").eq("id", b.guest_id).maybeSingle(),
    ]);
    const title = exc?.title ?? "votre excursion";
    const guestName = guest?.first_name ?? "";
    const hostName = exc?.contact_firstname ?? "";

    if (type === "created") {
      if (b.guest_id !== uid) return json({ error: "not_guest" }, 403);
      if (b.created_at && Date.now() - new Date(b.created_at).getTime() > CREATED_MAX_AGE_MS) return json({ error: "too_old" }, 409);
      // Réservation instantanée : aucun e-mail avant le paiement
      if (b.status === "acceptée") return json({ ok: true, waiting_payment: true });
      if (b.status !== "en attente") return json({ error: "invalid_state" }, 409);
      await Promise.all([
        sendMail(guest?.email, `📨 Demande envoyée — ${title}`,
          layout("Demande envoyée !",
            `Bonjour ${esc(guestName)},<br><br>Votre demande de réservation pour <strong>${esc(title)}</strong> a bien été transmise au prestataire.
             <br><br><strong>Aucun paiement n'est demandé pour l'instant.</strong> Dès que le prestataire acceptera, vous recevrez un e-mail avec un lien de paiement : vous aurez alors <strong>24 h pour payer en ligne</strong>${b.pay_on_site ? " l'acompte de 10 % (le reste se règle sur place)" : ""} et confirmer votre place.`,
            recapGuest(b, title), { label: "🧳 Suivre ma demande", url: SITE },
            "Pensez à vérifier vos spams si vous ne recevez pas nos e-mails.")),
        sendMail(exc?.contact_email, `📨 Nouvelle demande de réservation — ${title}`,
          layout("Nouvelle demande à traiter",
            `Bonjour ${esc(hostName)},<br><br><strong>${esc(guestName || "Un voyageur")}</strong> souhaite réserver <strong>${esc(title)}</strong>. Acceptez ou refusez la demande depuis votre espace, rubrique « Demandes d'excursions ».
             <br><br>Si vous acceptez, le voyageur aura 24 h pour payer en ligne ; sa place ne sera confirmée qu'après ce paiement.`,
            recapOwner(b, title, await hostNetFor(b)), { label: "Répondre à la demande", url: SITE })),
      ]);
    } else if (type === "decision") {
      if (exc?.owner_id !== uid) return json({ error: "not_owner" }, 403);
      if (b.status !== "acceptée" && b.status !== "refusée") return json({ error: "invalid_state" }, 409);
      const ok = b.status === "acceptée";
      const msg = String(body.host_message ?? "").trim().slice(0, 1000);
      await sendMail(guest?.email,
        ok ? `✅ Demande acceptée — payez sous 24 h pour confirmer (${title})` : `Votre demande n'a pas été retenue — ${title}`,
        layout(ok ? "Demande acceptée !" : "Demande non retenue",
          `Bonjour ${esc(guestName)},<br><br>` + (ok
            ? `Bonne nouvelle : le prestataire a accepté votre demande pour <strong>${esc(title)}</strong>.
               <br><br>Pour confirmer votre place, <strong>payez ${b.pay_on_site ? `l'acompte de ${money(b.online_amount)}` : money(b.total)} en ligne avant le ${fmtDateTime(b.payment_deadline)}</strong>. Passé ce délai, la demande sera annulée et les places remises en vente.`
            : `Le prestataire n'a pas pu accepter votre demande pour <strong>${esc(title)}</strong>. Aucun paiement n'a été effectué.`) + hostNote(msg),
          recapGuest(b, title),
          ok ? { label: "💳 Payer et confirmer", url: payUrl(b.id) } : { label: "🔍 Voir d'autres excursions", url: SITE },
          ok ? "Vous devrez être connecté avec le compte utilisé pour la demande." : ""));
    } else if (type === "confirm_payment") {
      const net = await hostNetFor(b);
      await Promise.all([
        sendMail(guest?.email, `🎉 Réservation confirmée — ${title}`,
          layout("Votre réservation est confirmée !",
            `Bonjour ${esc(guestName)},<br><br>Votre paiement a bien été enregistré. Votre place pour <strong>${esc(title)}</strong> est confirmée.` +
            (b.pay_on_site ? `<br><br>Le reste, <strong>${money(b.on_site_amount)}</strong>, est à régler sur place auprès de l'organisateur.` : ""),
            recapGuest(b, title) + codeBlock(b.booking_code, "guest", "excursion"),
            { label: "🧳 Voir mes voyages", url: SITE })),
        sendMail(exc?.contact_email, `🎉 Nouvelle réservation confirmée — ${title}`,
          layout("Une réservation est confirmée",
            `Bonjour ${esc(hostName)},<br><br><strong>${esc(guestName || "Un voyageur")}</strong> a payé en ligne : sa réservation pour <strong>${esc(title)}</strong> est confirmée.` +
            (b.pay_on_site ? `<br><br>Le voyageur vous réglera <strong>${money(b.on_site_amount)}</strong> sur place.` : ""),
            recapOwner(b, title, net) + codeBlock(b.booking_code, "host", "excursion"),
            { label: "Voir la réservation", url: SITE })),
      ]);
    } else if (type === "cancelled") {
      if (b.guest_id !== uid) return json({ error: "not_guest" }, 403);
      if (b.status !== "annulée") return json({ error: "invalid_state" }, 409);
      // Motif et montant remboursable : lus en base (fn_guest_cancel_policy)
      const reason = b.cancel_reason
        ? `<div style="margin-top:14px;padding:10px 14px;border-left:3px solid #b42318;background:#fff5f5;"><strong>Motif :</strong> ${esc(b.cancel_reason)}</div>`
        : "";
      const refund = Number(b.refund_amount ?? 0);
      const moneyTxt = !b.paid_at
        ? "Aucun paiement n'avait été effectué : rien ne vous sera prélevé."
        : refund > 0
          ? `Vous serez remboursé de ${money(refund)}.`
          : "Selon la politique d'annulation de cette excursion, le montant payé en ligne n'est pas remboursable.";
      await Promise.all([
        sendMail(exc?.contact_email, `❌ Réservation annulée — ${title}`,
          layout("Réservation annulée",
            `Bonjour ${esc(hostName)},<br><br><strong>${esc(guestName || "Le voyageur")}</strong> a annulé sa réservation pour <strong>${esc(title)}</strong>. Les places sont de nouveau disponibles.${reason}`,
            recapOwner(b, title, null, false))),
        sendMail(guest?.email, `Votre annulation est confirmée — ${title}`,
          layout("Annulation confirmée",
            `Bonjour ${esc(guestName)},<br><br>Nous confirmons l'annulation de votre réservation pour <strong>${esc(title)}</strong>. ${moneyTxt}${reason}`,
            recapGuest(b, title), { label: "🔍 Voir d'autres excursions", url: SITE })),
      ]);
    } else {
      return json({ error: "type invalide" }, 400);
    }

    if (mailErrors.length) return json({ ok: type === "confirm_payment", error: "mail_failed" }, type === "confirm_payment" ? 200 : 502);
    return json({ ok: true });
  } catch (err) {
    console.error("notify-excursion-booking:", (err as Error).message);
    return json({ error: (err as Error).message }, 500);
  }
});
