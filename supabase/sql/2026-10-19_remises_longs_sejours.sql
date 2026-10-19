-- Réductions longs séjours (19/10), modèle Airbnb / Booking.
-- Remplace les anciens champs « Prix / semaine » et « Prix / mois » (jamais
-- utilisés dans le calcul) par deux pourcentages réglés par l'hôte :
--   weekly_discount_percent  : dès 7 nuits
--   monthly_discount_percent : dès 28 nuits
-- Le plus fort des pourcentages applicables s'applique au total du séjour
-- (prix du calendrier et promos compris), par chambre, puis × nombre de
-- chambres. Même règle que longStayTotal() dans index.html.
-- Les annonces existantes démarrent à 0 % (aucune réduction) : les anciennes
-- valeurs price_week / price_month étaient des valeurs automatiques
-- (nuit × 6,5 et × 25) que les hôtes n'avaient pas choisies. Ces deux colonnes
-- sont conservées mais ne sont plus utilisées.
ALTER TABLE public.annonces
  ADD COLUMN IF NOT EXISTS weekly_discount_percent  integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS monthly_discount_percent integer NOT NULL DEFAULT 0;

ALTER TABLE public.annonces DROP CONSTRAINT IF EXISTS annonces_long_stay_discounts_chk;
ALTER TABLE public.annonces ADD CONSTRAINT annonces_long_stay_discounts_chk
  CHECK (weekly_discount_percent BETWEEN 0 AND 90 AND monthly_discount_percent BETWEEN 0 AND 90);

CREATE OR REPLACE FUNCTION public.fn_logement_pricing(p_annonce uuid, p_check_in date, p_check_out date, p_rooms int)
RETURNS TABLE(host_subtotal numeric, guest_total numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_base numeric; v_disc numeric; v_wk int; v_mo int;
  d date; v_night numeric; v_row record; v_n int; v_pct int := 0;
  v_host numeric := 0; v_rooms int := greatest(coalesce(p_rooms,1),1);
BEGIN
  SELECT price_night, coalesce(discount_percent,0), coalesce(weekly_discount_percent,0), coalesce(monthly_discount_percent,0)
    INTO v_base, v_disc, v_wk, v_mo FROM public.annonces WHERE id = p_annonce;
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
    v_host := v_host + v_night;
    d := d + 1;
  END LOOP;

  -- Réduction longs séjours : le plus fort pourcentage applicable (0 à 90)
  v_n := p_check_out - p_check_in;
  IF v_n >= 7  THEN v_pct := greatest(v_pct, v_wk); END IF;
  IF v_n >= 28 THEN v_pct := greatest(v_pct, v_mo); END IF;
  v_pct := least(greatest(v_pct, 0), 90);
  IF v_pct > 0 THEN v_host := round(v_host * (100 - v_pct) / 100); END IF;

  v_host := v_host * v_rooms;
  RETURN QUERY SELECT v_host, v_host + round(v_host * public.fn_tarif('frais_voyageur'));
END $$;
REVOKE ALL ON FUNCTION public.fn_logement_pricing(uuid, date, date, int) FROM PUBLIC, anon, authenticated;
