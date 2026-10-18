-- =====================================================================
-- MyTunigo — 18/10/2026 : pas de réservation d'une excursion déjà commencée
--
-- Problème : on pouvait réserver une excursion le jour même après l'heure de
-- rendez-vous (ou sans heure renseignée). L'organisateur ne pouvait ensuite
-- pas accepter la demande (EXCURSION_STARTED) et elle restait « en attente ».
--
-- Correctif : à la création (voyageur), refus si l'excursion a commencé à la
-- date choisie (heure de rendez-vous, heure de Tunis ; sans heure : minuit).
-- Les demandes déjà en attente sont closes par la tâche planifiée
-- (Edge Function notify-excursion-booking, action expire_pending).
--
-- À exécuter une fois dans le SQL Editor. Idempotent.
-- =====================================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.fn_excursion_not_started()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF current_user IN ('postgres', 'service_role', 'supabase_admin') OR public.fn_is_admin() THEN
    RETURN NEW;
  END IF;
  IF public.fn_excursion_start(NEW.excursion_id, NEW.date) <= now() THEN
    RAISE EXCEPTION 'EXCURSION_STARTED';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_excursion_not_started ON public.excursion_bookings;
CREATE TRIGGER trg_excursion_not_started
  BEFORE INSERT ON public.excursion_bookings
  FOR EACH ROW EXECUTE FUNCTION public.fn_excursion_not_started();

COMMIT;
