-- =====================================================================
-- MyTunigo — Nouvelle grille tarifaire des logements (17/10/2026)
-- Projet : fxbetakueqkzipsqvtck
--
-- Règle (décision de Bassem du 17/10) :
--   * Voyageur : paie le prix fixé par l'hôte + 8 % de frais de service,
--     affiché tout compris (il ne voit jamais le prix de l'hôte).
--     Remplace les anciens « taxes et frais » de 10 %.
--   * Hôte : reçoit son prix − 8 % de commission (il ne voit jamais ce que
--     le voyageur a payé).
--   * Badge « Hôte fondateur » : attribué par l'admin, à tout moment, sur
--     l'annonce de son choix, sans limite de nombre (les « 100 places » sont
--     un argument publicitaire). Annonce fondatrice : 0 % de commission
--     pendant 1 an à partir de l'attribution, puis 8 %.
--   * Excursions : inchangées (autre chantier) — 12 % prestataire par défaut,
--     pas de frais voyageur.
--
-- Contenu :
--   1. annonces.founder_since (badge) + verrou : seul l'admin le modifie.
--   2. Prix d'une demande calculé EN BASE à l'insertion (le total envoyé par
--      le navigateur est remplacé) ; prix hôte gardé dans une table privée
--      reservation_pricing, illisible par le voyageur.
--   3. fn_commission_quote(kind, booking) et reversements recalculés.
--   4. fn_my_booking_nets(kind, ids) : ce que l'hôte connecté reçoit.
--   5. Retrait de l'attribution automatique des fondateurs (13/10).
-- Rejouable.
-- =====================================================================

BEGIN;

-- Constantes de la grille (une seule source de vérité côté base)
CREATE OR REPLACE FUNCTION public.fn_tarif(p_key text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_key
    WHEN 'frais_voyageur'      THEN 0.08   -- ajouté au prix de l'hôte
    WHEN 'commission_hote'     THEN 0.08   -- retiré du prix de l'hôte
    WHEN 'commission_excursion' THEN 0.12  -- excursions (inchangé)
  END;
$$;

-- ---------------------------------------------------------------------
-- 1. Badge « Hôte fondateur » par annonce
-- ---------------------------------------------------------------------
ALTER TABLE public.annonces ADD COLUMN IF NOT EXISTS founder_since timestamptz;

CREATE OR REPLACE FUNCTION public.fn_annonce_founder_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF current_user IN ('postgres','service_role','supabase_admin') OR public.fn_is_admin() THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.founder_since IS NOT NULL THEN RAISE EXCEPTION 'FOUNDER_ADMIN_ONLY'; END IF;
  ELSIF NEW.founder_since IS DISTINCT FROM OLD.founder_since THEN
    RAISE EXCEPTION 'FOUNDER_ADMIN_ONLY';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.fn_annonce_founder_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_annonce_founder_guard ON public.annonces;
CREATE TRIGGER trg_annonce_founder_guard BEFORE INSERT OR UPDATE ON public.annonces
  FOR EACH ROW EXECUTE FUNCTION public.fn_annonce_founder_guard();

-- Fin de l'attribution automatique du 13/10 (100 premiers hôtes publiés)
DROP TRIGGER IF EXISTS trg_assign_host_plan ON public.annonces;
DROP FUNCTION IF EXISTS public.fn_assign_host_plan();
DROP FUNCTION IF EXISTS public.fn_founder_slots_left();
DROP FUNCTION IF EXISTS public.fn_founder_hosts();
DROP FUNCTION IF EXISTS public.fn_my_commission_quote(text, numeric);
DROP FUNCTION IF EXISTS public.fn_commission_quote(uuid, text, numeric);
-- host_plans reste pour le taux négocié des excursions (excursion_rate).

-- ---------------------------------------------------------------------
-- 2. Prix calculé en base
-- ---------------------------------------------------------------------
-- Même calcul que le site (datePriceNight) : prix fixe du jour s'il existe,
-- sinon pourcentage du jour, sinon promo globale de l'annonce, sinon prix
-- de base. Le prix voyageur de chaque nuit = arrondi(prix hôte × 1,08).
CREATE OR REPLACE FUNCTION public.fn_logement_pricing(p_annonce uuid, p_check_in date, p_check_out date, p_rooms int)
RETURNS TABLE(host_subtotal numeric, guest_total numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_base numeric; v_disc numeric; d date; v_night numeric; v_row record;
  v_host numeric := 0; v_guest numeric := 0; v_rooms int := greatest(coalesce(p_rooms,1),1);
BEGIN
  SELECT price_night, coalesce(discount_percent,0) INTO v_base, v_disc FROM public.annonces WHERE id = p_annonce;
  IF v_base IS NULL OR p_check_in IS NULL OR p_check_out IS NULL OR p_check_out <= p_check_in THEN
    RETURN QUERY SELECT 0::numeric, 0::numeric; RETURN;
  END IF;
  d := p_check_in;
  WHILE d < p_check_out LOOP
    SELECT discount_percent, price_override INTO v_row FROM public.date_discounts
      WHERE annonce_id = p_annonce AND date = d LIMIT 1;
    IF FOUND AND v_row.price_override IS NOT NULL THEN
      v_night := round(v_row.price_override);
    ELSIF FOUND THEN
      v_night := CASE WHEN coalesce(v_row.discount_percent,0) <> 0
                      THEN round(v_base * (1 - v_row.discount_percent / 100.0)) ELSE v_base END;
    ELSE
      v_night := CASE WHEN v_disc <> 0 THEN round(v_base * (1 - v_disc / 100.0)) ELSE v_base END;
    END IF;
    v_host  := v_host + v_night;
    v_guest := v_guest + round(v_night * (1 + public.fn_tarif('frais_voyageur')));
    d := d + 1;
  END LOOP;
  RETURN QUERY SELECT v_host * v_rooms, v_guest * v_rooms;
END $$;
REVOKE ALL ON FUNCTION public.fn_logement_pricing(uuid, date, date, int) FROM PUBLIC, anon, authenticated;

-- Prix hôte de chaque demande : lisible par l'hôte de l'annonce et l'admin,
-- jamais par le voyageur.
CREATE TABLE IF NOT EXISTS public.reservation_pricing (
  reservation_id uuid PRIMARY KEY REFERENCES public.reservations(id) ON DELETE CASCADE,
  host_subtotal  numeric NOT NULL,
  guest_total    numeric NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.reservation_pricing ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reservation_pricing_select ON public.reservation_pricing;
CREATE POLICY reservation_pricing_select ON public.reservation_pricing FOR SELECT TO authenticated
  USING (public.fn_is_admin() OR EXISTS (
    SELECT 1 FROM public.reservations r JOIN public.annonces a ON a.id = r.logement_id
    WHERE r.id = reservation_id AND a.user_id = auth.uid()));
REVOKE ALL ON public.reservation_pricing FROM anon;
GRANT SELECT ON public.reservation_pricing TO authenticated;
GRANT SELECT ON public.reservation_pricing TO service_role;

-- À l'insertion d'une demande : le total est recalculé en base (le montant
-- envoyé par le navigateur est ignoré).
CREATE OR REPLACE FUNCTION public.fn_reservation_set_price()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p record;
BEGIN
  SELECT * INTO p FROM public.fn_logement_pricing(NEW.logement_id, NEW.check_in, NEW.check_out, NEW.rooms);
  IF p.guest_total > 0 THEN
    NEW.total := p.guest_total;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.fn_reservation_set_price() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_reservation_set_price ON public.reservations;
CREATE TRIGGER trg_reservation_set_price BEFORE INSERT ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.fn_reservation_set_price();

CREATE OR REPLACE FUNCTION public.fn_reservation_store_pricing()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p record;
BEGIN
  SELECT * INTO p FROM public.fn_logement_pricing(NEW.logement_id, NEW.check_in, NEW.check_out, NEW.rooms);
  INSERT INTO public.reservation_pricing(reservation_id, host_subtotal, guest_total)
  VALUES (NEW.id,
          CASE WHEN p.guest_total > 0 THEN p.host_subtotal
               ELSE round(coalesce(NEW.total,0) / (1 + public.fn_tarif('frais_voyageur')), 2) END,
          coalesce(NEW.total,0))
  ON CONFLICT (reservation_id) DO NOTHING;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.fn_reservation_store_pricing() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_reservation_store_pricing ON public.reservations;
CREATE TRIGGER trg_reservation_store_pricing AFTER INSERT ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.fn_reservation_store_pricing();

-- Demandes existantes : elles ont été calculées avec les anciens 10 %.
INSERT INTO public.reservation_pricing(reservation_id, host_subtotal, guest_total)
SELECT r.id, round(coalesce(r.total,0) / 1.10, 2), coalesce(r.total,0)
FROM public.reservations r
ON CONFLICT (reservation_id) DO NOTHING;

-- ---------------------------------------------------------------------
-- 3. Commission et reversements
-- ---------------------------------------------------------------------
ALTER TABLE public.booking_payouts ADD COLUMN IF NOT EXISTS host_amount numeric;
ALTER TABLE public.booking_payouts ADD COLUMN IF NOT EXISTS guest_fee numeric;

-- Taux d'une annonce à un instant donné : fondatrice depuis moins d'1 an → 0.
CREATE OR REPLACE FUNCTION public.fn_annonce_rate(p_annonce uuid, p_at timestamptz DEFAULT now())
RETURNS TABLE(plan text, rate numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN a.founder_since IS NOT NULL THEN 'fondateur' ELSE 'standard' END,
         CASE WHEN a.founder_since IS NOT NULL AND a.founder_since <= p_at
                   AND p_at < a.founder_since + interval '1 year' THEN 0::numeric
              ELSE public.fn_tarif('commission_hote') END
  FROM public.annonces a WHERE a.id = p_annonce;
$$;
REVOKE ALL ON FUNCTION public.fn_annonce_rate(uuid, timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_commission_quote(p_kind text, p_booking uuid)
RETURNS TABLE(owner_id uuid, gross numeric, host_amount numeric, guest_fee numeric,
              plan text, commission_rate numeric, commission numeric, payout numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_owner uuid; v_gross numeric; v_host numeric; v_plan text; v_rate numeric; v_ann uuid;
BEGIN
  IF p_kind = 'logement' THEN
    SELECT a.user_id, coalesce(r.total,0), r.logement_id, coalesce(rp.host_subtotal, round(coalesce(r.total,0) / (1 + public.fn_tarif('frais_voyageur')), 2))
      INTO v_owner, v_gross, v_ann, v_host
      FROM public.reservations r
      JOIN public.annonces a ON a.id = r.logement_id
      LEFT JOIN public.reservation_pricing rp ON rp.reservation_id = r.id
     WHERE r.id = p_booking;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT q.plan, q.rate INTO v_plan, v_rate FROM public.fn_annonce_rate(v_ann) q;
  ELSIF p_kind = 'excursion' THEN
    SELECT e.owner_id, coalesce(b.total,0) INTO v_owner, v_gross
      FROM public.excursion_bookings b JOIN public.excursions e ON e.id = b.excursion_id
     WHERE b.id = p_booking;
    IF NOT FOUND THEN RETURN; END IF;
    v_host := v_gross;
    v_plan := 'excursion';
    SELECT coalesce((SELECT h.excursion_rate FROM public.host_plans h WHERE h.user_id = v_owner),
                    public.fn_tarif('commission_excursion')) INTO v_rate;
  ELSE
    RETURN;
  END IF;
  RETURN QUERY SELECT v_owner, v_gross, v_host, v_gross - v_host, v_plan, v_rate,
                      round(v_host * v_rate, 2), v_host - round(v_host * v_rate, 2);
END $$;
REVOKE ALL ON FUNCTION public.fn_commission_quote(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_commission_quote(text, uuid) TO service_role;

-- Reversement figé à la confirmation
CREATE OR REPLACE FUNCTION public.fn_record_payout()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_kind text := CASE WHEN TG_TABLE_NAME = 'reservations' THEN 'logement' ELSE 'excursion' END;
        q record;
BEGIN
  IF NEW.status IS DISTINCT FROM 'confirmée' THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM public.booking_payouts WHERE kind = v_kind AND booking_id = NEW.id) THEN RETURN NULL; END IF;
  SELECT * INTO q FROM public.fn_commission_quote(v_kind, NEW.id);
  IF q.owner_id IS NULL THEN RETURN NULL; END IF;
  INSERT INTO public.booking_payouts(kind, booking_id, owner_id, gross, host_amount, guest_fee, plan, commission_rate, commission, payout)
  VALUES (v_kind, NEW.id, q.owner_id, q.gross, q.host_amount, q.guest_fee, q.plan, q.commission_rate, q.commission, q.payout)
  ON CONFLICT (kind, booking_id) DO NOTHING;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.fn_record_payout() FROM PUBLIC, anon, authenticated;

-- Recalcul de tous les reversements existants avec la nouvelle grille
DELETE FROM public.booking_payouts;
INSERT INTO public.booking_payouts(kind, booking_id, owner_id, gross, host_amount, guest_fee, plan, commission_rate, commission, payout)
SELECT 'logement', r.id, q.owner_id, q.gross, q.host_amount, q.guest_fee, q.plan, q.commission_rate, q.commission, q.payout
FROM public.reservations r CROSS JOIN LATERAL public.fn_commission_quote('logement', r.id) q
WHERE r.status IN ('confirmée','terminée') AND q.owner_id IS NOT NULL;
INSERT INTO public.booking_payouts(kind, booking_id, owner_id, gross, host_amount, guest_fee, plan, commission_rate, commission, payout)
SELECT 'excursion', b.id, q.owner_id, q.gross, q.host_amount, q.guest_fee, q.plan, q.commission_rate, q.commission, q.payout
FROM public.excursion_bookings b CROSS JOIN LATERAL public.fn_commission_quote('excursion', b.id) q
WHERE b.status IN ('confirmée','terminée') AND q.owner_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 4. Ce que l'hôte connecté reçoit (site) : reversement figé s'il existe,
--    sinon devis. Seulement pour ses propres réservations.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_my_booking_nets(p_kind text, p_ids uuid[])
RETURNS TABLE(booking_id uuid, payout numeric, commission_rate numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT x.id,
         coalesce(bp.payout, q.payout),
         coalesce(bp.commission_rate, q.commission_rate)
  FROM unnest(p_ids) AS x(id)
  LEFT JOIN public.booking_payouts bp ON bp.kind = p_kind AND bp.booking_id = x.id
  CROSS JOIN LATERAL public.fn_commission_quote(p_kind, x.id) q
  WHERE auth.uid() IS NOT NULL AND q.owner_id = auth.uid();
$$;
REVOKE ALL ON FUNCTION public.fn_my_booking_nets(text, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_my_booking_nets(text, uuid[]) TO authenticated;

COMMIT;
