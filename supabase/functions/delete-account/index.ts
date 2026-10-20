// =====================================================================
// MyTunigo — Edge Function "delete-account"
// Finalise une demande de suppression de compte, à la validation de l'admin.
//
// Appel (POST JSON, avec le JWT d'un administrateur — app_metadata.role) :
//   { request_id }    -> ligne deletion_requests (item_type 'compte', 'en attente')
//
// Étapes :
//   1. vérifie l'admin, la demande, et qu'il ne reste rien à venir
//      (fn_account_deletion_blockers) ;
//   2. compte de connexion : e-mail remplacé par une adresse factice,
//      mot de passe aléatoire, métadonnées vidées, compte bloqué, puis
//      suppression douce Supabase Auth (la ligne reste : les réservations,
//      avis et messages des autres utilisateurs ne sont pas effacés) ;
//   3. photos de profil supprimées du stockage (profile-photos/<id>/) ;
//   4. fn_account_deletion_finalize : profil anonymisé, annonces et
//      excursions archivées, favoris/alertes/appareils supprimés.
// Relançable : si l'étape 4 échoue, un nouvel appel la refait.
//
// Secrets : SB_SERVICE_ROLE_KEY (ou SUPABASE_SERVICE_ROLE_KEY).
// =====================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SB_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const randomPassword = () => {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return btoa(String.fromCharCode(...b));
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    // 1. Un administrateur ?
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: callerData } = await admin.auth.getUser(token);
    const caller = callerData?.user;
    if (!caller) return json({ error: "unauthorized" }, 401);
    if (caller.app_metadata?.role !== "admin") return json({ error: "forbidden" }, 403);

    // deno-lint-ignore no-explicit-any
    let body: any = {};
    try { body = await req.json(); } catch { /* corps vide */ }
    const requestId = String(body.request_id ?? "");
    if (!/^[0-9a-f-]{36}$/i.test(requestId)) return json({ error: "request_id manquant" }, 400);

    // 2. La demande
    const { data: reqRow, error: readErr } = await admin.from("deletion_requests")
      .select("id,item_type,status,host_id")
      .eq("id", requestId).maybeSingle();
    if (readErr) return json({ error: readErr.message }, 500);
    if (!reqRow || reqRow.item_type !== "compte") return json({ error: "not_found" }, 404);
    if (reqRow.status !== "en attente") return json({ error: "not_pending", status: reqRow.status }, 409);
    const uid = reqRow.host_id as string;
    if (!uid) return json({ error: "not_found" }, 404);
    if (uid === caller.id) return json({ error: "self_delete_forbidden" }, 409);

    // 3. Plus rien à venir ?
    const { data: blockers, error: blkErr } = await admin.rpc("fn_account_deletion_blockers", { p_user: uid });
    if (blkErr) return json({ error: blkErr.message }, 500);
    if (Number(blockers?.total ?? 0) > 0) return json({ error: "blocked", blockers }, 409);

    // 4. Compte de connexion : rendu inutilisable, puis suppression douce
    const { data: authData } = await admin.auth.admin.getUserById(uid);
    if (authData?.user) {
      const { error: updErr } = await admin.auth.admin.updateUserById(uid, {
        email: `supprime-${uid}@mytunigo.invalid`,
        email_confirm: true,
        password: randomPassword(),
        user_metadata: {},
        app_metadata: { deleted: true },
        ban_duration: "876000h",
      });
      if (updErr) return json({ error: "auth_update_failed", detail: updErr.message }, 500);

      const { error: delErr } = await admin.auth.admin.deleteUser(uid, true);
      if (delErr) return json({ error: "auth_delete_failed", detail: delErr.message }, 500);
    }

    // 5. Photos de profil (best-effort)
    try {
      const { data: files } = await admin.storage.from("profile-photos").list(uid, { limit: 1000 });
      const paths = (files ?? []).map((f) => `${uid}/${f.name}`);
      if (paths.length) await admin.storage.from("profile-photos").remove(paths);
    } catch (e) {
      console.warn("profile-photos:", (e as Error).message);
    }

    // 6. Anonymisation en base
    const { data: result, error: finErr } = await admin.rpc("fn_account_deletion_finalize", { p_request: requestId });
    if (finErr) {
      return json({ error: "finalize_failed", detail: finErr.message, hint: "Compte de connexion déjà supprimé : relancer la suppression." }, 500);
    }
    return json({ ok: true, result });
  } catch (err) {
    console.error("delete-account:", (err as Error).message);
    return json({ error: (err as Error).message }, 500);
  }
});
