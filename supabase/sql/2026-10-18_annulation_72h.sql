-- =====================================================================
-- MyTunigo — Annulation par le voyageur : délai de 72 h (18/10/2026)
-- Projet : fxbetakueqkzipsqvtck
--
-- Règle (décision de Bassem du 18/10), logements ET excursions :
--   * Demande pas encore engagée (logement « en attente » ou « acceptée »
--     non payée, excursion « en attente ») : annulable à tout moment.
--   * Réservation confirmée : annulable par le voyageur jusqu'à 72 h avant
--     le début (arrivée à l'heure d'arrivée de l'annonce, ou heure de
--     rendez-vous de l'excursion, heure de Tunis). Passé ce délai, la base
--     refuse (CANCEL_DEADLINE_PASSED) : le voyageur doit contacter l'hôte
--     ou l'organisateur.
--   * Seul le voyageur (ou l'admin / le serveur) peut annuler.
--   * Motif obligatoire (cancel_reason), date d'annulation (cancelled_at).
--   * Montant remboursable calculé selon la politique (refund_amount),
--     à titre indicatif tant que le paiement réel n'est pas branché :
--       logement flexible 100 % ; modérée 50 % si annulée au moins 5 jours
--       avant, sinon 0 ; stricte 0. Excursion payée sur place : 0 (rien
--       n'a été payé) ; payée en ligne : flexible 100 %, stricte 0.
-- Rejouable.
-- =====================================================================

BEGIN;

ALTER TABLE public.reservations       ADD COLUMN IF NOT EXISTS cancel_reason text;
ALTER TABLE public.reservations       ADD COLUMN IF NOT EXISTS cancelled_at  timestamptz;
ALTER TABLE public.reservations       ADD COLUMN IF NOT EXISTS refund_amount numeric;
ALTER TABLE public.excursion_bookings ADD COLUMN IF NOT EXISTS cancel_reason text;
ALTER TABLE public.excursion_bookings ADD COLUMN IF NOT EXISTS cancelled_at  timestamptz;
ALTER TABLE public.excursion_bookings ADD COLUMN IF NOT EXISTS refund_amount numeric;

-- Heure « HH:MM » valide, sinon l'heure par défaut
CREATE OR REPLACE FUNCTION public.fn_safe_time(p text, p_default time)
RETURNS time LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p ~ '^\s*([01]?[0-9]|2[0-3]):[0-5][0-9]\s*$' THEN trim(p)::time ELSE p_default END;
$$;

-- Début d'une réservation (heure de Tunis)
CREATE OR REPLACE FUNCTION public.fn_booking_start(p_kind text, p_booking uuid)
RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE p_kind
    WHEN 'logement' THEN (
      SELECT (r.check_in + public.fn_safe_time(a.checkin, '15:00')) AT TIME ZONE 'Africa/Tunis'
      FROM public.reservations r JOIN public.annonces a ON a.id = r.logement_id WHERE r.id = p_booking)
    WHEN 'excursion' THEN (
      SELECT (b.date + public.fn_safe_time(e.meeting_time, '00:00')) AT TIME ZONE 'Africa/Tunis'
      FROM public.excursion_bookings b JOIN public.excursions e ON e.id = b.excursion_id WHERE b.id = p_booking)
  END;
$$;
REVOKE ALL ON FUNCTION public.fn_booking_start(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_booking_start(text, uuid) TO authenticated, service_role;

-- Pas SECURITY DEFINER : current_user doit rester celui de l'appelant pour
-- distinguer le voyageur du serveur.
CREATE OR REPLACE FUNCTION public.fn_guest_cancel_policy()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_kind  text := CASE WHEN TG_TABLE_NAME = 'reservations' THEN 'logement' ELSE 'excursion' END;
  v_priv  boolean := current_user IN ('postgres','service_role','supabase_admin') OR public.fn_is_admin();
  v_start timestamptz;
  v_policy text;
  v_on_site boolean := false;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status OR NEW.status <> 'annulée' THEN
    -- Le motif et la date d'annulation ne se modifient qu'en annulant
    IF NOT v_priv THEN
      NEW.cancel_reason := OLD.cancel_reason;
      NEW.cancelled_at  := OLD.cancelled_at;
      NEW.refund_amount := OLD.refund_amount;
    END IF;
    RETURN NEW;
  END IF;

  IF NOT v_priv THEN
    IF OLD.guest_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'CANCEL_NOT_GUEST';
    END IF;
    IF OLD.status NOT IN ('en attente','acceptée','confirmée') THEN
      RAISE EXCEPTION 'INVALID_TRANSITION: % -> annulée', OLD.status;
    END IF;
    IF coalesce(trim(NEW.cancel_reason), '') = '' THEN
      RAISE EXCEPTION 'CANCEL_REASON_REQUIRED';
    END IF;
  END IF;

  NEW.cancel_reason := left(trim(coalesce(NEW.cancel_reason, '')), 300);
  NEW.cancelled_at  := now();
  NEW.refund_amount := 0;

  IF OLD.status = 'confirmée' THEN
    v_start := public.fn_booking_start(v_kind, OLD.id);
    IF NOT v_priv AND v_start IS NOT NULL AND now() > v_start - interval '72 hours' THEN
      RAISE EXCEPTION 'CANCEL_DEADLINE_PASSED';
    END IF;
    IF v_kind = 'logement' THEN
      SELECT a.cancellation INTO v_policy FROM public.annonces a WHERE a.id = OLD.logement_id;
      NEW.refund_amount := CASE
        WHEN v_policy = 'flexible' THEN coalesce(OLD.total, 0)
        WHEN v_policy = 'moderate' AND v_start IS NOT NULL AND now() <= v_start - interval '5 days'
          THEN round(coalesce(OLD.total, 0) * 0.5, 2)
        ELSE 0 END;
    ELSE
      SELECT CASE WHEN e.free_cancellation THEN 'flexible' ELSE 'strict' END INTO v_policy
        FROM public.excursions e WHERE e.id = OLD.excursion_id;
      v_on_site := coalesce(OLD.payment_method, '') ILIKE '%sur place%';
      NEW.refund_amount := CASE WHEN NOT v_on_site AND v_policy = 'flexible' THEN coalesce(OLD.total, 0) ELSE 0 END;
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.fn_guest_cancel_policy() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_guest_cancel_policy ON public.reservations;
CREATE TRIGGER trg_guest_cancel_policy BEFORE UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.fn_guest_cancel_policy();
DROP TRIGGER IF EXISTS trg_guest_cancel_policy ON public.excursion_bookings;
CREATE TRIGGER trg_guest_cancel_policy BEFORE UPDATE ON public.excursion_bookings
  FOR EACH ROW EXECUTE FUNCTION public.fn_guest_cancel_policy();

COMMIT;
