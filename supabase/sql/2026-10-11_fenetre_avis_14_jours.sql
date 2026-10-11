-- =====================================================================
-- MyTunigo — Fenêtre d'avis de 14 jours (modèle Airbnb)
-- Projet : fxbetakueqkzipsqvtck — 11/10/2026
--
-- Objectif : qu'aucun des deux côtés ne puisse écrire (ou réécrire) son avis
-- en connaissant déjà celui de l'autre.
--
-- 1. Voyageur -> logement (table avis) :
--    - avis possible seulement APRÈS le séjour (corrige une faille : une
--      réservation « confirmée » suffisait, même avant l'arrivée) et au plus
--      tard 14 jours après le départ ;
--    - modification / suppression possibles pendant ces 14 jours, TANT QUE
--      l'hôte n'a pas évalué le voyageur pour ce séjour. Ensuite l'avis est
--      figé (le voyageur pourrait sinon changer sa note après avoir lu celle
--      de l'hôte).
-- 2. Voyageur -> excursion (table avis) : même fenêtre de 14 jours après la
--    date de l'excursion, pour publier, modifier ou supprimer.
-- 3. Hôte -> voyageur (table guest_reviews) :
--    - avis possible au plus tard 14 jours après le départ ;
--    - le voyageur le voit dès qu'il a noté le logement, ou à la fin de la
--      fenêtre (15e jour après le départ) — au lieu de « 14 jours après
--      l'avis de l'hôte ».
--
-- L'admin (fn_is_admin) et les fonctions serveur gardent la main (modération).
-- Dates comptées à l'heure de Tunis. À exécuter AVANT de fusionner la PR.
-- =====================================================================

BEGIN;

-- 1. Publier un avis : après le séjour / l'excursion, dans les 14 jours ----
DROP POLICY IF EXISTS avis_insert_eligible ON public.avis;
CREATE POLICY avis_insert_eligible ON public.avis
  FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() = author_id
    AND (
      (logement_id IS NOT NULL AND EXISTS (
         SELECT 1 FROM public.reservations r
          WHERE r.guest_id = auth.uid()
            AND r.logement_id = avis.logement_id
            AND (r.status = 'terminée'
                 OR (r.status = 'confirmée' AND r.check_out <= (now() AT TIME ZONE 'Africa/Tunis')::date))
            AND r.check_out >= (now() AT TIME ZONE 'Africa/Tunis')::date - 14))
      OR
      (excursion_id IS NOT NULL AND EXISTS (
         SELECT 1 FROM public.excursion_bookings b
          WHERE b.guest_id = auth.uid()
            AND b.excursion_id = avis.excursion_id
            AND (b.status = 'terminée'
                 OR (b.status = 'confirmée' AND b.date < (now() AT TIME ZONE 'Africa/Tunis')::date))
            AND b.date >= (now() AT TIME ZONE 'Africa/Tunis')::date - 14))
    )
  );


-- 2. Modifier / supprimer un avis : fenêtre ouverte et pas encore figé -----
-- Renvoie NULL si l'utilisateur connecté peut encore modifier SON avis sur
-- ce logement / cette excursion, sinon la raison. Ne porte que sur ses
-- propres avis (auth.uid()) : rien n'est divulgué sur les autres.
-- SECURITY DEFINER : doit voir l'avis de l'hôte même quand le voyageur n'a
-- pas encore le droit de le lire.
DROP FUNCTION IF EXISTS public.fn_avis_edit_block(uuid, uuid, uuid);
CREATE OR REPLACE FUNCTION public.fn_avis_edit_block(p_logement uuid, p_excursion uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Africa/Tunis')::date;
  p_author uuid := auth.uid();
BEGIN
  IF p_author IS NULL THEN
    RETURN 'AVIS_WINDOW_CLOSED';
  END IF;
  IF p_logement IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM reservations r
                    WHERE r.guest_id = p_author AND r.logement_id = p_logement
                      AND (r.status = 'terminée' OR (r.status = 'confirmée' AND r.check_out <= v_today))
                      AND r.check_out >= v_today - 14) THEN
      RETURN 'AVIS_WINDOW_CLOSED';
    END IF;
    -- L'hôte a déjà évalué le voyageur pour un séjour encore dans la fenêtre
    IF EXISTS (SELECT 1 FROM guest_reviews g JOIN reservations r ON r.id = g.reservation_id
                WHERE g.guest_id = p_author AND g.logement_id = p_logement
                  AND r.check_out >= v_today - 14) THEN
      RETURN 'AVIS_LOCKED';
    END IF;
    RETURN NULL;
  END IF;
  IF p_excursion IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM excursion_bookings b
                    WHERE b.guest_id = p_author AND b.excursion_id = p_excursion
                      AND (b.status = 'terminée' OR (b.status = 'confirmée' AND b.date < v_today))
                      AND b.date >= v_today - 14) THEN
      RETURN 'AVIS_WINDOW_CLOSED';
    END IF;
    RETURN NULL;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.fn_avis_edit_block(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_avis_edit_block(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_avis_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_block text;
BEGIN
  IF current_user IN ('postgres','service_role','supabase_admin') OR public.fn_is_admin() THEN
    RETURN COALESCE(NEW, OLD);
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.author_id IS DISTINCT FROM OLD.author_id
     OR NEW.logement_id IS DISTINCT FROM OLD.logement_id
     OR NEW.excursion_id IS DISTINCT FROM OLD.excursion_id) THEN
    RAISE EXCEPTION 'AVIS_TARGET_IMMUTABLE';
  END IF;
  -- (les règles RLS imposent déjà auteur = utilisateur connecté)
  IF OLD.author_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'AVIS_NOT_AUTHOR';
  END IF;
  v_block := public.fn_avis_edit_block(OLD.logement_id, OLD.excursion_id);
  IF v_block IS NOT NULL THEN
    RAISE EXCEPTION '%', v_block;
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;

DROP TRIGGER IF EXISTS trg_avis_guard ON public.avis;
CREATE TRIGGER trg_avis_guard BEFORE UPDATE OR DELETE ON public.avis
  FOR EACH ROW EXECUTE FUNCTION public.fn_avis_guard();


-- 3. Avis des hôtes : fenêtre de 14 jours et visibilité en fin de fenêtre --
DROP POLICY IF EXISTS guest_reviews_insert_host ON public.guest_reviews;
CREATE POLICY guest_reviews_insert_host ON public.guest_reviews FOR INSERT TO authenticated
  WITH CHECK (author_id = auth.uid() AND EXISTS (
    SELECT 1 FROM public.reservations r JOIN public.annonces a ON a.id = r.logement_id
     WHERE r.id = guest_reviews.reservation_id
       AND r.guest_id = guest_reviews.guest_id
       AND r.logement_id = guest_reviews.logement_id
       AND a.user_id = auth.uid()
       AND (r.status = 'terminée'
            OR (r.status = 'confirmée' AND r.check_out <= (now() AT TIME ZONE 'Africa/Tunis')::date))
       AND r.check_out >= (now() AT TIME ZONE 'Africa/Tunis')::date - 14));

DROP POLICY IF EXISTS guest_reviews_select ON public.guest_reviews;
CREATE POLICY guest_reviews_select ON public.guest_reviews FOR SELECT TO authenticated
  USING (
    author_id = auth.uid()
    OR public.fn_is_admin()
    -- le voyageur : après avoir noté le logement, ou à la fin de la fenêtre
    OR (guest_id = auth.uid() AND (
          EXISTS (SELECT 1 FROM public.avis v
                   WHERE v.author_id = guest_reviews.guest_id AND v.logement_id = guest_reviews.logement_id)
          OR EXISTS (SELECT 1 FROM public.reservations r
                      WHERE r.id = guest_reviews.reservation_id
                        AND r.check_out < (now() AT TIME ZONE 'Africa/Tunis')::date - 14)))
    -- les hôtes qui ont reçu une demande de ce voyageur
    OR EXISTS (SELECT 1 FROM public.reservations r JOIN public.annonces a ON a.id = r.logement_id
                WHERE r.guest_id = guest_reviews.guest_id AND a.user_id = auth.uid())
  );

COMMIT;
