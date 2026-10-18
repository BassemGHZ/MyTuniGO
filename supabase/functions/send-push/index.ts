// =====================================================================
// MyTunigo — Edge Function "send-push"
// Envoi des notifications push (Web Push) déposées en base dans push_queue.
//
// Appels (POST JSON) :
//   { type: "flush" }
//       -> envoie les notifications en attente (réveil par trigger en base
//          ou par la tâche planifiée mytunigo-push). Idempotent : chaque
//          notification est réservée en base avant l'envoi.
//   { type: "public_key" }
//       -> clé publique VAPID, utilisée par le site pour abonner l'appareil.
//   { type: "test" }   (JWT de l'utilisateur connecté)
//       -> envoie une notification de test à tous les appareils de
//          l'utilisateur qui appelle, et à lui seul.
//
// Sécurité : destinataires et contenus viennent uniquement de push_queue,
// alimentée par des triggers en base ; aucun appel ne peut choisir le
// destinataire ni le texte. Les abonnements expirés (404/410) sont supprimés.
//
// Secrets : VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (ex. mailto:contact@mytunigo.com),
//           SB_SERVICE_ROLE_KEY (ou SUPABASE_SERVICE_ROLE_KEY).
// =====================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SB_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "mailto:contact@mytunigo.com";

const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
const vapidReady = !!(VAPID_PUBLIC_KEY && VAPID_PRIVATE_KEY);
if (vapidReady) webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

type Sub = { id: string; endpoint: string; p256dh: string; auth: string };
type Msg = { title: string; body: string; url: string; tag?: string | null };

// Envoie un message à une liste d'appareils. Retourne le nombre d'envois réussis
// et la dernière erreur (hors abonnements expirés, qui sont supprimés).
async function sendToSubs(subs: Sub[], msg: Msg): Promise<{ ok: number; error: string | null }> {
  let ok = 0;
  let error: string | null = null;
  const payload = JSON.stringify({ title: msg.title, body: msg.body, url: msg.url || "/", tag: msg.tag || undefined });
  await Promise.all(subs.map(async (s) => {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        payload,
        { TTL: 24 * 3600, urgency: "high" },
      );
      ok++;
      await admin.from("push_subscriptions").update({ last_used_at: new Date().toISOString() }).eq("id", s.id);
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) {
        await admin.from("push_subscriptions").delete().eq("id", s.id);
      } else {
        error = `${code ?? ""} ${(e as Error).message}`.trim().slice(0, 300);
        console.error("push:", error);
      }
    }
  }));
  return { ok, error };
}

async function flush() {
  if (!vapidReady) return json({ error: "VAPID non configuré (secrets VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY)" }, 500);
  let sent = 0, failed = 0, rounds = 0;
  while (rounds++ < 5) {
    const { data: items, error } = await admin.rpc("fn_push_claim", { p_limit: 100 });
    if (error) return json({ error: error.message }, 500);
    if (!items || !items.length) break;
    const userIds = [...new Set(items.map((i: { user_id: string }) => i.user_id))];
    const { data: subs, error: subErr } = await admin.from("push_subscriptions")
      .select("id,user_id,endpoint,p256dh,auth").in("user_id", userIds);
    if (subErr) return json({ error: subErr.message }, 500);
    for (const it of items) {
      const mine = (subs ?? []).filter((s) => s.user_id === it.user_id);
      const r = mine.length ? await sendToSubs(mine, it) : { ok: 0, error: null };
      // Envoyée si au moins un appareil l'a reçue, ou s'il n'y a plus d'appareil
      if (r.ok > 0 || !r.error) {
        sent++;
        await admin.from("push_queue").update({ sent_at: new Date().toISOString(), last_error: null }).eq("id", it.id);
      } else {
        failed++;
        await admin.from("push_queue").update({ claimed_at: null, last_error: r.error }).eq("id", it.id);
      }
    }
  }
  return json({ ok: true, sent, failed });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    // deno-lint-ignore no-explicit-any
    let body: any = {};
    try { body = await req.json(); } catch { /* corps vide */ }
    const type = String(body.type ?? "");

    if (type === "flush") return await flush();
    if (type === "public_key") {
      return vapidReady ? json({ public_key: VAPID_PUBLIC_KEY }) : json({ error: "not_configured" }, 503);
    }
    if (type === "test") {
      if (!vapidReady) return json({ error: "not_configured" }, 503);
      const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
      const { data: userData } = await admin.auth.getUser(token);
      const uid = userData?.user?.id;
      if (!uid) return json({ error: "unauthorized" }, 401);
      const { data: subs } = await admin.from("push_subscriptions").select("id,endpoint,p256dh,auth").eq("user_id", uid);
      if (!subs || !subs.length) return json({ error: "no_device" }, 404);
      const r = await sendToSubs(subs, {
        title: "🔔 Notifications activées",
        body: "Vous serez prévenu ici des demandes, paiements et messages MyTunigo.",
        url: "/", tag: "test",
      });
      return r.ok > 0 ? json({ ok: true, devices: r.ok }) : json({ error: r.error ?? "send_failed" }, 502);
    }
    return json({ error: "type invalide" }, 400);
  } catch (err) {
    console.error("send-push:", (err as Error).message);
    return json({ error: (err as Error).message }, 500);
  }
});
