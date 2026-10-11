-- =====================================================================
-- MyTunigo — Code de réservation (6 caractères)
-- Projet : fxbetakueqkzipsqvtck — 11/10/2026
--
-- Contrôle supplémentaire à l'arrivée (ne prouve pas l'identité) :
-- chaque réservation CONFIRMÉE — logement ou excursion — reçoit un code
-- de 6 caractères, par ex. K7P4QX. Le voyageur le voit dans « Mes voyages »
-- (et peut le transmettre à ses enfants / amis) ; l'hôte ou l'organisateur
-- le voit sur la réservation et le demande sur place.
--
-- - Logement : code créé quand la réservation passe « confirmée » (après
--   le paiement).
-- - Excursion : code créé à la réservation si elle est confirmée
--   automatiquement, sinon quand l'organisateur l'accepte.
-- - Code UNIQUE sur toute la plateforme (logements + excursions) : chaque
--   code est inscrit dans un registre commun dont il est la clé primaire.
-- - Caractères sans ambiguïté (pas de 0/O, 1/I/L).
-- - Le code ne peut être ni choisi ni modifié depuis le navigateur.
-- - Seuls le voyageur et l'hôte / l'organisateur peuvent le lire (règles
--   d'accès existantes des réservations).
--
-- À exécuter AVANT de fusionner la PR. Rejouable.
-- =====================================================================

BEGIN;

ALTER TABLE public.reservations       ADD COLUMN IF NOT EXISTS booking_code text;
ALTER TABLE public.excursion_bookings ADD COLUMN IF NOT EXISTS booking_code text;
CREATE UNIQUE INDEX IF NOT EXISTS reservations_booking_code_key       ON public.reservations (booking_code);
CREATE UNIQUE INDEX IF NOT EXISTS excursion_bookings_booking_code_key ON public.excursion_bookings (booking_code);

-- Registre commun : garantit qu'un code n'existe qu'une fois, toutes
-- réservations confondues. Aucun accès depuis le site.
CREATE TABLE IF NOT EXISTS public.booking_codes (
  code       text PRIMARY KEY CHECK (code ~ '^[A-HJKMNP-Z2-9]{6}$'),
  kind       text NOT NULL CHECK (kind IN ('logement','excursion')),
  booking_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.booking_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.booking_codes FROM PUBLIC, anon, authenticated;

-- Tire un code libre et l'inscrit au registre (réessaie en cas de doublon).
CREATE OR REPLACE FUNCTION public.fn_new_booking_code(p_kind text, p_booking_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code text;
  i int;
BEGIN
  FOR attempt IN 1..50 LOOP
    v_code := '';
    FOR i IN 1..6 LOOP
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    END LOOP;
    BEGIN
      INSERT INTO booking_codes(code, kind, booking_id) VALUES (v_code, p_kind, p_booking_id);
      RETURN v_code;
    EXCEPTION WHEN unique_violation THEN
      -- code déjà pris : on recommence
    END;
  END LOOP;
  RAISE EXCEPTION 'BOOKING_CODE_UNAVAILABLE';
END $$;
REVOKE ALL ON FUNCTION public.fn_new_booking_code(text, uuid) FROM PUBLIC, anon, authenticated;

-- Trigger commun aux deux tables : code figé, créé à la confirmation.
CREATE OR REPLACE FUNCTION public.fn_booking_code_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_kind text := CASE TG_TABLE_NAME WHEN 'reservations' THEN 'logement' ELSE 'excursion' END;
BEGIN
  -- Jamais choisi ni modifié depuis le navigateur
  IF TG_OP = 'INSERT' THEN
    NEW.booking_code := NULL;
  ELSE
    NEW.booking_code := OLD.booking_code;
  END IF;
  IF NEW.booking_code IS NULL AND NEW.status = 'confirmée' THEN
    NEW.booking_code := public.fn_new_booking_code(v_kind, NEW.id);
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.fn_booking_code_trigger() FROM PUBLIC, anon, authenticated;

-- « zz » : s'exécute après les contrôles existants (ordre alphabétique)
DROP TRIGGER IF EXISTS trg_zz_booking_code ON public.reservations;
CREATE TRIGGER trg_zz_booking_code BEFORE INSERT OR UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.fn_booking_code_trigger();
DROP TRIGGER IF EXISTS trg_zz_booking_code ON public.excursion_bookings;
CREATE TRIGGER trg_zz_booking_code BEFORE INSERT OR UPDATE ON public.excursion_bookings
  FOR EACH ROW EXECUTE FUNCTION public.fn_booking_code_trigger();

-- Codes pour les réservations déjà confirmées (trigger désactivé le temps
-- du rattrapage, pour que le code tiré ici soit bien celui enregistré)
ALTER TABLE public.reservations       DISABLE TRIGGER trg_zz_booking_code;
ALTER TABLE public.excursion_bookings DISABLE TRIGGER trg_zz_booking_code;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM public.reservations WHERE status = 'confirmée' AND booking_code IS NULL LOOP
    UPDATE public.reservations SET booking_code = public.fn_new_booking_code('logement', r.id) WHERE id = r.id;
  END LOOP;
  FOR r IN SELECT id FROM public.excursion_bookings WHERE status = 'confirmée' AND booking_code IS NULL LOOP
    UPDATE public.excursion_bookings SET booking_code = public.fn_new_booking_code('excursion', r.id) WHERE id = r.id;
  END LOOP;
END $$;
ALTER TABLE public.reservations       ENABLE TRIGGER trg_zz_booking_code;
ALTER TABLE public.excursion_bookings ENABLE TRIGGER trg_zz_booking_code;

COMMIT;
