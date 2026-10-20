-- « Pas de réduction longs séjours sur ces dates » (19/10) : l'hôte désigne
-- des dates (haute saison…) où ses réductions semaine / mois ne s'appliquent
-- pas. Si au moins une NUIT du séjour tombe sur une de ces dates, aucune
-- réduction longs séjours n'est appliquée à ce séjour (même règle que
-- computeNightlyTotal() dans index.html). Son pourcentage reste réglé toute
-- l'année dans « Modifier le prix ».

CREATE TABLE IF NOT EXISTS public.date_no_long_stay (
  annonce_id uuid NOT NULL REFERENCES public.annonces(id) ON DELETE CASCADE,
  date       date NOT NULL,
  host_id    uuid,
  PRIMARY KEY (annonce_id, date)
);
ALTER TABLE public.date_no_long_stay ENABLE ROW LEVEL SECURITY;

-- Lecture publique (le voyageur en a besoin pour voir le bon prix), écriture
-- réservée à l'hôte propriétaire de l'annonce.
DROP POLICY IF EXISTS no_long_stay_read ON public.date_no_long_stay;
CREATE POLICY no_long_stay_read ON public.date_no_long_stay FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS no_long_stay_insert ON public.date_no_long_stay;
CREATE POLICY no_long_stay_insert ON public.date_no_long_stay FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.annonces a WHERE a.id = annonce_id AND a.user_id = auth.uid()));
DROP POLICY IF EXISTS no_long_stay_delete ON public.date_no_long_stay;
CREATE POLICY no_long_stay_delete ON public.date_no_long_stay FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.annonces a WHERE a.id = annonce_id AND a.user_id = auth.uid()));
REVOKE ALL ON public.date_no_long_stay FROM anon, authenticated;
GRANT SELECT ON public.date_no_long_stay TO anon, authenticated;
GRANT INSERT, DELETE ON public.date_no_long_stay TO authenticated;
GRANT SELECT ON public.date_no_long_stay TO service_role;

-- Calcul du total en base : la réduction longs séjours est ignorée si une nuit
-- du séjour est marquée (reprend fn_logement_pricing du 2026-10-19_remises_longs_sejours).
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

  -- Réduction longs séjours : plus fort pourcentage applicable (0 à 90),
  -- sauf si une nuit du séjour est marquée « sans réduction »
  v_n := p_check_out - p_check_in;
  IF NOT EXISTS (SELECT 1 FROM public.date_no_long_stay n
                 WHERE n.annonce_id = p_annonce AND n.date >= p_check_in AND n.date < p_check_out) THEN
    IF v_n >= 7  THEN v_pct := greatest(v_pct, v_wk); END IF;
    IF v_n >= 28 THEN v_pct := greatest(v_pct, v_mo); END IF;
    v_pct := least(greatest(v_pct, 0), 90);
    IF v_pct > 0 THEN v_host := round(v_host * (100 - v_pct) / 100); END IF;
  END IF;

  v_host := v_host * v_rooms;
  RETURN QUERY SELECT v_host, v_host + round(v_host * public.fn_tarif('frais_voyageur'));
END $$;
REVOKE ALL ON FUNCTION public.fn_logement_pricing(uuid, date, date, int) FROM PUBLIC, anon, authenticated;
