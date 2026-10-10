-- =====================================================================
-- MyTunigo — Avis sur les excursions
-- Projet : fxbetakueqkzipsqvtck — 10/10/2026
--
-- La table avis accepte déjà une excursion (colonne excursion_id), mais :
--   - la règle d'insertion ne vérifiait rien pour une excursion (n'importe
--     quel utilisateur connecté pouvait noter n'importe quelle excursion) ;
--   - rien n'empêchait plusieurs avis du même voyageur sur une excursion ;
--   - la note et le nombre d'avis des excursions n'étaient jamais calculés.
--
-- 1. Un seul avis par voyageur et par excursion.
-- 2. Insertion : avis d'excursion seulement si le voyageur y a participé
--    (réservation « terminée », ou « confirmée » dont la date est passée).
-- 3. Modification : l'auteur ne peut changer que la note et le commentaire
--    (pas la cible de l'avis ni l'auteur).
-- 4. Note moyenne et nombre d'avis tenus à jour sur excursions
--    (rating / review_count), recalculés à chaque avis ajouté, modifié ou
--    supprimé — utilisés par le site, la recherche « à moins de 50 km » et
--    les e-mails.
--
-- À exécuter AVANT de fusionner la Pull Request.
-- =====================================================================

BEGIN;

-- 1. Un avis par voyageur et par excursion ------------------------------
-- (contrainte complète, comme pour les logements : les avis de logement ont
--  excursion_id vide et ne se gênent donc pas entre eux)
ALTER TABLE public.avis DROP CONSTRAINT IF EXISTS avis_unique_author_excursion;
ALTER TABLE public.avis ADD CONSTRAINT avis_unique_author_excursion UNIQUE (author_id, excursion_id);


-- 2. Qui peut publier un avis ------------------------------------------
DROP POLICY IF EXISTS avis_insert_eligible ON public.avis;
CREATE POLICY avis_insert_eligible ON public.avis
  FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() = author_id
    AND (
      -- logement : séjour confirmé ou terminé (règle inchangée)
      (logement_id IS NOT NULL AND EXISTS (
         SELECT 1 FROM public.reservations r
          WHERE r.guest_id = auth.uid()
            AND r.logement_id = avis.logement_id
            AND r.status = ANY (ARRAY['confirmée','terminée'])))
      OR
      -- excursion : le voyageur y a participé
      (excursion_id IS NOT NULL AND EXISTS (
         SELECT 1 FROM public.excursion_bookings b
          WHERE b.guest_id = auth.uid()
            AND b.excursion_id = avis.excursion_id
            AND (b.status = 'terminée'
                 OR (b.status = 'confirmée' AND b.date < (now() AT TIME ZONE 'Africa/Tunis')::date))))
    )
  );


-- 3. Cible et auteur d'un avis non modifiables --------------------------
CREATE OR REPLACE FUNCTION public.fn_avis_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF current_user IN ('postgres','service_role','supabase_admin') THEN
    RETURN NEW;
  END IF;
  IF NEW.author_id IS DISTINCT FROM OLD.author_id
     OR NEW.logement_id IS DISTINCT FROM OLD.logement_id
     OR NEW.excursion_id IS DISTINCT FROM OLD.excursion_id THEN
    RAISE EXCEPTION 'AVIS_TARGET_IMMUTABLE';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_avis_guard ON public.avis;
CREATE TRIGGER trg_avis_guard BEFORE UPDATE ON public.avis
  FOR EACH ROW EXECUTE FUNCTION public.fn_avis_guard();


-- 4. Note moyenne et nombre d'avis des excursions -----------------------
CREATE OR REPLACE FUNCTION public.fn_refresh_excursion_rating(p_excursion_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  UPDATE public.excursions e
     SET rating       = coalesce(s.avg_rating, 0),
         review_count = coalesce(s.n, 0)
    FROM (SELECT round(avg(rating)::numeric, 1) AS avg_rating, count(*)::int AS n
            FROM public.avis WHERE excursion_id = p_excursion_id) s
   WHERE e.id = p_excursion_id
     AND (e.rating IS DISTINCT FROM coalesce(s.avg_rating, 0)
          OR e.review_count IS DISTINCT FROM coalesce(s.n, 0));
$$;
REVOKE ALL ON FUNCTION public.fn_refresh_excursion_rating(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_avis_excursion_rating()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP IN ('INSERT','UPDATE') AND NEW.excursion_id IS NOT NULL THEN
    PERFORM public.fn_refresh_excursion_rating(NEW.excursion_id);
  END IF;
  IF TG_OP IN ('UPDATE','DELETE') AND OLD.excursion_id IS NOT NULL
     AND (TG_OP = 'DELETE' OR OLD.excursion_id IS DISTINCT FROM NEW.excursion_id) THEN
    PERFORM public.fn_refresh_excursion_rating(OLD.excursion_id);
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.fn_avis_excursion_rating() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_avis_excursion_rating ON public.avis;
CREATE TRIGGER trg_avis_excursion_rating
  AFTER INSERT OR UPDATE OF rating, excursion_id OR DELETE ON public.avis
  FOR EACH ROW EXECUTE FUNCTION public.fn_avis_excursion_rating();

-- Remise à niveau des excursions existantes (aucun avis aujourd'hui : 0)
UPDATE public.excursions e
   SET rating = coalesce(s.avg_rating, 0), review_count = coalesce(s.n, 0)
  FROM (SELECT x.id,
               (SELECT round(avg(a.rating)::numeric, 1) FROM public.avis a WHERE a.excursion_id = x.id) AS avg_rating,
               (SELECT count(*)::int FROM public.avis a WHERE a.excursion_id = x.id) AS n
          FROM public.excursions x) s
 WHERE e.id = s.id
   AND (e.rating IS DISTINCT FROM coalesce(s.avg_rating, 0) OR e.review_count IS DISTINCT FROM coalesce(s.n, 0));

COMMIT;
