// =====================================================================
// MyTunigo — Edge Function "notify-review"
// E-mails liés aux avis sur les logements et les excursions.
//
// Appels (POST JSON) :
//   { type: "new_review", annonce_id }            (JWT du VOYAGEUR connecté)
//       -> e-mail à l'hôte : nouvel avis (ou avis modifié) sur son logement.
//   { type: "new_review", excursion_id }          (JWT du VOYAGEUR connecté)
//       -> e-mail au prestataire : nouvel avis sur son excursion.
//          L'avis est relu en base (auteur = appelant, mis à jour il y a
//          moins de 10 min) : le navigateur n'envoie ni destinataire ni texte.
//
//   { type: "review_requests" }                   (tâche planifiée pg_cron)
//       -> demandes d'avis aux voyageurs après leur séjour :
//          A) 1er e-mail : réservation 'terminée', départ + 24h passé,
//             jamais envoyé, pas encore d'avis ;
//          B) relance unique 24h après le 1er e-mail, toujours pas d'avis.
//          Même principe pour les excursions (excursion_bookings 'terminée',
//          le lendemain de l'excursion, puis une relance).
//          Traitement par lot et idempotent (chaque réservation est
//          « réservée » avant l'envoi) : un appel en trop n'envoie rien de plus.
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

const NEW_REVIEW_MAX_AGE_MS = 10 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

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
const fmtDateLong = (d: string | null) =>
  d ? new Date(String(d).slice(0, 10) + "T12:00:00Z").toLocaleDateString("fr-FR", { day: "numeric", month: "long", year: "numeric" }) : "";

function layout(title: string, intro: string, content: string, cta?: { label: string; url: string }, outro = "") {
  return `<!doctype html><html><body style="margin:0;background:#f3f6fa;font-family:-apple-system,'Segoe UI',Arial,sans-serif;color:#212529;">
  <div style="max-width:560px;margin:0 auto;padding:24px 16px;">
    <div style="background:#003580;color:#fff;border-radius:12px 12px 0 0;padding:20px 24px;">
      <div style="font-size:20px;font-weight:800;">My<span style="color:#FEBB02;">Tunigo</span></div>
      <div style="font-size:18px;font-weight:700;margin-top:8px;">${title}</div>
    </div>
    <div style="background:#fff;border-radius:0 0 12px 12px;padding:24px;border:1px solid #e9ecef;border-top:none;">
      <div style="font-size:15px;line-height:1.65;margin-bottom:18px;">${intro}</div>
      ${content}
      ${cta ? `<div style="text-align:center;margin:24px 0 8px;"><a href="${cta.url}" style="display:inline-block;background:#0071c2;color:#fff;text-decoration:none;font-weight:800;font-size:16px;padding:13px 28px;border-radius:8px;">${cta.label}</a></div>` : ""}
      ${outro ? `<div style="font-size:13px;color:#6c757d;line-height:1.6;margin-top:16px;">${outro}</div>` : ""}
    </div>
    <div style="text-align:center;font-size:12px;color:#adb5bd;margin-top:14px;">MyTunigo — mytunigo.com</div>
  </div></body></html>`;
}

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

// ---------- nouvel avis -> hôte ----------
async function newReview(req: Request, body: Record<string, unknown>) {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: userData } = await admin.auth.getUser(token);
  const uid = userData?.user?.id;
  if (!uid) return json({ error: "unauthorized" }, 401);

  const annonceId = String(body.annonce_id ?? "");
  const excursionId = String(body.excursion_id ?? "");
  if (!annonceId && !excursionId) return json({ error: "annonce_id ou excursion_id manquant" }, 400);
  const isExc = !annonceId;

  const { data: avis, error: avisErr } = await admin.from("avis")
    .select("rating,comment,created_at,updated_at")
    .eq("author_id", uid).eq(isExc ? "excursion_id" : "logement_id", isExc ? excursionId : annonceId).maybeSingle();
  if (avisErr) return json({ error: avisErr.message }, 500);
  if (!avis) return json({ error: "not_found" }, 404);
  const last = new Date(avis.updated_at ?? avis.created_at).getTime();
  if (Date.now() - last > NEW_REVIEW_MAX_AGE_MS) return json({ error: "too_old" }, 409);

  const [{ data: ann }, { data: author }] = await Promise.all([
    isExc
      ? admin.from("excursions").select("name:title,contact_email,contact_firstname").eq("id", excursionId).maybeSingle()
      : admin.from("annonces").select("name,contact_email,contact_firstname").eq("id", annonceId).maybeSingle(),
    admin.from("profiles").select("first_name").eq("id", uid).maybeSingle(),
  ]);
  if (!ann?.contact_email) return json({ error: "host_email_missing" }, 422);

  const rating = Math.max(1, Math.min(5, Number(avis.rating) || 0));
  const stars = "★".repeat(rating) + "☆".repeat(5 - rating);
  const comment = String(avis.comment ?? "").slice(0, 2000);
  const propName = ann.name ?? (isExc ? "votre excursion" : "votre hébergement");
  const reviewer = author?.first_name || "Un voyageur";

  await sendMail(
    ann.contact_email,
    `⭐ Nouvel avis ${rating}/5 sur ${propName}`.slice(0, 150),
    layout(
      "⭐ Nouvel avis",
      `Bonjour ${esc(ann.contact_firstname ?? "")},<br><br><strong>${esc(reviewer)}</strong> a laissé un avis sur <strong>${esc(propName)}</strong> :`,
      `<div style="background:#f8f9fa;border-radius:8px;padding:14px 16px;">
         <div style="font-size:20px;color:#e6a800;letter-spacing:2px;">${stars}</div>
         ${comment ? `<div style="font-size:15px;line-height:1.6;margin-top:8px;white-space:pre-wrap;">${esc(comment)}</div>` : ""}
       </div>`,
      { label: "Voir sur MyTunigo", url: isExc ? `${SITE}/?exc=${encodeURIComponent(excursionId)}` : SITE },
    ),
  );
  if (mailErrors.length) return json({ error: "mail_failed" }, 502);
  return json({ ok: true });
}

// ---------- demandes d'avis aux voyageurs (lot) ----------
// deno-lint-ignore no-explicit-any
async function sendRequest(r: any, kind: "request" | "reminder") {
  const [{ data: guest }, { data: ann }] = await Promise.all([
    admin.from("profiles").select("email,first_name").eq("id", r.guest_id).maybeSingle(),
    admin.from("annonces").select("name,city").eq("id", r.logement_id).maybeSingle(),
  ]);
  const propName = ann?.name ?? "";
  const reminder = kind === "reminder";
  const subject = reminder
    ? `⭐ On attend toujours votre avis${propName ? " sur " + propName : ""}`
    : `⭐ Comment s'est passé votre séjour${ann?.city ? " à " + ann.city : ""} ?`;
  return sendMail(
    guest?.email,
    subject.slice(0, 150),
    layout(
      reminder ? "Votre avis compte" : "Comment s'est passé votre séjour ?",
      `Bonjour ${esc(guest?.first_name ?? "")},<br><br>` + (reminder
        ? `Vous n'avez pas encore laissé d'avis sur votre séjour${propName ? ` à <strong>${esc(propName)}</strong>` : ""} (départ le ${fmtDateLong(r.check_out)}).`
        : `Votre séjour${propName ? ` à <strong>${esc(propName)}</strong>` : ""} s'est terminé le ${fmtDateLong(r.check_out)}. Nous espérons que tout s'est bien passé !`)
        + `<br><br>Votre avis (note + commentaire) aide les futurs voyageurs et votre hôte. Cela ne prend qu'une minute.`,
      "",
      { label: "⭐ Laisser un avis", url: SITE },
      `Réservation ${esc(r.reference ?? "")}`,
    ),
  );
}

// En cas d'erreur de lecture, on lève une exception plutôt que de supposer
// « pas d'avis » : mieux vaut ne rien envoyer qu'envoyer à tort.
// deno-lint-ignore no-explicit-any
async function hasReview(r: any) {
  const { count, error } = await admin.from("avis").select("id", { count: "exact", head: true })
    .eq("logement_id", r.logement_id).eq("author_id", r.guest_id);
  if (error) throw new Error(`lecture avis : ${error.message}`);
  return (count ?? 0) > 0;
}

// ---------- demandes d'avis après une excursion ----------
// deno-lint-ignore no-explicit-any
async function sendExcRequest(b: any, kind: "request" | "reminder") {
  const [{ data: guest }, { data: exc }] = await Promise.all([
    admin.from("profiles").select("email,first_name").eq("id", b.guest_id).maybeSingle(),
    admin.from("excursions").select("title,city").eq("id", b.excursion_id).maybeSingle(),
  ]);
  const title = exc?.title ?? "";
  const reminder = kind === "reminder";
  const subject = reminder
    ? `⭐ On attend toujours votre avis${title ? " sur " + title : ""}`
    : `⭐ Comment s'est passée votre excursion${title ? " « " + title + " »" : ""} ?`;
  return sendMail(
    guest?.email,
    subject.slice(0, 150),
    layout(
      reminder ? "Votre avis compte" : "Comment s'est passée votre excursion ?",
      `Bonjour ${esc(guest?.first_name ?? "")},<br><br>` + (reminder
        ? `Vous n'avez pas encore laissé d'avis sur votre excursion${title ? ` <strong>${esc(title)}</strong>` : ""} du ${fmtDateLong(b.date)}.`
        : `Votre excursion${title ? ` <strong>${esc(title)}</strong>` : ""}${exc?.city ? ` à ${esc(exc.city)}` : ""} a eu lieu le ${fmtDateLong(b.date)}. Nous espérons que vous avez passé un excellent moment !`)
        + `<br><br>Votre avis (note + commentaire) aide les futurs voyageurs et le prestataire. Rendez-vous dans « Mes voyages », onglet Excursions : cela ne prend qu'une minute.`,
      "",
      { label: "⭐ Laisser un avis", url: SITE },
      `Réservation ${esc(b.reference ?? "")}`,
    ),
  );
}

// deno-lint-ignore no-explicit-any
async function hasExcReview(b: any) {
  const { count, error } = await admin.from("avis").select("id", { count: "exact", head: true })
    .eq("excursion_id", b.excursion_id).eq("author_id", b.guest_id);
  if (error) throw new Error(`lecture avis : ${error.message}`);
  return (count ?? 0) > 0;
}

async function excursionReviewRequests(now: number) {
  let sent = 0, reminded = 0;
  // A) premier e-mail : excursion terminée (passée), jamais envoyé
  const { data: firsts, error: e1 } = await admin.from("excursion_bookings")
    .select("id,guest_id,excursion_id,date,reference")
    .eq("status", "terminée").is("review_email_sent_at", null)
    .lte("date", new Date(now - DAY_MS).toISOString().slice(0, 10));
  if (e1) throw new Error(`excursion_bookings : ${e1.message}`);
  for (const b of firsts ?? []) {
    if (await hasExcReview(b)) continue;
    const { data: claimed, error: claimErr } = await admin.from("excursion_bookings")
      .update({ review_email_sent_at: new Date().toISOString() })
      .eq("id", b.id).is("review_email_sent_at", null).select("id");
    if (claimErr) throw new Error(`réservation d'excursion ${b.id} : ${claimErr.message}`);
    if (!claimed?.length) continue;
    if (await sendExcRequest(b, "request")) sent++;
  }
  // B) relance unique 24 h après le premier e-mail
  const { data: seconds, error: e2 } = await admin.from("excursion_bookings")
    .select("id,guest_id,excursion_id,date,reference")
    .eq("status", "terminée").is("review_reminder_sent_at", null)
    .not("review_email_sent_at", "is", null)
    .lte("review_email_sent_at", new Date(now - DAY_MS).toISOString());
  if (e2) throw new Error(`excursion_bookings : ${e2.message}`);
  for (const b of seconds ?? []) {
    if (await hasExcReview(b)) continue;
    const { data: claimed, error: claimErr } = await admin.from("excursion_bookings")
      .update({ review_reminder_sent_at: new Date().toISOString() })
      .eq("id", b.id).is("review_reminder_sent_at", null).select("id");
    if (claimErr) throw new Error(`réservation d'excursion ${b.id} : ${claimErr.message}`);
    if (!claimed?.length) continue;
    if (await sendExcRequest(b, "reminder")) reminded++;
  }
  return { sent, reminded };
}

async function reviewRequests() {
  const now = Date.now();
  let sent = 0, reminded = 0;

  // A) premier e-mail
  const { data: firsts, error: e1 } = await admin.from("reservations")
    .select("id,guest_id,logement_id,check_out,reference")
    .eq("status", "terminée").is("review_email_sent_at", null)
    .lte("check_out", new Date(now - DAY_MS).toISOString().slice(0, 10));
  if (e1) return json({ error: e1.message }, 500);
  for (const r of firsts ?? []) {
    if (await hasReview(r)) continue;
    // « Réserve » la réservation avant d'envoyer : un appel concurrent ne la reprendra pas.
    const { data: claimed, error: claimErr } = await admin.from("reservations")
      .update({ review_email_sent_at: new Date().toISOString() })
      .eq("id", r.id).is("review_email_sent_at", null).select("id");
    if (claimErr) throw new Error(`réservation ${r.id} : ${claimErr.message}`);
    if (!claimed?.length) continue;
    if (await sendRequest(r, "request")) sent++;
  }

  // B) relance unique
  const { data: seconds, error: e2 } = await admin.from("reservations")
    .select("id,guest_id,logement_id,check_out,reference")
    .eq("status", "terminée").is("review_reminder_sent_at", null)
    .not("review_email_sent_at", "is", null)
    .lte("review_email_sent_at", new Date(now - DAY_MS).toISOString());
  if (e2) return json({ error: e2.message }, 500);
  for (const r of seconds ?? []) {
    if (await hasReview(r)) continue;
    const { data: claimed, error: claimErr } = await admin.from("reservations")
      .update({ review_reminder_sent_at: new Date().toISOString() })
      .eq("id", r.id).is("review_reminder_sent_at", null).select("id");
    if (claimErr) throw new Error(`réservation ${r.id} : ${claimErr.message}`);
    if (!claimed?.length) continue;
    if (await sendRequest(r, "reminder")) reminded++;
  }

  const exc = await excursionReviewRequests(now);
  return json({ ok: true, sent, reminded, excursions_sent: exc.sent, excursions_reminded: exc.reminded });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  mailErrors = [];
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* corps vide */ }
  try {
    switch (body.type) {
      case "new_review":
        return await newReview(req, body);
      case "review_requests":
        return await reviewRequests();
      default:
        return json({ error: "type invalide" }, 400);
    }
  } catch (err) {
    console.error("notify-review:", (err as Error).message);
    return json({ error: (err as Error).message }, 500);
  }
});
