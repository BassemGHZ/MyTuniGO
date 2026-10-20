// =====================================================================
// MyTunigo — Edge Function "notify-admin"
// E-mails liés à la modération des annonces et des excursions.
//
// Appel (POST JSON, avec le JWT de l'utilisateur connecté) :
//   { action, kind: "annonce" | "excursion", id }
//
//   action "submitted"        (PROPRIÉTAIRE) dépôt ou modification
//       -> e-mail à l'admin (à valider) + accusé de réception au propriétaire
//   action "validated"        (ADMIN) statut 'publiée' -> e-mail au propriétaire
//   action "rejected"         (ADMIN) statut 'rejetée' -> e-mail au propriétaire
//   action "changes_applied"  (ADMIN, annonce) modifs en ligne -> propriétaire
//   action "changes_rejected" (ADMIN, annonce) modifs refusées -> propriétaire
//   action "founder_granted"  (ADMIN, annonce) badge « Hôte fondateur »
//       attribué (annonces.founder_since renseigné) -> e-mail à l'hôte
//
// Sécurité : destinataires et contenu lus en base. L'admin est reconnu par
// app_metadata.role = 'admin' (non modifiable par l'utilisateur, contrairement
// à user_metadata).
//
// Secrets : RESEND_API_KEY, SB_SERVICE_ROLE_KEY (ou SUPABASE_SERVICE_ROLE_KEY).
// Facultatif : ADMIN_EMAIL (défaut admin@mytunigo.com).
// =====================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SB_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM = Deno.env.get("RESEND_FROM") ?? "MyTunigo <noreply@mytunigo.com>";
const ADMIN_EMAIL = Deno.env.get("ADMIN_EMAIL") ?? "admin@mytunigo.com";
const SITE = (Deno.env.get("SITE_URL") ?? "https://mytunigo.com").replace(/\/$/, "");

// Grille des logements (17/10/2026) : annonce fondatrice à 0 % pendant
// 12 mois à partir de l'attribution du badge, puis commission normale.
const FOUNDER_FREE_MONTHS = 12;
const HOST_COMMISSION_PCT = 8;

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

const table = (rows: [string, string][]) =>
  `<table style="width:100%;border-collapse:collapse;font-size:14px;background:#f8f9fa;border-radius:8px;">
    <tbody style="display:block;padding:12px 14px;">
      ${rows.map(([k, v]) => `<tr><td style="padding:5px 0;color:#6c757d;width:120px;vertical-align:top;">${k}</td><td style="padding:5px 0;font-weight:600;">${v}</td></tr>`).join("")}
    </tbody></table>`;

const fmtDate = (d: Date) =>
  d.toLocaleDateString("fr-FR", { timeZone: "Africa/Tunis", day: "2-digit", month: "long", year: "numeric" });

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  mailErrors = [];

  try {
    // 1. Qui appelle ?
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: userData } = await admin.auth.getUser(token);
    const user = userData?.user;
    if (!user) return json({ error: "unauthorized" }, 401);
    const isAdmin = user.app_metadata?.role === "admin";

    // deno-lint-ignore no-explicit-any
    let body: any = {};
    try { body = await req.json(); } catch { /* corps vide */ }
    const action = String(body.action ?? "");
    const kind = body.kind === "excursion" ? "excursion" : body.kind === "annonce" ? "annonce" : "";
    const id = String(body.id ?? "");
    if (!kind || !id) return json({ error: "kind/id manquant" }, 400);

    // 2. L'élément, lu en base
    const isExc = kind === "excursion";
    const { data: row, error: readErr } = await admin.from(isExc ? "excursions" : "annonces")
      .select("*").eq("id", id).maybeSingle();
    if (readErr) return json({ error: readErr.message }, 500);
    if (!row) return json({ error: "not_found" }, 404);

    const ownerId = isExc ? row.owner_id : row.user_id;
    const title = isExc ? row.title : row.name;
    const what = isExc ? "excursion" : "annonce";
    const whatCap = isExc ? "Excursion" : "Annonce";
    const firstname = row.contact_firstname ?? "";
    const ownerEmail = row.contact_email;

    const recap = table([
      ["Référence", esc(row.ref ?? "—")],
      [isExc ? "Excursion" : "Logement", esc(title)],
      ...(isExc
        ? [["Catégorie", esc(row.category_label ?? row.category ?? "—")] as [string, string],
           ["Prix", `${esc(row.price)} € / ${row.price_type === "groupe" ? "groupe" : "personne"}`] as [string, string]]
        : [["Type", esc(row.type_label ?? row.type ?? "—")] as [string, string],
           ["Prix / nuit", `${esc(row.price_night)} €`] as [string, string]]),
      ["Ville", `${esc(row.city ?? "")}${row.country ? ", " + esc(row.country) : ""}`],
    ]);

    // 3. Actions
    if (action === "submitted") {
      if (ownerId !== user.id) return json({ error: "not_owner" }, 403);
      const pendingLive = !isExc && row.status === "publiée" && row.pending_changes;
      if (!pendingLive && row.status !== "en attente") return json({ error: "not_pending" }, 409);
      const isEdit = body.edited === true;

      const adminTitle = pendingLive ? `Modifications à valider (${what} en ligne)`
        : isEdit ? `${whatCap} modifiée à re-valider` : `Nouvelle ${what} à valider`;
      const contact = table([
        ["Contact", `${esc(firstname)} ${esc(row.contact_lastname ?? "")}`],
        ["E-mail", esc(ownerEmail ?? "—")],
        ["Téléphone", esc(row.contact_phone ?? "—")],
      ]);
      await Promise.all([
        sendMail(ADMIN_EMAIL, `${isExc ? "🧭" : "🏠"} ${adminTitle} — ${title}`,
          layout(adminTitle, `À vérifier dans le tableau de bord d'administration.`,
            recap + `<div style="height:10px;"></div>` + contact,
            { label: "Ouvrir l'administration", url: `${SITE}/?admin=1` })),
        sendMail(ownerEmail,
          pendingLive ? `Vos modifications sont en cours de vérification — ${title}`
            : `✅ Votre ${what} est en cours de vérification — ${title}`,
          layout(pendingLive ? "Modifications reçues" : isEdit ? `${whatCap} mise à jour` : `${whatCap} reçue !`,
            `Bonjour ${esc(firstname)},<br><br>` + (pendingLive
              ? `Vos modifications de <strong>${esc(title)}</strong> ont bien été reçues. La version actuelle reste en ligne et réservable ; les changements seront appliqués dès leur validation par notre équipe.`
              : `Votre ${what} <strong>${esc(title)}</strong> a bien été ${isEdit ? "mise à jour" : "reçue"} et est en cours de vérification par notre équipe (délai estimé : 24h). Vous recevrez un e-mail dès sa mise en ligne.`),
            recap)),
      ]);
    } else if (action === "founder_granted") {
      // Badge « Hôte fondateur » : attribué par l'admin sur une annonce.
      if (!isAdmin) return json({ error: "not_admin" }, 403);
      if (isExc || !row.founder_since) return json({ error: "invalid_state" }, 409);
      const since = new Date(row.founder_since);
      const until = new Date(since);
      until.setMonth(until.getMonth() + FOUNDER_FREE_MONTHS);
      const perks = `<div style="margin-top:16px;padding:14px 16px;background:#fff8e6;border:1px solid #f5d38a;border-radius:8px;font-size:14px;line-height:1.7;">
        <div style="font-weight:800;color:#8a6200;margin-bottom:6px;">⭐ Vos avantages d'hôte fondateur</div>
        • <strong>0 % de commission</strong> sur cette annonce jusqu'au <strong>${fmtDate(until)}</strong>, puis ${HOST_COMMISSION_PCT} %<br>
        • Le badge « Hôte fondateur » affiché sur votre annonce et sur votre profil<br>
        • Une meilleure visibilité : les annonces fondatrices sont mises en avant sur MyTunigo<br>
        • Un accompagnement prioritaire pour optimiser votre annonce<br>
        • La possibilité de participer aux améliorations de la plateforme
      </div>`;
      await sendMail(ownerEmail, `⭐ Vous êtes Hôte fondateur MyTunigo — ${title}`,
        layout("Bienvenue parmi les hôtes fondateurs !",
          `Bonjour ${esc(firstname)},<br><br>Bonne nouvelle : l'équipe MyTunigo a attribué le badge <strong>« Hôte fondateur »</strong> à votre annonce <strong>${esc(title)}</strong>. Merci de faire partie des premiers à nous faire confiance.`,
          recap + perks,
          { label: "Voir mon annonce", url: SITE },
          "Le taux appliqué à une réservation est celui en vigueur au moment de sa confirmation."));
    } else if (["validated", "rejected", "changes_applied", "changes_rejected"].includes(action)) {
      if (!isAdmin) return json({ error: "not_admin" }, 403);
      if (action === "validated" && row.status !== "publiée") return json({ error: "not_publiée" }, 409);
      if (action === "rejected" && row.status !== "rejetée") return json({ error: "not_rejetée" }, 409);
      if ((action === "changes_applied" || action === "changes_rejected") && (isExc || row.pending_changes)) {
        return json({ error: "invalid_state" }, 409);
      }
      const t = {
        validated: [`🎉 Votre ${what} est en ligne — ${title}`, `${whatCap} validée !`,
          `Bonne nouvelle : votre ${what} <strong>${esc(title)}</strong> a été validée par notre équipe et est maintenant visible sur MyTunigo.`],
        rejected: [`Votre ${what} n'a pas été validée — ${title}`, `${whatCap} non validée`,
          `Après vérification, votre ${what} <strong>${esc(title)}</strong> n'a pas pu être publiée. Vous pouvez la corriger depuis votre espace, ou nous écrire via « Contacter le support » pour en savoir plus.`],
        changes_applied: [`✅ Vos modifications sont en ligne — ${title}`, "Modifications publiées",
          `Les modifications de votre annonce <strong>${esc(title)}</strong> ont été validées et sont maintenant en ligne.`],
        changes_rejected: [`Vos modifications n'ont pas été retenues — ${title}`, "Modifications non retenues",
          `Les modifications proposées pour <strong>${esc(title)}</strong> n'ont pas été validées. La version précédente reste en ligne, inchangée. Pour en savoir plus, écrivez-nous via « Contacter le support ».`],
      }[action as "validated"]!;
      await sendMail(ownerEmail, t[0],
        layout(t[1], `Bonjour ${esc(firstname)},<br><br>${t[2]}`, recap, { label: "Voir sur MyTunigo", url: SITE }));
    } else {
      return json({ error: "action invalide" }, 400);
    }

    if (mailErrors.length) return json({ error: "mail_failed" }, 502);
    return json({ ok: true });
  } catch (err) {
    console.error("notify-admin:", (err as Error).message);
    return json({ error: (err as Error).message }, 500);
  }
});
