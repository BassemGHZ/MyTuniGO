-- =====================================================================
-- MyTunigo — 18/10/2026 : notifications push (mobile et ordinateur)
--
-- Principe :
--   1. Chaque appareil qui accepte les notifications enregistre son
--      abonnement Web Push dans push_subscriptions (une ligne par appareil).
--   2. Les événements (demande, accord, paiement, annulation, message,
--      annonce à valider…) sont détectés par des triggers en base, qui
--      déposent la notification dans push_queue. Rien n'est envoyé depuis
--      le navigateur : impossible d'envoyer une notification à quelqu'un
--      d'autre en appelant l'API.
--   3. Un dépôt dans push_queue « réveille » l'Edge Function send-push,
--      qui envoie les notifications et les marque envoyées. Une tâche
--      planifiée (toutes les 10 min) relance les envois en échec et dépose
--      les rappels de paiement.
--   Un trigger de notification ne peut jamais bloquer la réservation ou le
--   message : toute erreur est ignorée (avertissement dans les logs).
--
-- La clé utilisée pour réveiller send-push est la clé anon PUBLIQUE (déjà
-- dans le site) : elle sert seulement à passer la vérification JWT.
--
-- À exécuter une fois dans le SQL Editor. Idempotent.
-- =====================================================================
BEGIN;

-- ---------------------------------------------------------------------
-- 1. Abonnements des appareils
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.push_subscriptions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  endpoint     text NOT NULL UNIQUE CHECK (endpoint ~ '^https://' AND length(endpoint) < 1000),
  p256dh       text NOT NULL CHECK (length(p256dh) BETWEEN 20 AND 200),
  auth         text NOT NULL CHECK (length(auth) BETWEEN 8 AND 100),
  user_agent   text CHECK (length(user_agent) < 400),
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz
);
CREATE INDEX IF NOT EXISTS push_subscriptions_user_idx ON public.push_subscriptions(user_id);

ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS push_sub_select_own ON public.push_subscriptions;
DROP POLICY IF EXISTS push_sub_insert_own ON public.push_subscriptions;
DROP POLICY IF EXISTS push_sub_delete_own ON public.push_subscriptions;
CREATE POLICY push_sub_select_own ON public.push_subscriptions FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY push_sub_insert_own ON public.push_subscriptions FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY push_sub_delete_own ON public.push_subscriptions FOR DELETE TO authenticated USING (user_id = auth.uid());
REVOKE ALL ON public.push_subscriptions FROM anon;
GRANT SELECT, INSERT, DELETE ON public.push_subscriptions TO authenticated;

-- Enregistrement d'un appareil : si le même appareil était lié à un autre
-- compte (changement de compte sur le même téléphone), il passe au compte
-- connecté.
CREATE OR REPLACE FUNCTION public.fn_push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'NOT_AUTHENTICATED'; END IF;
  INSERT INTO public.push_subscriptions(user_id, endpoint, p256dh, auth, user_agent)
  VALUES (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300))
  ON CONFLICT (endpoint) DO UPDATE
    SET user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
        user_agent = excluded.user_agent, created_at = now();
END $$;
REVOKE ALL ON FUNCTION public.fn_push_subscribe(text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_push_subscribe(text, text, text, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 2. File d'envoi (aucun accès depuis le navigateur)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.push_queue (
  id         bigserial PRIMARY KEY,
  user_id    uuid NOT NULL,
  title      text NOT NULL,
  body       text NOT NULL DEFAULT '',
  url        text NOT NULL DEFAULT '/',
  tag        text,
  created_at timestamptz NOT NULL DEFAULT now(),
  claimed_at timestamptz,
  sent_at    timestamptz,
  attempts   int NOT NULL DEFAULT 0,
  last_error text
);
CREATE INDEX IF NOT EXISTS push_queue_todo_idx ON public.push_queue(created_at) WHERE sent_at IS NULL;
ALTER TABLE public.push_queue ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_queue FROM anon, authenticated;
REVOKE ALL ON SEQUENCE public.push_queue_id_seq FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_push_enqueue(p_user uuid, p_title text, p_body text, p_url text, p_tag text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_user IS NULL THEN RETURN; END IF;
  -- Inutile de remplir la file pour un utilisateur sans appareil abonné
  IF NOT EXISTS (SELECT 1 FROM public.push_subscriptions WHERE user_id = p_user) THEN RETURN; END IF;
  INSERT INTO public.push_queue(user_id, title, body, url, tag)
  VALUES (p_user, left(p_title, 120), left(coalesce(p_body, ''), 240), coalesce(p_url, '/'), p_tag);
END $$;
REVOKE ALL ON FUNCTION public.fn_push_enqueue(uuid, text, text, text, text) FROM PUBLIC, anon, authenticated;

-- Réservation des notifications à envoyer (appelée par send-push, clé de service)
CREATE OR REPLACE FUNCTION public.fn_push_claim(p_limit int DEFAULT 100)
RETURNS SETOF public.push_queue LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  UPDATE public.push_queue q SET claimed_at = now(), attempts = q.attempts + 1
  WHERE q.id IN (
    SELECT id FROM public.push_queue
    WHERE sent_at IS NULL AND attempts < 5
      AND created_at > now() - interval '1 day'
      AND (claimed_at IS NULL OR claimed_at < now() - interval '2 minutes')
    ORDER BY id LIMIT p_limit
    FOR UPDATE SKIP LOCKED)
  RETURNING q.*;
$$;
REVOKE ALL ON FUNCTION public.fn_push_claim(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_push_claim(int) TO service_role;
GRANT SELECT, UPDATE, DELETE ON public.push_queue TO service_role;
GRANT SELECT, UPDATE, DELETE ON public.push_subscriptions TO service_role;

-- Réveil de send-push après chaque dépôt (une fois par instruction)
CREATE OR REPLACE FUNCTION public.fn_push_wake()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  BEGIN
    PERFORM net.http_post(
      url     := 'https://fxbetakueqkzipsqvtck.supabase.co/functions/v1/send-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ4YmV0YWt1ZXFremlwc3F2dGNrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI1NDk1MjAsImV4cCI6MjA5ODEyNTUyMH0.e3RRfDjfmH4EJjRiX2UDJhyNKzhWhiHYay8wJFoQYNk'
      ),
      body    := jsonb_build_object('type', 'flush'));
  EXCEPTION WHEN others THEN
    RAISE WARNING 'push wake: %', SQLERRM;
  END;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_push_wake ON public.push_queue;
CREATE TRIGGER trg_push_wake AFTER INSERT ON public.push_queue
  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_push_wake();

-- ---------------------------------------------------------------------
-- 3. Événements
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_push_dm(d date) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT to_char(d, 'DD/MM')
$$;
CREATE OR REPLACE FUNCTION public.fn_push_dt(t timestamptz) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT to_char(t AT TIME ZONE 'Africa/Tunis', 'DD/MM à HH24"h"MI')
$$;

-- 3a. Réservations de logement
CREATE OR REPLACE FUNCTION public.fn_push_reservation_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_host  uuid;
  v_name  text;
  v_guest text;
  v_dates text;
BEGIN
  BEGIN
    SELECT a.user_id, coalesce(a.name, 'votre logement') INTO v_host, v_name
      FROM public.annonces a WHERE a.id = NEW.logement_id;
    SELECT coalesce(nullif(p.first_name, ''), 'Un voyageur') INTO v_guest
      FROM public.profiles p WHERE p.id = NEW.guest_id;
    v_guest := coalesce(v_guest, 'Un voyageur');
    v_dates := public.fn_push_dm(NEW.check_in) || ' → ' || public.fn_push_dm(NEW.check_out);

    IF TG_OP = 'INSERT' THEN
      IF NEW.status = 'en attente' THEN
        PERFORM public.fn_push_enqueue(v_host, '📨 Nouvelle demande de réservation',
          v_guest || ' · ' || v_name || ' · ' || v_dates, '/?go=booking-requests', 'resa-' || NEW.id);
      END IF;
    ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
      IF NEW.status = 'acceptée' THEN
        PERFORM public.fn_push_enqueue(NEW.guest_id, '✅ Demande acceptée — payez pour confirmer',
          v_name || ' · ' || v_dates || ' — à payer avant le ' || public.fn_push_dt(NEW.payment_deadline) || '.',
          '/?pay=' || NEW.id, 'resa-' || NEW.id);
      ELSIF NEW.status = 'refusée' THEN
        PERFORM public.fn_push_enqueue(NEW.guest_id, 'Demande non retenue',
          v_name || ' · ' || v_dates || ' — aucun paiement effectué.', '/?go=reservations', 'resa-' || NEW.id);
      ELSIF NEW.status = 'confirmée' THEN
        PERFORM public.fn_push_enqueue(NEW.guest_id, '🎉 Réservation confirmée',
          v_name || ' · ' || v_dates, '/?go=reservations', 'resa-' || NEW.id);
        PERFORM public.fn_push_enqueue(v_host, '💳 Réservation payée',
          v_guest || ' a payé : ' || v_name || ' · ' || v_dates, '/?go=booking-requests', 'resa-' || NEW.id);
      ELSIF NEW.status = 'expirée' THEN
        PERFORM public.fn_push_enqueue(NEW.guest_id,
          CASE WHEN OLD.status = 'acceptée' THEN '⌛ Délai de paiement dépassé' ELSE 'Demande expirée' END,
          v_name || ' · ' || v_dates, '/?go=reservations', 'resa-' || NEW.id);
      ELSIF NEW.status = 'annulée' THEN
        IF auth.uid() IS NOT DISTINCT FROM v_host THEN
          PERFORM public.fn_push_enqueue(NEW.guest_id, '❌ Réservation annulée par l''hôte',
            v_name || ' · ' || v_dates, '/?go=reservations', 'resa-' || NEW.id);
        ELSE
          PERFORM public.fn_push_enqueue(v_host, '❌ Réservation annulée',
            v_guest || ' a annulé : ' || v_name || ' · ' || v_dates, '/?go=booking-requests', 'resa-' || NEW.id);
        END IF;
      END IF;
    END IF;
  EXCEPTION WHEN others THEN
    RAISE WARNING 'push reservation: %', SQLERRM;
  END;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_push_reservation ON public.reservations;
CREATE TRIGGER trg_push_reservation AFTER INSERT OR UPDATE OF status ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.fn_push_reservation_event();

-- 3b. Réservations d'excursion
CREATE OR REPLACE FUNCTION public.fn_push_excursion_booking_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_owner uuid;
  v_title text;
  v_guest text;
  v_info  text;
BEGIN
  BEGIN
    SELECT e.owner_id, coalesce(e.title, 'votre excursion') INTO v_owner, v_title
      FROM public.excursions e WHERE e.id = NEW.excursion_id;
    SELECT coalesce(nullif(p.first_name, ''), 'Un voyageur') INTO v_guest
      FROM public.profiles p WHERE p.id = NEW.guest_id;
    v_guest := coalesce(v_guest, 'Un voyageur');
    v_info  := v_title || ' · ' || public.fn_push_dm(NEW.date) || ' · ' || coalesce(NEW.participants, 1) || ' pers.';

    IF TG_OP = 'INSERT' THEN
      IF NEW.status = 'en attente' THEN
        PERFORM public.fn_push_enqueue(v_owner, '📨 Nouvelle demande d''excursion',
          v_guest || ' · ' || v_info, '/?go=excursion-requests', 'exc-' || NEW.id);
      END IF;
      -- Réservation instantanée (acceptée) : rien tant que le voyageur n'a pas payé
    ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
      IF NEW.status = 'acceptée' THEN
        PERFORM public.fn_push_enqueue(NEW.guest_id, '✅ Demande acceptée — payez pour confirmer',
          v_info || ' — à payer avant le ' || public.fn_push_dt(NEW.payment_deadline) || '.',
          '/?payexc=' || NEW.id, 'exc-' || NEW.id);
      ELSIF NEW.status = 'refusée' THEN
        PERFORM public.fn_push_enqueue(NEW.guest_id, 'Demande non retenue',
          v_info || ' — aucun paiement effectué.', '/?go=reservations', 'exc-' || NEW.id);
      ELSIF NEW.status = 'confirmée' THEN
        PERFORM public.fn_push_enqueue(NEW.guest_id, '🎉 Réservation confirmée', v_info, '/?go=reservations', 'exc-' || NEW.id);
        PERFORM public.fn_push_enqueue(v_owner, '💳 Réservation payée',
          v_guest || ' a payé : ' || v_info, '/?go=excursion-requests', 'exc-' || NEW.id);
      ELSIF NEW.status = 'expirée' THEN
        PERFORM public.fn_push_enqueue(NEW.guest_id, '⌛ Délai de paiement dépassé', v_info, '/?go=reservations', 'exc-' || NEW.id);
      ELSIF NEW.status = 'annulée' THEN
        IF auth.uid() IS NOT DISTINCT FROM v_owner THEN
          PERFORM public.fn_push_enqueue(NEW.guest_id, '❌ Réservation annulée par l''organisateur', v_info, '/?go=reservations', 'exc-' || NEW.id);
        ELSE
          PERFORM public.fn_push_enqueue(v_owner, '❌ Réservation annulée',
            v_guest || ' a annulé : ' || v_info, '/?go=excursion-requests', 'exc-' || NEW.id);
        END IF;
      END IF;
    END IF;
  EXCEPTION WHEN others THEN
    RAISE WARNING 'push excursion: %', SQLERRM;
  END;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_push_excursion_booking ON public.excursion_bookings;
CREATE TRIGGER trg_push_excursion_booking AFTER INSERT OR UPDATE OF status ON public.excursion_bookings
  FOR EACH ROW EXECUTE FUNCTION public.fn_push_excursion_booking_event();

-- 3c. Messages
CREATE OR REPLACE FUNCTION public.fn_push_message_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_to   uuid;
  v_from text;
BEGIN
  BEGIN
    SELECT CASE WHEN c.participant_a = NEW.sender_id THEN c.participant_b ELSE c.participant_a END
      INTO v_to FROM public.conversations c WHERE c.id = NEW.conversation_id;
    IF v_to IS NULL OR v_to = NEW.sender_id THEN RETURN NULL; END IF;
    SELECT coalesce(nullif(p.first_name, ''), 'Quelqu''un') INTO v_from FROM public.profiles p WHERE p.id = NEW.sender_id;
    PERFORM public.fn_push_enqueue(v_to, '💬 Nouveau message de ' || coalesce(v_from, 'Quelqu''un'),
      left(regexp_replace(coalesce(NEW.content, ''), '\s+', ' ', 'g'), 140),
      '/?go=messages', 'msg-' || NEW.conversation_id);
  EXCEPTION WHEN others THEN
    RAISE WARNING 'push message: %', SQLERRM;
  END;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_push_message ON public.messages;
CREATE TRIGGER trg_push_message AFTER INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.fn_push_message_event();

-- 3d. Admin : annonce ou excursion à valider
CREATE OR REPLACE FUNCTION public.fn_push_admins(p_title text, p_body text, p_tag text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM auth.users WHERE raw_app_meta_data ->> 'role' = 'admin' LOOP
    PERFORM public.fn_push_enqueue(r.id, p_title, p_body, '/?go=admin', p_tag);
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.fn_push_admins(text, text, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_push_listing_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_kind  text := CASE WHEN TG_TABLE_NAME = 'annonces' THEN 'annonce' ELSE 'excursion' END;
  v_name  text;
  v_new   boolean;
  v_edit  boolean := false;
BEGIN
  BEGIN
    v_name := CASE WHEN TG_TABLE_NAME = 'annonces' THEN to_jsonb(NEW) ->> 'name' ELSE to_jsonb(NEW) ->> 'title' END;
    v_new  := NEW.status = 'en attente' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'en attente');
    IF TG_TABLE_NAME = 'annonces' AND TG_OP = 'UPDATE' THEN
      v_edit := (to_jsonb(NEW) -> 'pending_changes') IS NOT NULL
                AND jsonb_typeof(to_jsonb(NEW) -> 'pending_changes') <> 'null'
                AND ((to_jsonb(OLD) -> 'pending_changes') IS NULL
                     OR jsonb_typeof(to_jsonb(OLD) -> 'pending_changes') = 'null');
    END IF;
    IF v_new THEN
      PERFORM public.fn_push_admins(
        CASE v_kind WHEN 'annonce' THEN '🏠 Annonce à valider' ELSE '🧭 Excursion à valider' END,
        coalesce(v_name, '') || CASE WHEN TG_OP = 'UPDATE' THEN ' (modifiée)' ELSE '' END,
        v_kind || '-' || NEW.id);
    ELSIF v_edit THEN
      PERFORM public.fn_push_admins('✏️ Modifications d''annonce à valider', coalesce(v_name, ''), v_kind || '-' || NEW.id);
    END IF;
  EXCEPTION WHEN others THEN
    RAISE WARNING 'push listing: %', SQLERRM;
  END;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_push_annonce ON public.annonces;
CREATE TRIGGER trg_push_annonce AFTER INSERT OR UPDATE OF status, pending_changes ON public.annonces
  FOR EACH ROW EXECUTE FUNCTION public.fn_push_listing_event();
DROP TRIGGER IF EXISTS trg_push_excursion ON public.excursions;
CREATE TRIGGER trg_push_excursion AFTER INSERT OR UPDATE OF status ON public.excursions
  FOR EACH ROW EXECUTE FUNCTION public.fn_push_listing_event();

-- ---------------------------------------------------------------------
-- 4. Rappel de paiement (environ 3 h avant la fin du délai de 24 h)
-- ---------------------------------------------------------------------
ALTER TABLE public.reservations       ADD COLUMN IF NOT EXISTS push_reminder_sent_at timestamptz;
ALTER TABLE public.excursion_bookings ADD COLUMN IF NOT EXISTS push_reminder_sent_at timestamptz;

CREATE OR REPLACE FUNCTION public.fn_push_cron()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record;
BEGIN
  FOR r IN
    UPDATE public.reservations x SET push_reminder_sent_at = now()
    FROM public.annonces a
    WHERE a.id = x.logement_id AND x.status = 'acceptée' AND x.push_reminder_sent_at IS NULL
      AND x.payment_deadline > now() AND x.payment_deadline <= now() + interval '3 hours'
      AND x.accepted_at <= now() - interval '1 hour'
    RETURNING x.id, x.guest_id, x.payment_deadline, coalesce(a.name, 'votre logement') AS name
  LOOP
    PERFORM public.fn_push_enqueue(r.guest_id, '⏰ Pensez à payer votre réservation',
      r.name || ' : à payer avant le ' || public.fn_push_dt(r.payment_deadline) || ', sinon la demande sera annulée.',
      '/?pay=' || r.id, 'resa-' || r.id);
  END LOOP;

  FOR r IN
    UPDATE public.excursion_bookings x SET push_reminder_sent_at = now()
    FROM public.excursions e
    WHERE e.id = x.excursion_id AND x.status = 'acceptée' AND x.push_reminder_sent_at IS NULL
      AND x.payment_deadline > now() AND x.payment_deadline <= now() + interval '3 hours'
      AND x.accepted_at <= now() - interval '1 hour'
    RETURNING x.id, x.guest_id, x.payment_deadline, coalesce(e.title, 'votre excursion') AS name
  LOOP
    PERFORM public.fn_push_enqueue(r.guest_id, '⏰ Pensez à payer votre excursion',
      r.name || ' : à payer avant le ' || public.fn_push_dt(r.payment_deadline) || ', sinon la réservation sera annulée.',
      '/?payexc=' || r.id, 'exc-' || r.id);
  END LOOP;

  -- Relance des envois en attente ou en échec
  IF EXISTS (SELECT 1 FROM public.push_queue WHERE sent_at IS NULL AND attempts < 5 AND created_at > now() - interval '1 day') THEN
    PERFORM net.http_post(
      url     := 'https://fxbetakueqkzipsqvtck.supabase.co/functions/v1/send-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ4YmV0YWt1ZXFremlwc3F2dGNrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI1NDk1MjAsImV4cCI6MjA5ODEyNTUyMH0.e3RRfDjfmH4EJjRiX2UDJhyNKzhWhiHYay8wJFoQYNk'
      ),
      body    := jsonb_build_object('type', 'flush'));
  END IF;

  -- Ménage : notifications de plus de 30 jours
  DELETE FROM public.push_queue WHERE created_at < now() - interval '30 days';
END $$;
REVOKE ALL ON FUNCTION public.fn_push_cron() FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'mytunigo-push') THEN
    PERFORM cron.unschedule('mytunigo-push');
  END IF;
  PERFORM cron.schedule('mytunigo-push', '*/10 * * * *', 'SELECT public.fn_push_cron();');
END $$;

COMMIT;
