-- Vues = apparitions de l'annonce dans les résultats de recherche (19/10).
-- Clics = ouvertures de la fiche : c'est ce que comptait jusqu'ici « Vues »
-- (table annonce_views, historique conservé, aucune modification).
-- Un nouveau compteur « apparitions » est ajouté ; il démarre à 0.

-- 1. Apparitions : aucune donnée personnelle (ni visiteur, ni appareil)
CREATE TABLE IF NOT EXISTS public.annonce_impressions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  annonce_id uuid NOT NULL REFERENCES public.annonces(id) ON DELETE CASCADE,
  seen_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS annonce_impressions_annonce_seen_idx ON public.annonce_impressions (annonce_id, seen_at);
ALTER TABLE public.annonce_impressions ENABLE ROW LEVEL SECURITY;

-- Lecture : l'hôte de l'annonce (comme annonce_views) ; aucune écriture directe
DROP POLICY IF EXISTS impressions_select_owner ON public.annonce_impressions;
CREATE POLICY impressions_select_owner ON public.annonce_impressions FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.annonces a WHERE a.id = annonce_impressions.annonce_id AND a.user_id = auth.uid()));
REVOKE ALL ON public.annonce_impressions FROM anon, authenticated;
GRANT SELECT ON public.annonce_impressions TO authenticated;
GRANT SELECT ON public.annonce_impressions TO service_role;

-- 2. Enregistrement par lot (50 annonces max par appel) : seules les annonces
--    publiées comptent, et jamais celles de l'utilisateur connecté.
CREATE OR REPLACE FUNCTION public.log_annonce_impressions(p_ids uuid[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_ids IS NULL OR cardinality(p_ids) = 0 THEN RETURN; END IF;
  INSERT INTO public.annonce_impressions(annonce_id)
  SELECT a.id FROM public.annonces a
  WHERE a.id = ANY (p_ids[1:50]) AND a.status = 'publiée'
    AND (auth.uid() IS NULL OR a.user_id <> auth.uid());
END $$;
REVOKE ALL ON FUNCTION public.log_annonce_impressions(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_annonce_impressions(uuid[]) TO anon, authenticated;

-- 3. Compteurs pour « Mes annonces » (SECURITY INVOKER : la RLS limite à
--    l'hôte ; évite aussi la limite de 1000 lignes des requêtes du site)
CREATE OR REPLACE FUNCTION public.fn_my_annonce_counts(p_ids uuid[])
RETURNS TABLE(annonce_id uuid, impressions bigint, clicks bigint)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public, pg_temp AS $$
  SELECT i.id,
         (SELECT count(*) FROM public.annonce_impressions x WHERE x.annonce_id = i.id),
         (SELECT count(*) FROM public.annonce_views v WHERE v.annonce_id = i.id)
  FROM unnest(p_ids) AS i(id);
$$;
REVOKE ALL ON FUNCTION public.fn_my_annonce_counts(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_my_annonce_counts(uuid[]) TO authenticated;

-- 4. Détail par mois (page « Statistiques »)
CREATE OR REPLACE FUNCTION public.fn_annonce_monthly(p_annonce uuid, p_year int)
RETURNS TABLE(month int, impressions bigint, clicks bigint)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public, pg_temp AS $$
  SELECT m,
         (SELECT count(*) FROM public.annonce_impressions x
           WHERE x.annonce_id = p_annonce AND extract(year from x.seen_at)::int = p_year AND extract(month from x.seen_at)::int = m),
         (SELECT count(*) FROM public.annonce_views v
           WHERE v.annonce_id = p_annonce AND extract(year from v.viewed_at)::int = p_year AND extract(month from v.viewed_at)::int = m)
  FROM generate_series(1,12) AS m;
$$;
REVOKE ALL ON FUNCTION public.fn_annonce_monthly(uuid, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_annonce_monthly(uuid, int) TO authenticated;
