-- =====================================================================
-- MyTunigo — Tâches planifiées : appel des Edge Functions sécurisées
-- Projet : fxbetakueqkzipsqvtck — 08/10/2026
--
-- À exécuter APRÈS avoir déployé les nouvelles versions de :
--   notify-review, notify-price-drop, notify-excursion-booking
--
-- Avant : les fonctions SQL lisaient elles-mêmes les e-mails des
-- utilisateurs et les envoyaient aux Edge Functions avec le contenu de
-- l'e-mail. Ces appels étaient cassés (fonction inexistante, clé factice,
-- format refusé) et reposaient sur des relais d'e-mail ouverts.
-- Après : chaque tâche planifiée se contente de « réveiller » l'Edge
-- Function, qui relit tout en base et ne traite chaque élément qu'une fois.
--
-- La clé utilisée dans les appels est la clé anon PUBLIQUE (déjà présente
-- dans le site) : elle sert seulement à passer la vérification JWT de
-- Supabase. Aucun secret n'est écrit ici.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Avis : date de dernière modification
--    (notify-review n'envoie l'e-mail « nouvel avis » à l'hôte que pour
--     un avis créé ou modifié il y a moins de 10 minutes)
-- ---------------------------------------------------------------------
ALTER TABLE public.avis ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
UPDATE public.avis SET updated_at = created_at WHERE created_at IS NOT NULL;

DROP TRIGGER IF EXISTS set_avis_updated_at ON public.avis;
CREATE TRIGGER set_avis_updated_at
  BEFORE UPDATE ON public.avis
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- ---------------------------------------------------------------------
-- 2. Demandes d'avis aux voyageurs (job « send-review-requests », toutes les heures)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_send_review_requests()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM net.http_post(
    url     := 'https://fxbetakueqkzipsqvtck.supabase.co/functions/v1/notify-review',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ4YmV0YWt1ZXFremlwc3F2dGNrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI1NDk1MjAsImV4cCI6MjA5ODEyNTUyMH0.e3RRfDjfmH4EJjRiX2UDJhyNKzhWhiHYay8wJFoQYNk'
    ),
    body    := jsonb_build_object('type', 'review_requests')
  );
END;
$$;


-- ---------------------------------------------------------------------
-- 3. Alertes de baisse de prix (job « mytunigo-price-alerts », toutes les 3 h)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_check_price_alerts()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM net.http_post(
    url     := 'https://fxbetakueqkzipsqvtck.supabase.co/functions/v1/notify-price-drop',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ4YmV0YWt1ZXFremlwc3F2dGNrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI1NDk1MjAsImV4cCI6MjA5ODEyNTUyMH0.e3RRfDjfmH4EJjRiX2UDJhyNKzhWhiHYay8wJFoQYNk'
    ),
    body    := jsonb_build_object('action', 'check')
  );
END;
$$;


-- ---------------------------------------------------------------------
-- 4. Demandes d'excursions expirées (job « auto-reject-expired-excursion-bookings », 5h05)
--    Le passage en 'refusée' ET l'e-mail au voyageur sont faits par
--    notify-excursion-booking (type expire_pending).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_auto_reject_expired_excursion_bookings()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM net.http_post(
    url     := 'https://fxbetakueqkzipsqvtck.supabase.co/functions/v1/notify-excursion-booking',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ4YmV0YWt1ZXFremlwc3F2dGNrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI1NDk1MjAsImV4cCI6MjA5ODEyNTUyMH0.e3RRfDjfmH4EJjRiX2UDJhyNKzhWhiHYay8wJFoQYNk'
    ),
    body    := jsonb_build_object('type', 'expire_pending')
  );
END;
$$;


-- ---------------------------------------------------------------------
-- 5. Ancien auto-refus des demandes de logement (job « auto-reject-expired-requests »)
--    Devenu inutile : reservation-flow (action expire, toutes les 10 min)
--    clôt déjà les demandes en attente dès la date d'arrivée, et l'ancien
--    appel e-mail vers notify-booking ne fonctionnait plus.
-- ---------------------------------------------------------------------
SELECT cron.unschedule('auto-reject-expired-requests');


-- Les fonctions planifiées ne doivent pas être appelables depuis l'API.
REVOKE EXECUTE ON FUNCTION public.fn_send_review_requests()                   FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.fn_check_price_alerts()                     FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.fn_auto_reject_expired_excursion_bookings() FROM PUBLIC, anon, authenticated;

COMMIT;

-- Vérification (facultative), juste après exécution :
--   select public.fn_send_review_requests();
--   select public.fn_check_price_alerts();
--   select public.fn_auto_reject_expired_excursion_bookings();
-- puis, quelques secondes plus tard, les réponses des Edge Functions :
--   select id, status_code, left(content::text, 200) from net._http_response order by id desc limit 3;
-- Chaque réponse doit être 200 avec {"ok":true,...}.
