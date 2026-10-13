-- =====================================================================
-- MyTunigo — Commissions hôtes et prestataires
-- Projet : fxbetakueqkzipsqvtck — 13/10/2026
--
-- Grille (décision de Bassem du 13/10/2026) :
--   - Voyageur : 0 % de frais, il paie le prix affiché.
--   - Hôte fondateur : 0 % de commission pendant 2 ans. Réservé aux 100
--     premiers hôtes qui publient une annonce (attribution automatique).
--     Badge « Hôte fondateur » public et meilleure visibilité.
--   - Hôte standard : 10 %. Hôte performant : 8 % (attribué par l'admin, puis
--     par un calcul trimestriel à venir).
--   - Excursions : 12 % par défaut, taux négocié possible par prestataire
--     (jamais moins de 8 %).
--
-- Ce que chacun voit :
--   - Le voyageur ne voit jamais la commission ni ce que touche l'hôte : les
--     montants nets sont dans booking_payouts, que seuls l'hôte / le
--     prestataire concerné et l'admin peuvent lire.
--   - L'hôte voit ce qu'il reçoit (prix − commission).
--
-- 1. host_plans       : niveau de chaque hôte (lu par lui-même et l'admin).
-- 2. booking_payouts  : montant brut, commission et net de chaque réservation
--                       confirmée, figés à la confirmation.
-- 3. Fondateurs       : attribués automatiquement à la première annonce
--                       publiée, dans la limite de 100.
-- 4. Fonctions        : devis de commission (site, e-mails), places de
--                       fondateur restantes, liste publique des fondateurs.
--
-- Les hôtes existants (comptes de test) sont mis en « standard » pour ne pas
-- consommer de places de fondateur ; l'admin peut les modifier.
-- À exécuter AVANT de fusionner la PR. Rejouable.
-- =====================================================================

BEGIN;

-- 1. Niveau de chaque hôte -------------------------------------------------
CREATE TABLE IF NOT EXISTS public.host_plans (
  user_id        uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  plan           text NOT NULL DEFAULT 'standard' CHECK (plan IN ('fondateur','standard','performant')),
  founder_number int UNIQUE CHECK (founder_number IS NULL OR founder_number BETWEEN 1 AND 100),
  founder_since  timestamptz,
  excursion_rate numeric CHECK (excursion_rate IS NULL OR excursion_rate BETWEEN 0.08 AND 0.30),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.host_plans ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS host_plans_select ON public.host_plans;
CREATE POLICY host_plans_select ON public.host_plans FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.fn_is_admin());
DROP POLICY IF EXISTS host_plans_admin_write ON public.host_plans;
CREATE POLICY host_plans_admin_write ON public.host_plans FOR ALL TO authenticated
  USING (public.fn_is_admin()) WITH CHECK (public.fn_is_admin());
REVOKE ALL ON public.host_plans FROM anon;
GRANT SELECT, INSERT, UPDATE ON public.host_plans TO authenticated;
GRANT SELECT ON public.host_plans TO service_role;


-- 2. Montants nets des réservations confirmées ----------------------------
CREATE TABLE IF NOT EXISTS public.booking_payouts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind            text NOT NULL CHECK (kind IN ('logement','excursion')),
  booking_id      uuid NOT NULL,
  owner_id        uuid NOT NULL,
  gross           numeric NOT NULL,
  plan            text NOT NULL,
  commission_rate numeric NOT NULL,
  commission      numeric NOT NULL,
  payout          numeric NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (kind, booking_id)
);
CREATE INDEX IF NOT EXISTS booking_payouts_owner_idx ON public.booking_payouts (owner_id);
ALTER TABLE public.booking_payouts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS booking_payouts_select ON public.booking_payouts;
CREATE POLICY booking_payouts_select ON public.booking_payouts FOR SELECT TO authenticated
  USING (owner_id = auth.uid() OR public.fn_is_admin());
REVOKE ALL ON public.booking_payouts FROM anon;
GRANT SELECT ON public.booking_payouts TO authenticated;
GRANT SELECT ON public.booking_payouts TO service_role;


-- 3. Devis de commission ---------------------------------------------------
-- Interne (serveur) : pour un hôte / prestataire et un montant brut.
CREATE OR REPLACE FUNCTION public.fn_commission_quote(p_owner uuid, p_kind text, p_gross numeric)
RETURNS TABLE(plan text, commission_rate numeric, commission numeric, payout numeric, founder_until timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  hp public.host_plans%ROWTYPE;
  v_plan text;
  v_rate numeric;
  v_until timestamptz;
  v_gross numeric := greatest(coalesce(p_gross, 0), 0);
BEGIN
  SELECT * INTO hp FROM public.host_plans h WHERE h.user_id = p_owner;
  v_plan := coalesce(hp.plan, 'standard');
  IF hp.plan = 'fondateur' AND hp.founder_since IS NOT NULL THEN
    v_until := hp.founder_since + interval '2 years';
  END IF;

  IF p_kind = 'excursion' THEN
    v_rate := coalesce(hp.excursion_rate, 0.12);
  ELSIF v_plan = 'fondateur' AND v_until > now() THEN
    v_rate := 0;
  ELSIF v_plan IN ('performant') THEN
    v_rate := 0.08;
  ELSE
    v_rate := 0.10;           -- standard, ou fondateur dont les 2 ans sont passés
  END IF;

  RETURN QUERY SELECT v_plan, v_rate, round(v_gross * v_rate, 2),
                      v_gross - round(v_gross * v_rate, 2), v_until;
END $$;
REVOKE ALL ON FUNCTION public.fn_commission_quote(uuid, text, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_commission_quote(uuid, text, numeric) TO service_role;

-- Pour l'hôte connecté (site) : son niveau et ce qu'il recevrait.
CREATE OR REPLACE FUNCTION public.fn_my_commission_quote(p_kind text, p_gross numeric)
RETURNS TABLE(plan text, commission_rate numeric, commission numeric, payout numeric, founder_until timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT * FROM public.fn_commission_quote(auth.uid(), p_kind, p_gross) WHERE auth.uid() IS NOT NULL;
$$;
REVOKE ALL ON FUNCTION public.fn_my_commission_quote(text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_my_commission_quote(text, numeric) TO authenticated;

-- Places de fondateur restantes (affichées publiquement)
CREATE OR REPLACE FUNCTION public.fn_founder_slots_left()
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT greatest(0, 100 - (SELECT count(*) FROM public.host_plans WHERE founder_number IS NOT NULL))::int;
$$;
REVOKE ALL ON FUNCTION public.fn_founder_slots_left() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_founder_slots_left() TO anon, authenticated, service_role;

-- Liste publique des hôtes fondateurs (pour le badge). N'expose que l'id.
CREATE OR REPLACE FUNCTION public.fn_founder_hosts()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT user_id FROM public.host_plans WHERE plan = 'fondateur';
$$;
REVOKE ALL ON FUNCTION public.fn_founder_hosts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_founder_hosts() TO anon, authenticated, service_role;


-- 4. Fondateur attribué à la première annonce publiée ----------------------
CREATE OR REPLACE FUNCTION public.fn_assign_host_plan()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count int;
BEGIN
  IF NEW.status IS DISTINCT FROM 'publiée' OR NEW.user_id IS NULL THEN
    RETURN NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = NEW.user_id) THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM public.host_plans WHERE user_id = NEW.user_id) THEN
    RETURN NULL;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('mytunigo_founders'));
  SELECT count(*) INTO v_count FROM public.host_plans WHERE founder_number IS NOT NULL;
  IF v_count < 100 THEN
    INSERT INTO public.host_plans(user_id, plan, founder_number, founder_since)
    VALUES (NEW.user_id, 'fondateur', v_count + 1, now())
    ON CONFLICT (user_id) DO NOTHING;
  ELSE
    INSERT INTO public.host_plans(user_id, plan) VALUES (NEW.user_id, 'standard')
    ON CONFLICT (user_id) DO NOTHING;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.fn_assign_host_plan() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_assign_host_plan ON public.annonces;
CREATE TRIGGER trg_assign_host_plan AFTER INSERT OR UPDATE OF status ON public.annonces
  FOR EACH ROW EXECUTE FUNCTION public.fn_assign_host_plan();


-- 5. Montant net figé à la confirmation -----------------------------------
CREATE OR REPLACE FUNCTION public.fn_record_payout()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_kind text := CASE TG_TABLE_NAME WHEN 'reservations' THEN 'logement' ELSE 'excursion' END;
  v_owner uuid;
  q record;
BEGIN
  IF NEW.status IS DISTINCT FROM 'confirmée' THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM public.booking_payouts WHERE kind = v_kind AND booking_id = NEW.id) THEN
    RETURN NULL;
  END IF;
  IF v_kind = 'logement' THEN
    SELECT a.user_id INTO v_owner FROM public.annonces a WHERE a.id = NEW.logement_id;
  ELSE
    SELECT e.owner_id INTO v_owner FROM public.excursions e WHERE e.id = NEW.excursion_id;
  END IF;
  IF v_owner IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO q FROM public.fn_commission_quote(v_owner, v_kind, NEW.total);
  INSERT INTO public.booking_payouts(kind, booking_id, owner_id, gross, plan, commission_rate, commission, payout)
  VALUES (v_kind, NEW.id, v_owner, coalesce(NEW.total, 0), q.plan, q.commission_rate, q.commission, q.payout)
  ON CONFLICT (kind, booking_id) DO NOTHING;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.fn_record_payout() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_record_payout ON public.reservations;
CREATE TRIGGER trg_record_payout AFTER INSERT OR UPDATE OF status ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.fn_record_payout();
DROP TRIGGER IF EXISTS trg_record_payout ON public.excursion_bookings;
CREATE TRIGGER trg_record_payout AFTER INSERT OR UPDATE OF status ON public.excursion_bookings
  FOR EACH ROW EXECUTE FUNCTION public.fn_record_payout();


-- 6. Existant ---------------------------------------------------------------
-- Hôtes et prestataires déjà présents (comptes de test) : standard, sans
-- consommer de place de fondateur.
INSERT INTO public.host_plans(user_id, plan)
SELECT DISTINCT a.user_id, 'standard' FROM public.annonces a
 WHERE a.user_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = a.user_id)
ON CONFLICT (user_id) DO NOTHING;
INSERT INTO public.host_plans(user_id, plan)
SELECT DISTINCT e.owner_id, 'standard' FROM public.excursions e
 WHERE e.owner_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = e.owner_id)
ON CONFLICT (user_id) DO NOTHING;

-- Montants nets des réservations déjà confirmées ou terminées
INSERT INTO public.booking_payouts(kind, booking_id, owner_id, gross, plan, commission_rate, commission, payout)
SELECT 'logement', r.id, a.user_id, coalesce(r.total, 0), q.plan, q.commission_rate, q.commission, q.payout
  FROM public.reservations r
  JOIN public.annonces a ON a.id = r.logement_id
  CROSS JOIN LATERAL public.fn_commission_quote(a.user_id, 'logement', r.total) q
 WHERE r.status IN ('confirmée','terminée') AND a.user_id IS NOT NULL
ON CONFLICT (kind, booking_id) DO NOTHING;
INSERT INTO public.booking_payouts(kind, booking_id, owner_id, gross, plan, commission_rate, commission, payout)
SELECT 'excursion', b.id, e.owner_id, coalesce(b.total, 0), q.plan, q.commission_rate, q.commission, q.payout
  FROM public.excursion_bookings b
  JOIN public.excursions e ON e.id = b.excursion_id
  CROSS JOIN LATERAL public.fn_commission_quote(e.owner_id, 'excursion', b.total) q
 WHERE b.status IN ('confirmée','terminée') AND e.owner_id IS NOT NULL
ON CONFLICT (kind, booking_id) DO NOTHING;

COMMIT;
