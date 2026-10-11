-- =====================================================================
-- MyTunigo — Demande de logement : arrivée au plus tôt demain
-- Projet : fxbetakueqkzipsqvtck — 11/10/2026
--
-- Constat (test du 11/10) : un voyageur pouvait envoyer une demande avec une
-- arrivée le jour même. Or l'hôte ne peut pas accepter une arrivée le jour
-- même (règle CHECKIN_PASSED de fn_reservation_flow_guard : le voyageur
-- n'aurait plus le temps de payer), et la tâche d'expiration clôt aussitôt
-- ces demandes. La demande passait donc directement en « expirée », sans que
-- l'hôte la voie.
--
-- Désormais une nouvelle demande doit avoir une arrivée à partir de demain
-- (heure de Tunis). Le site applique la même règle dans son calendrier.
-- Les fonctions serveur (service_role) et l'administration ne sont pas
-- concernées. Rejouable.
-- =====================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_reservation_checkin_min()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF current_user IN ('postgres','service_role','supabase_admin') THEN
    RETURN NEW;
  END IF;
  IF NEW.check_in <= (now() AT TIME ZONE 'Africa/Tunis')::date THEN
    RAISE EXCEPTION 'CHECKIN_TOO_SOON';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_reservation_checkin_min ON public.reservations;
CREATE TRIGGER trg_reservation_checkin_min BEFORE INSERT ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.fn_reservation_checkin_min();

COMMIT;
