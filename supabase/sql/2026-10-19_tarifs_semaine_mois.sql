-- Tarifs semaine / mois (19/10) : jusqu'ici price_week et price_month étaient
-- enregistrés mais jamais utilisés dans le calcul.
-- Règle : dès 7 nuits, prix moyen par nuit = price_week / 7 ; dès 30 nuits,
-- price_month / 30 (le plus bas des deux). Le voyageur paie le MOINS CHER entre
-- le total au tarif nuit / calendrier (inchangé) et le total au tarif
-- semaine / mois. Calculé par chambre, puis multiplié par le nombre de chambres.
-- Même règle que longStayTotal() dans index.html. Seule fn_logement_pricing
-- change : les triggers qui l'appellent (total à l'insertion, reversement) en
-- profitent automatiquement.
CREATE OR REPLACE FUNCTION public.fn_logement_pricing(p_annonce uuid, p_check_in date, p_check_out date, p_rooms int)
RETURNS TABLE(host_subtotal numeric, guest_total numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_base numeric; v_disc numeric; v_week numeric; v_month numeric;
  d date; v_night numeric; v_row record; v_n int; v_long numeric; v_w numeric;
  v_host numeric := 0; v_rooms int := greatest(coalesce(p_rooms,1),1);
BEGIN
  SELECT price_night, coalesce(discount_percent,0), coalesce(price_week,0), coalesce(price_month,0)
    INTO v_base, v_disc, v_week, v_month FROM public.annonces WHERE id = p_annonce;
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

  -- Tarifs semaine / mois : appliqués seulement s'ils sont moins chers
  v_n := p_check_out - p_check_in;
  v_long := NULL;
  IF v_n >= 30 AND v_month > 0 THEN v_long := round(v_month * v_n / 30); END IF;
  IF v_n >= 7 AND v_week > 0 THEN
    v_w := round(v_week * v_n / 7);
    v_long := CASE WHEN v_long IS NULL THEN v_w ELSE least(v_long, v_w) END;
  END IF;
  IF v_long IS NOT NULL AND v_long < v_host THEN v_host := v_long; END IF;

  v_host := v_host * v_rooms;
  RETURN QUERY SELECT v_host, v_host + round(v_host * public.fn_tarif('frais_voyageur'));
END $$;
REVOKE ALL ON FUNCTION public.fn_logement_pricing(uuid, date, date, int) FROM PUBLIC, anon, authenticated;
