-- =====================================================================
-- MyTunigo — Excursions : paiement en ligne obligatoire (18/10/2026)
-- Projet : fxbetakueqkzipsqvtck
--
-- Règle (décision de Bassem du 18/10) :
--   * Même processus que les logements : demande -> l'organisateur accepte
--     -> le voyageur a 24 h pour payer en ligne -> réservation confirmée.
--     Réservation instantanée : place bloquée 30 min, le temps de payer.
--     Non payée à temps -> « expirée », les places sont libérées.
--   * Excursion payée en ligne : même grille que les logements. Le voyageur
--     paie le prix + 8 % de taxes et frais ; l'organisateur reçoit le prix
--     − 8 %.
--   * Excursion « paiement sur place » : le voyageur paie en ligne un
--     acompte de 10 % du prix (gardé par MyTunigo) et règle les 90 % restants
--     sur place à l'organisateur.
--   * Annulation au moins 72 h avant : ce qui a été payé en ligne est
--     remboursé si la politique est Flexible, gardé si elle est Stricte.
--
-- Contenu :
--   1. Statuts « acceptée » et « expirée », colonnes de paiement.
--   2. Contrôle des réservations (prix, montants, transitions).
--   3. Places : une réservation acceptée non payée bloque les places
--      jusqu'à la fin de son délai.
--   4. Commission et reversements des excursions.
--   5. Remboursement en cas d'annulation (fn_guest_cancel_policy).
--   6. Tâche planifiée : expiration des paiements toutes les 10 min.
-- Rejouable.
-- =====================================================================

BEGIN;

-- Grille (complète fn_tarif du 17/10)
CREATE OR REPLACE FUNCTION public.fn_tarif(p_key text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_key
    WHEN 'frais_voyageur'       THEN 0.08   -- ajouté au prix de l'hôte / de l'organisateur
    WHEN 'commission_hote'      THEN 0.08   -- retiré du prix de l'hôte
    WHEN 'commission_excursion' THEN 0.08   -- excursions payées en ligne (même grille)
    WHEN 'acompte_sur_place'    THEN 0.10   -- excursions payées sur place : acompte en ligne
  END;
$$;

-- ---------------------------------------------------------------------
-- 1. Statuts et colonnes
-- ---------------------------------------------------------------------
ALTER TABLE public.excursion_bookings DROP CONSTRAINT IF EXISTS excursion_bookings_status_check;
ALTER TABLE public.excursion_bookings ADD CONSTRAINT excursion_bookings_status_check
  CHECK (status = ANY (ARRAY['en attente','acceptée','confirmée','refusée','annulée','terminée','expirée']));

ALTER TABLE public.excursion_bookings ADD COLUMN IF NOT EXISTS pay_on_site      boolean NOT NULL DEFAULT false;
ALTER TABLE public.excursion_bookings ADD COLUMN IF NOT EXISTS online_amount    numeric;   -- à payer en ligne
ALTER TABLE public.excursion_bookings ADD COLUMN IF NOT EXISTS on_site_amount   numeric;   -- à régler sur place
ALTER TABLE public.excursion_bookings ADD COLUMN IF NOT EXISTS accepted_at      timestamptz;
ALTER TABLE public.excursion_bookings ADD COLUMN IF NOT EXISTS payment_deadline timestamptz;
ALTER TABLE public.excursion_bookings ADD COLUMN IF NOT EXISTS paid_at          timestamptz;
ALTER TABLE public.excursion_bookings ADD COLUMN IF NOT EXISTS expired_reason   text;

-- Réservations existantes (toutes « paiement sur place », rien payé en ligne)
UPDATE public.excursion_bookings
   SET pay_on_site    = coalesce(payment_method, '') ILIKE '%sur place%',
       online_amount  = coalesce(online_amount, 0),
       on_site_amount = coalesce(on_site_amount, CASE WHEN coalesce(payment_method,'') ILIKE '%sur place%' THEN total ELSE 0 END)
 WHERE online_amount IS NULL;

-- Début d'une excursion réservée (heure de Tunis)
CREATE OR REPLACE FUNCTION public.fn_excursion_start(p_excursion uuid, p_date date)
RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT (p_date + public.fn_safe_time(e.meeting_time, '00:00')) AT TIME ZONE 'Africa/Tunis'
  FROM public.excursions e WHERE e.id = p_excursion;
$$;
REVOKE ALL ON FUNCTION public.fn_excursion_start(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_excursion_start(uuid, date) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. Contrôle des réservations d'excursion
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_excursion_booking_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  privileged boolean := current_user IN ('postgres', 'service_role', 'supabase_admin');
  v_price    numeric;
  v_instant  boolean;
  v_on_site  boolean;
  v_owner    uuid;
  v_sub      numeric;
  v_start    timestamptz;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT price, COALESCE(instant_book, false), COALESCE(pay_on_site, false)
      INTO v_price, v_instant, v_on_site
      FROM public.excursions WHERE id = NEW.excursion_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'EXCURSION_NOT_FOUND';
    END IF;
    IF NEW.participants IS NULL OR NEW.participants < 1 THEN
      RAISE EXCEPTION 'INVALID_PARTICIPANTS';
    END IF;
    v_sub := COALESCE(v_price, 0) * NEW.participants;
    NEW.unit_price  := COALESCE(v_price, 0);
    NEW.pay_on_site := v_on_site;
    IF v_on_site THEN
      -- Acompte en ligne (MyTunigo) + reste sur place (organisateur)
      NEW.total          := v_sub;
      NEW.online_amount  := round(v_sub * public.fn_tarif('acompte_sur_place'), 2);
      NEW.on_site_amount := v_sub - NEW.online_amount;
      NEW.payment_method := 'Acompte en ligne + paiement sur place';
    ELSE
      -- Paiement complet en ligne : prix + taxes et frais
      NEW.total          := v_sub + round(v_sub * public.fn_tarif('frais_voyageur'));
      NEW.online_amount  := NEW.total;
      NEW.on_site_amount := 0;
      NEW.payment_method := 'en ligne';
    END IF;
    NEW.paid_at := NULL;
    IF privileged THEN
      RETURN NEW;
    END IF;
    IF v_instant THEN
      -- Réservation instantanée : place bloquée 30 min, le temps de payer
      NEW.status           := 'acceptée';
      NEW.accepted_at      := now();
      NEW.payment_deadline := now() + interval '30 minutes';
    ELSE
      NEW.status           := 'en attente';
      NEW.accepted_at      := NULL;
      NEW.payment_deadline := NULL;
    END IF;
    RETURN NEW;
  END IF;

  IF privileged THEN
    RETURN NEW;
  END IF;

  -- UPDATE : champs figés après création
  NEW.excursion_id     := OLD.excursion_id;
  NEW.guest_id         := OLD.guest_id;
  NEW.date             := OLD.date;
  NEW.participants     := OLD.participants;
  NEW.unit_price       := OLD.unit_price;
  NEW.total            := OLD.total;
  NEW.reference        := OLD.reference;
  NEW.payment_method   := OLD.payment_method;
  NEW.created_at       := OLD.created_at;
  NEW.pay_on_site      := OLD.pay_on_site;
  NEW.online_amount    := OLD.online_amount;
  NEW.on_site_amount   := OLD.on_site_amount;
  NEW.accepted_at      := OLD.accepted_at;
  NEW.payment_deadline := OLD.payment_deadline;
  NEW.paid_at          := OLD.paid_at;
  NEW.expired_reason   := OLD.expired_reason;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    SELECT owner_id INTO v_owner FROM public.excursions WHERE id = OLD.excursion_id;

    IF NEW.status = 'annulée'
       AND OLD.status IN ('en attente', 'acceptée', 'confirmée')
       AND OLD.guest_id = auth.uid() THEN
      NULL;  -- annulation par le voyageur (délai contrôlé par fn_guest_cancel_policy)
    ELSIF NEW.status = 'refusée' AND OLD.status = 'en attente' AND v_owner = auth.uid() THEN
      NULL;  -- refus du prestataire
    ELSIF NEW.status = 'acceptée' AND OLD.status = 'en attente' AND v_owner = auth.uid() THEN
      -- Acceptation : 24 h pour payer, sans dépasser le début de l'excursion
      v_start := public.fn_excursion_start(OLD.excursion_id, OLD.date);
      IF v_start IS NOT NULL AND v_start <= now() THEN
        RAISE EXCEPTION 'EXCURSION_STARTED';
      END IF;
      NEW.accepted_at      := now();
      NEW.payment_deadline := least(now() + interval '24 hours', coalesce(v_start, now() + interval '24 hours'));
    ELSE
      -- « confirmée » (paiement) et « expirée » : réservés au serveur
      RAISE EXCEPTION 'INVALID_TRANSITION: % -> %', OLD.status, NEW.status;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
-- 3. Places : en attente, confirmée, et acceptée dans son délai de paiement
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_check_excursion_capacity()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_max int;
  v_used int;
BEGIN
  IF NEW.status NOT IN ('en attente','acceptée','confirmée') THEN
    RETURN NEW;
  END IF;
  -- Une réservation déjà comptée qui change seulement de statut ne se recontrôle pas
  IF TG_OP = 'UPDATE' AND OLD.status IN ('en attente','acceptée','confirmée')
     AND NEW.participants = OLD.participants AND NEW.date = OLD.date THEN
    RETURN NEW;
  END IF;

  PERFORM 1 FROM excursions WHERE id = NEW.excursion_id FOR UPDATE;
  SELECT max_participants INTO v_max FROM excursions WHERE id = NEW.excursion_id;

  SELECT COALESCE(SUM(participants),0) INTO v_used
    FROM excursion_bookings
    WHERE excursion_id = NEW.excursion_id
      AND date = NEW.date
      AND (status IN ('en attente','confirmée')
           OR (status = 'acceptée' AND coalesce(payment_deadline, now()) > now()))
      AND id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid);

  IF v_max IS NOT NULL AND v_used + NEW.participants > v_max THEN
    RAISE EXCEPTION 'CAPACITY_EXCEEDED: % places restantes sur % pour cette date', GREATEST(v_max - v_used,0), v_max;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_excursion_spots_taken(p_excursion_id uuid, p_date date)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  select coalesce(sum(participants), 0)::integer
  from excursion_bookings
  where excursion_id = p_excursion_id
    and date = p_date
    and (status in ('en attente', 'confirmée')
         or (status = 'acceptée' and coalesce(payment_deadline, now()) > now()));
$$;

-- ---------------------------------------------------------------------
-- 4. Commission des excursions
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_commission_quote(p_kind text, p_booking uuid)
RETURNS TABLE(owner_id uuid, gross numeric, host_amount numeric, guest_fee numeric,
              plan text, commission_rate numeric, commission numeric, payout numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_owner uuid; v_gross numeric; v_host numeric; v_plan text; v_rate numeric; v_ann uuid;
        v_on_site boolean; v_online numeric; v_sub numeric;
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
    RETURN QUERY SELECT v_owner, v_gross, v_host, v_gross - v_host, v_plan, v_rate,
                        round(v_host * v_rate, 2), v_host - round(v_host * v_rate, 2);
  ELSIF p_kind = 'excursion' THEN
    SELECT e.owner_id, coalesce(b.total,0), coalesce(b.pay_on_site,false), coalesce(b.online_amount,0),
           coalesce(b.unit_price,0) * coalesce(b.participants,1)
      INTO v_owner, v_gross, v_on_site, v_online, v_sub
      FROM public.excursion_bookings b JOIN public.excursions e ON e.id = b.excursion_id
     WHERE b.id = p_booking;
    IF NOT FOUND THEN RETURN; END IF;
    IF v_on_site THEN
      -- Acompte en ligne gardé par MyTunigo ; l'organisateur encaisse le reste sur place
      RETURN QUERY SELECT v_owner, v_gross, v_gross, 0::numeric, 'excursion_sur_place'::text,
                          public.fn_tarif('acompte_sur_place'), v_online, v_gross - v_online;
    ELSE
      v_rate := public.fn_tarif('commission_excursion');
      RETURN QUERY SELECT v_owner, v_gross, v_sub, v_gross - v_sub, 'excursion'::text, v_rate,
                          round(v_sub * v_rate, 2), v_sub - round(v_sub * v_rate, 2);
    END IF;
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.fn_commission_quote(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_commission_quote(text, uuid) TO service_role;

-- ---------------------------------------------------------------------
-- 5. Remboursement à l'annulation : ce qui a été payé en ligne
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_guest_cancel_policy()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_kind  text := CASE WHEN TG_TABLE_NAME = 'reservations' THEN 'logement' ELSE 'excursion' END;
  v_priv  boolean := current_user IN ('postgres','service_role','supabase_admin') OR public.fn_is_admin();
  v_start timestamptz;
  v_policy text;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status OR NEW.status <> 'annulée' THEN
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
      -- Seul ce qui a été payé en ligne peut être remboursé
      NEW.refund_amount := CASE WHEN v_policy = 'flexible' AND OLD.paid_at IS NOT NULL
                                THEN coalesce(OLD.online_amount, 0) ELSE 0 END;
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.fn_guest_cancel_policy() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. Expiration des paiements non faits : toutes les 10 minutes
--    (la fonction notify-excursion-booking passe les réservations en
--    « expirée » et prévient le voyageur)
-- ---------------------------------------------------------------------
DO $$
BEGIN
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'mytunigo-expire-excursion-payments';
  PERFORM cron.schedule('mytunigo-expire-excursion-payments', '*/10 * * * *',
                        'SELECT fn_auto_reject_expired_excursion_bookings();');
END $$;

COMMIT;
