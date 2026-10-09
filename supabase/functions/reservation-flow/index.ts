// =====================================================================
// MyTunigo — Edge Function "reservation-flow"
// Processus de réservation des logements après la demande du voyageur.
//
// Actions (POST JSON) :
//   { action: "notify", type: "request_created", reservation_id }
//       -> e-mails : accusé de réception au voyageur + alerte à l'hôte
//   { action: "notify", type: "accepted", reservation_id, host_message? }
//       -> e-mail au voyageur : demande acceptée, lien de paiement, 24h,
//          + excursions publiées à moins de 50 km du logement
//   { action: "confirm_payment", reservation_id, method }   (JWT du voyageur)
//       -> vérifie propriétaire + statut 'acceptée' + délai, passe en
//          'confirmée', refuse les autres demandes en attente sur ces dates,
//          e-mails au voyageur (+ excursions à moins de 50 km), à l'hôte
//          et aux voyageurs refusés
//   { action: "expire" }
//       -> 'acceptée' dont le délai de paiement est dépassé -> 'expirée',
//          e-mails au voyageur et à l'hôte. Idempotent (appelé par pg_cron
//          toutes les 10 min et par le site avant chaque vérification).
//
// Secrets utilisés (Supabase > Edge Functions > Secrets) :
//   RESEND_API_KEY           (déjà utilisé par les autres fonctions)
//   RESEND_FROM   (facultatif) défaut : "MyTunigo <noreply@mytunigo.com>"
//   SITE_URL      (facultatif) défaut : "https://mytunigo.com"
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY : fournis automatiquement
// =====================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
// Clé serveur : le secret personnalisé SB_SERVICE_ROLE_KEY du projet en priorité,
// sinon la clé fournie par défaut par Supabase.
const SERVICE_KEY = Deno.env.get("SB_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM = Deno.env.get("RESEND_FROM") ?? "MyTunigo <noreply@mytunigo.com>";
const SUPPORT_EMAIL = Deno.env.get("SUPPORT_EMAIL") ?? "contact@mytunigo.com";
const SITE = (Deno.env.get("SITE_URL") ?? "https://mytunigo.com").replace(/\/$/, "");

const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

// Erreurs d'envoi de la requête en cours, renvoyées dans la réponse JSON
// (champ "mail_errors") pour pouvoir diagnostiquer depuis le navigateur.
let mailErrors: string[] = [];

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => {
  const payload = (mailErrors.length && body && typeof body === "object")
    ? { ...(body as Record<string, unknown>), mail_errors: mailErrors }
    : body;
  return new Response(JSON.stringify(payload), { status, headers: { ...cors, "Content-Type": "application/json" } });
};

// ---------- formatage ----------
const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const fmtDate = (d: string | null) => {
  if (!d) return "—";
  const [y, m, dd] = String(d).slice(0, 10).split("-");
  return `${dd}/${m}/${y}`;
};
const fmtDateTime = (iso: string | null) =>
  iso
    ? new Date(iso).toLocaleString("fr-FR", {
        timeZone: "Europe/Paris", day: "2-digit", month: "2-digit", year: "numeric",
        hour: "2-digit", minute: "2-digit",
      })
    : "—";

// ---------- e-mails ----------
async function sendMail(to: string | null | undefined, subject: string, html: string, replyTo?: string) {
  if (!to) { mailErrors.push(`destinataire vide pour « ${subject} »`); return; }
  if (!RESEND_API_KEY) { mailErrors.push("RESEND_API_KEY manquant dans les secrets"); console.error("RESEND_API_KEY manquant"); return; }
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [to], subject, html, ...(replyTo ? { reply_to: replyTo } : {}) }),
  });
  if (!r.ok) {
    const txt = await r.text();
    mailErrors.push(`Resend ${r.status} (from: ${FROM}, to: ${to}) : ${txt}`);
    console.error("Resend", r.status, txt);
  }
}

function layout(title: string, intro: string, recap: string, cta?: { label: string; url: string }, outro = "", extra = "") {
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
      ${extra}
    </div>
    <div style="text-align:center;font-size:12px;color:#adb5bd;margin-top:14px;">MyTunigo — mytunigo.com</div>
  </div></body></html>`;
}

// deno-lint-ignore no-explicit-any
function recapBlock(r: any, propName: string) {
  const row = (k: string, v: string) =>
    `<tr><td style="padding:5px 0;color:#6c757d;">${k}</td><td style="padding:5px 0;text-align:right;font-weight:600;">${v}</td></tr>`;
  return `<table style="width:100%;border-collapse:collapse;font-size:14px;background:#f8f9fa;border-radius:8px;padding:12px;">
    <tbody style="display:block;padding:12px 14px;">
      ${row("Hébergement", esc(propName))}
      ${row("Arrivée", fmtDate(r.check_in))}
      ${row("Départ", fmtDate(r.check_out))}
      ${row("Voyageurs", String(r.guests_count ?? 1))}
      ${row("Référence", esc(r.reference ?? "—"))}
      ${row("Total", `<span style="color:#003580;font-size:16px;">${esc(r.total)}€</span>`)}
    </tbody></table>`;
}

// Excursions publiées à moins de 50 km du logement (fonction SQL
// fn_excursions_near_annonce), des mieux notées aux moins bien notées.
// Bloc facultatif : en cas d'erreur ou s'il n'y en a aucune, rien n'est ajouté.
const NEAR_MAX_IN_MAIL = 15;
async function nearbyExcursionsBlock(logementId: string | null | undefined): Promise<string> {
  if (!logementId) return "";
  const { data, error } = await admin.rpc("fn_excursions_near_annonce", { p_annonce_id: logementId, p_radius_km: 50 });
  if (error) { console.error("fn_excursions_near_annonce", error.message); return ""; }
  // deno-lint-ignore no-explicit-any
  const rows = (data ?? []) as any[];
  if (!rows.length) return "";
  const shown = rows.slice(0, NEAR_MAX_IN_MAIL);
  const items = shown.map((x) => {
    const n = Number(x.review_count) || 0;
    const note = n ? `⭐ ${Number(x.rating).toFixed(1).replace(".", ",")} (${n} avis)` : "Nouveau";
    const dist = x.distance_km != null ? `${String(x.distance_km).replace(".", ",")} km` : "même région";
    const img = x.photo && /^https:\/\//.test(String(x.photo))
      ? `<td style="width:72px;padding:0 12px 0 0;vertical-align:top;"><img src="${esc(x.photo)}" alt="" width="72" height="56" style="display:block;width:72px;height:56px;object-fit:cover;border-radius:6px;"></td>`
      : "";
    return `<tr><td style="padding:10px 0;border-top:1px solid #e9ecef;">
      <table style="width:100%;border-collapse:collapse;"><tr>${img}
        <td style="vertical-align:top;font-size:14px;line-height:1.5;">
          <a href="${SITE}/?exc=${encodeURIComponent(String(x.id))}" style="color:#003580;font-weight:700;text-decoration:none;">${esc(x.title)}</a><br>
          <span style="color:#6c757d;font-size:13px;">📍 ${esc(x.city ?? "")} · ${dist} · ${note}</span>
        </td>
        <td style="vertical-align:top;text-align:right;white-space:nowrap;font-size:14px;font-weight:800;">${esc(x.price)}€<br><span style="font-weight:400;color:#6c757d;font-size:12px;">/ ${esc(x.price_type ?? "personne")}</span></td>
      </tr></table></td></tr>`;
  }).join("");
  const more = rows.length > shown.length
    ? `<div style="font-size:13px;margin-top:8px;"><a href="${SITE}" style="color:#0071c2;">et ${rows.length - shown.length} autre(s) à découvrir sur MyTunigo</a></div>`
    : "";
  return `<div style="margin-top:24px;padding-top:18px;border-top:2px solid #FEBB02;">
    <div style="font-size:16px;font-weight:800;margin-bottom:4px;">🧭 Excursions à moins de 50 km de votre logement</div>
    <div style="font-size:13px;color:#6c757d;margin-bottom:6px;">Profitez de votre séjour : voici les excursions proches, les mieux notées en premier.</div>
    <table style="width:100%;border-collapse:collapse;">${items}</table>
    ${more}
  </div>`;
}

// deno-lint-ignore no-explicit-any
async function loadContext(r: any) {
  const [{ data: ann, error: annErr }, { data: guest, error: guestErr }] = await Promise.all([
    admin.from("annonces").select("name,contact_email,contact_firstname").eq("id", r.logement_id).maybeSingle(),
    admin.from("profiles").select("email,first_name").eq("id", r.guest_id).maybeSingle(),
  ]);
  if (annErr) mailErrors.push(`lecture annonces : ${annErr.message}`);
  if (guestErr) mailErrors.push(`lecture profiles : ${guestErr.message}`);
  return {
    propName: ann?.name ?? "votre hébergement",
    hostEmail: ann?.contact_email ?? null,
    hostName: ann?.contact_firstname ?? "",
    guestEmail: guest?.email ?? null,
    guestName: guest?.first_name ?? "",
  };
}

// ---------- actions ----------
// deno-lint-ignore no-explicit-any
async function notifyAccepted(body: any) {
  const { data: r, error: readErr } = await admin.from("reservations").select("*").eq("id", body.reservation_id).maybeSingle();
  if (readErr) return json({ error: readErr.message }, 500);
  if (!r) return json({ error: "not_found" }, 404);
  if (r.status !== "acceptée") return json({ error: "not_acceptée" }, 409);
  const [c, nearby] = await Promise.all([loadContext(r), nearbyExcursionsBlock(r.logement_id)]);
  const hostMsg = (body.host_message ?? "").toString().trim();
  await sendMail(
    c.guestEmail,
    `✅ Demande acceptée — finalisez votre réservation sous 24h`,
    layout(
      "Votre demande est acceptée !",
      `Bonjour ${esc(c.guestName) || ""},<br><br>Bonne nouvelle : l'hôte de <strong>${esc(c.propName)}</strong> a accepté votre demande.
       <br><br>Pour confirmer votre séjour, <strong>finalisez le paiement avant le ${fmtDateTime(r.payment_deadline)}</strong>.
       Passé ce délai, la demande sera annulée automatiquement et les dates seront remises en location.
       ${hostMsg ? `<div style="margin-top:14px;padding:10px 14px;border-left:3px solid #0071c2;background:#f0f7ff;font-style:italic;">« ${esc(hostMsg)} »<br><span style="font-style:normal;font-size:12px;color:#6c757d;">— votre hôte</span></div>` : ""}`,
      recapBlock(r, c.propName),
      { label: "💳 Payer et confirmer", url: `${SITE}/?pay=${r.id}` },
      "Vous devrez être connecté avec le compte utilisé pour la demande.",
      nearby,
    ),
  );
  return json({ ok: true });
}

// deno-lint-ignore no-explicit-any
async function notifyRequestCreated(body: any) {
  const { data: r, error: readErr } = await admin.from("reservations").select("*").eq("id", body.reservation_id).maybeSingle();
  if (readErr) return json({ error: readErr.message }, 500);
  if (!r) return json({ error: "not_found" }, 404);
  // Anti-renvoi : uniquement pour une demande en attente créée il y a moins de 10 min.
  if (r.status !== "en attente" || Date.now() - new Date(r.created_at).getTime() > 10 * 60 * 1000) {
    return json({ error: "too_late" }, 409);
  }
  const c = await loadContext(r);
  await Promise.all([
    sendMail(
      c.guestEmail,
      `📨 Demande envoyée — ${c.propName}`,
      layout("Demande envoyée !",
        `Bonjour ${esc(c.guestName)},<br><br>Votre demande de réservation pour <strong>${esc(c.propName)}</strong> a bien été enregistrée et transmise à l'hôte. Elle reste en attente jusqu'à sa réponse.
         <br><br><strong>Aucun paiement n'est demandé pour l'instant.</strong> Dès que l'hôte acceptera, vous recevrez un e-mail avec un lien de paiement : vous aurez alors <strong>24h pour payer en ligne</strong> et confirmer votre séjour.`,
        recapBlock(r, c.propName),
        { label: "📅 Suivre ma demande", url: SITE }),
    ),
    sendMail(
      c.hostEmail,
      `📨 Nouvelle demande de réservation — ${c.propName}`,
      layout("Nouvelle demande de réservation",
        `Bonjour ${esc(c.hostName)},<br><br>${esc(c.guestName) || "Un voyageur"} souhaite réserver <strong>${esc(c.propName)}</strong>. Les dates ne sont pas encore bloquées : d'autres voyageurs peuvent demander la même période, c'est vous qui choisissez.
         <br><br>Si vous acceptez, le voyageur aura <strong>24h pour payer</strong> ; pendant ce délai les dates seront bloquées.
         ${r.notes ? `<div style="margin-top:14px;padding:10px 14px;border-left:3px solid #0071c2;background:#f0f7ff;font-style:italic;">« ${esc(r.notes)} »</div>` : ""}`,
        recapBlock(r, c.propName),
        { label: "✅ Répondre à la demande", url: SITE }),
    ),
  ]);
  return json({ ok: true });
}

// deno-lint-ignore no-explicit-any
async function confirmPayment(req: Request, body: any) {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: userData } = await admin.auth.getUser(token);
  const user = userData?.user;
  if (!user) return json({ error: "unauthenticated" }, 401);

  const { data: current, error: readErr } = await admin.from("reservations").select("*").eq("id", body.reservation_id).maybeSingle();
  if (readErr) return json({ error: readErr.message }, 500);
  if (!current || current.guest_id !== user.id) return json({ error: "not_found" }, 404);
  if (current.status !== "acceptée") return json({ error: "not_acceptée" }, 409);
  if (!current.payment_deadline || new Date(current.payment_deadline) <= new Date()) {
    return json({ error: "expired" }, 409);
  }

  // TODO paiement réel : vérifier ici la transaction auprès du prestataire
  // (ou déplacer cette confirmation dans son webhook). Mode test pour l'instant.
  const nowIso = new Date().toISOString();
  const { data: updated, error } = await admin
    .from("reservations")
    .update({ status: "confirmée", paid_at: nowIso, payment_method: `${body.method ?? "card"} (test)` })
    .eq("id", current.id)
    .eq("status", "acceptée")
    .gt("payment_deadline", nowIso)
    .select("*");
  if (error) return json({ error: error.message }, 500);
  if (!updated || !updated.length) return json({ error: "expired" }, 409);
  const r = updated[0];

  const [c, nearby] = await Promise.all([loadContext(r), nearbyExcursionsBlock(r.logement_id)]);
  await Promise.all([
    sendMail(
      c.guestEmail,
      `🎉 Réservation confirmée — ${c.propName}`,
      layout("Votre réservation est confirmée !",
        `Bonjour ${esc(c.guestName)},<br><br>Votre paiement a bien été enregistré. Votre séjour à <strong>${esc(c.propName)}</strong> est confirmé.`,
        recapBlock(r, c.propName),
        { label: "🧳 Voir mes voyages", url: SITE },
        "", nearby),
    ),
    sendMail(
      c.hostEmail,
      `🎉 Réservation confirmée et payée — ${c.propName}`,
      layout("Une réservation est confirmée",
        `Bonjour ${esc(c.hostName)},<br><br>Le voyageur a payé : la réservation pour <strong>${esc(c.propName)}</strong> est confirmée. Les dates sont bloquées dans votre calendrier.`,
        recapBlock(r, c.propName),
        { label: "📨 Gérer mes réservations", url: SITE }),
    ),
  ]);

  // Les autres demandes en attente sur ces dates ne peuvent plus aboutir.
  const { data: refused } = await admin
    .from("reservations")
    .update({ status: "refusée", expired_reason: "dates_taken" })
    .eq("logement_id", r.logement_id)
    .eq("status", "en attente")
    .neq("id", r.id)
    .lt("check_in", r.check_out)
    .gt("check_out", r.check_in)
    .select("*");
  for (const o of refused ?? []) {
    const oc = await loadContext(o);
    await sendMail(
      oc.guestEmail,
      `Votre demande pour ${oc.propName} n'a pas pu aboutir`,
      layout("Dates plus disponibles",
        `Bonjour ${esc(oc.guestName)},<br><br>Les dates que vous aviez demandées pour <strong>${esc(oc.propName)}</strong> viennent d'être réservées par un autre voyageur. Votre demande est donc annulée — aucun paiement n'a été effectué.`,
        recapBlock(o, oc.propName),
        { label: "🔍 Trouver un autre logement", url: SITE }),
    );
  }

  return json({ ok: true, refused_overlapping: (refused ?? []).length });
}

async function expire() {
  const nowIso = new Date().toISOString();
  const { data: expired, error } = await admin
    .from("reservations")
    .update({ status: "expirée", expired_reason: "payment_timeout" })
    .eq("status", "acceptée")
    .lt("payment_deadline", nowIso)
    .select("*");
  if (error) return json({ error: error.message }, 500);

  for (const r of expired ?? []) {
    const c = await loadContext(r);
    await Promise.all([
      sendMail(
        c.guestEmail,
        `⌛ Réservation annulée — délai de paiement dépassé`,
        layout("Délai de paiement dépassé",
          `Bonjour ${esc(c.guestName)},<br><br>Le paiement de votre réservation pour <strong>${esc(c.propName)}</strong> n'a pas été effectué dans les 24h suivant l'accord de l'hôte. La réservation est annulée et les dates ont été libérées. Aucun montant n'a été débité.`,
          recapBlock(r, c.propName),
          { label: "🔍 Refaire une demande", url: SITE }),
      ),
      sendMail(
        c.hostEmail,
        `⌛ Réservation non payée — dates libérées (${c.propName})`,
        layout("Réservation non finalisée",
          `Bonjour ${esc(c.hostName)},<br><br>Le voyageur n'a pas payé dans les 24h la réservation que vous aviez acceptée pour <strong>${esc(c.propName)}</strong>. Elle est annulée et les dates sont à nouveau disponibles. Si d'autres demandes sont en attente sur ces dates, vous pouvez maintenant les accepter.`,
          recapBlock(r, c.propName),
          { label: "📨 Voir les demandes", url: SITE }),
      ),
    ]);
  }

  // Demandes restées « en attente » dont la date d'arrivée est passée sans
  // réponse de l'hôte : elles n'ont plus d'objet → 'expirée' (no_host_reply).
  const todayTn = new Date().toLocaleDateString("en-CA", { timeZone: "Africa/Tunis" }); // YYYY-MM-DD
  const { data: stale, error: staleErr } = await admin
    .from("reservations")
    .update({ status: "expirée", expired_reason: "no_host_reply" })
    .eq("status", "en attente")
    .lte("check_in", todayTn)
    .select("*");
  if (staleErr) return json({ error: staleErr.message }, 500);

  // Réservations acceptées mais pas encore payées dont l'arrivée est arrivée :
  // on ne paie plus un séjour dont la date d'arrivée est passée → 'expirée' (checkin_passed).
  const { data: lateAccepted, error: lateErr } = await admin
    .from("reservations")
    .update({ status: "expirée", expired_reason: "checkin_passed" })
    .eq("status", "acceptée")
    .lt("check_in", todayTn)
    .select("*");
  if (lateErr) return json({ error: lateErr.message }, 500);

  for (const r of [...(stale ?? []), ...(lateAccepted ?? [])]) {
    const c = await loadContext(r);
    await sendMail(
      c.guestEmail,
      `Votre demande pour ${c.propName} a expiré`,
      layout("Demande expirée",
        r.expired_reason === "checkin_passed"
          ? `Bonjour ${esc(c.guestName)},<br><br>Le paiement de votre réservation pour <strong>${esc(c.propName)}</strong> n'a pas été effectué avant la date d'arrivée. La réservation est close — aucun montant n'a été débité.`
          : `Bonjour ${esc(c.guestName)},<br><br>L'hôte de <strong>${esc(c.propName)}</strong> n'a pas répondu à votre demande avant la date d'arrivée prévue. La demande est donc close — aucun paiement n'a été effectué.`,
        recapBlock(r, c.propName),
        { label: "🔍 Trouver un autre logement", url: SITE }),
    );
  }

  return json({ ok: true, expired: (expired ?? []).length, expired_no_reply: (stale ?? []).length, expired_checkin_passed: (lateAccepted ?? []).length });
}

// ── Formulaire « Contacter le support » (utilisateur connecté uniquement) ──
// Le mail part vers SUPPORT_EMAIL avec reply_to = e-mail de l'utilisateur :
// il suffit de cliquer « Répondre » dans Gmail pour lui écrire.
async function supportMessage(req: Request, body: Record<string, unknown>) {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: userData } = await admin.auth.getUser(token);
  const user = userData?.user;
  if (!user?.email) return json({ error: "unauthorized" }, 401);

  const message = String(body.message ?? "").trim();
  const subject = String(body.subject ?? "").trim().slice(0, 120) || "Aide réservation";
  const ref = String(body.reference ?? "").trim().slice(0, 40);
  if (message.length < 10 || message.length > 3000) return json({ error: "invalid_message" }, 400);

  const { data: prof } = await admin.from("profiles").select("first_name,last_name").eq("id", user.id).maybeSingle();
  const name = [prof?.first_name, prof?.last_name].filter(Boolean).join(" ") || user.email;

  const recap = `<table style="width:100%;font-size:14px;border-collapse:collapse;">
      <tr><td style="color:#6c757d;padding:4px 0;width:130px;">De</td><td><strong>${esc(name)}</strong> — ${esc(user.email)}</td></tr>
      ${ref ? `<tr><td style="color:#6c757d;padding:4px 0;">Réservation</td><td><strong>${esc(ref)}</strong></td></tr>` : ""}
    </table>
    <div style="margin-top:14px;padding:14px;background:#f8f9fa;border-radius:8px;white-space:pre-wrap;font-size:14px;line-height:1.6;">${esc(message)}</div>`;

  await sendMail(SUPPORT_EMAIL, `🆘 Support — ${subject}${ref ? " (" + ref + ")" : ""}`,
    layout("Nouveau message support", `Message envoyé depuis le site. Répondez directement à cet e-mail pour écrire à ${esc(name)}.`, recap),
    user.email);
  await sendMail(user.email, "Nous avons bien reçu votre message",
    layout("Message reçu", `Bonjour ${esc(prof?.first_name || "")},<br><br>Votre message a bien été transmis à l'équipe MyTunigo. Nous vous répondrons par e-mail à cette adresse.`, recap));

  if (mailErrors.length) return json({ error: "mail_failed", mail_errors: mailErrors }, 502);
  return json({ ok: true });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  mailErrors = [];
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* corps vide */ }
  try {
    switch (body.action) {
      case "notify":
        if (body.type === "accepted") return await notifyAccepted(body);
        if (body.type === "request_created") return await notifyRequestCreated(body);
        return json({ error: "unknown_type" }, 400);
      case "confirm_payment":
        return await confirmPayment(req, body);
      case "expire":
        return await expire();
      case "support":
        return await supportMessage(req, body);
      default:
        return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    console.error("reservation-flow", e);
    return json({ error: (e as Error).message }, 500);
  }
});
