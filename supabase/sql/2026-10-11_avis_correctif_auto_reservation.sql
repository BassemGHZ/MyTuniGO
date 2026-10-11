-- =====================================================================
-- MyTunigo — Avis : correctif « réservation chez soi-même »
-- Projet : fxbetakueqkzipsqvtck — 11/10/2026
--
-- Problème trouvé pendant le test du scénario d'avis (étape A4) :
-- un voyageur qui est AUSSI hôte et qui a déjà réservé l'un de ses propres
-- logements passait pour « un hôte ayant reçu une demande de ce voyageur ».
-- Il pouvait donc lire tous les avis des hôtes écrits sur lui, même ceux
-- encore masqués (le principe « en aveugle » ne tenait plus).
--
-- 1. Lecture des avis des hôtes : la règle « hôtes ayant reçu une demande »
--    ne s'applique plus au voyageur lui-même (il garde sa propre règle :
--    après son avis sur le logement, ou à la fin de la fenêtre de 14 jours).
-- 2. Un hôte ne peut plus évaluer un séjour fait dans son propre logement.
-- 3. Un voyageur ne peut plus noter son propre logement ni sa propre
--    excursion (les avis déjà publiés ne sont pas supprimés).
--
-- Reprend à l'identique les règles de 2026-10-11_fenetre_avis_14_jours.sql,
-- en ajoutant seulement ces exclusions. Rejouable.
-- =====================================================================

BEGIN;

-- 1. Lecture des avis des hôtes -------------------------------------------
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
    -- les AUTRES hôtes qui ont reçu une demande de ce voyageur
    OR (guest_id <> auth.uid() AND EXISTS (
          SELECT 1 FROM public.reservations r JOIN public.annonces a ON a.id = r.logement_id
           WHERE r.guest_id = guest_reviews.guest_id AND a.user_id = auth.uid()))
  );

-- 2. Pas d'avis d'un hôte sur un séjour dans son propre logement ----------
DROP POLICY IF EXISTS guest_reviews_insert_host ON public.guest_reviews;
CREATE POLICY guest_reviews_insert_host ON public.guest_reviews FOR INSERT TO authenticated
  WITH CHECK (author_id = auth.uid() AND guest_id <> auth.uid() AND EXISTS (
    SELECT 1 FROM public.reservations r JOIN public.annonces a ON a.id = r.logement_id
     WHERE r.id = guest_reviews.reservation_id
       AND r.guest_id = guest_reviews.guest_id
       AND r.logement_id = guest_reviews.logement_id
       AND a.user_id = auth.uid()
       AND (r.status = 'terminée'
            OR (r.status = 'confirmée' AND r.check_out <= (now() AT TIME ZONE 'Africa/Tunis')::date))
       AND r.check_out >= (now() AT TIME ZONE 'Africa/Tunis')::date - 14));

-- 3. Pas d'avis d'un voyageur sur son propre logement / sa propre excursion
DROP POLICY IF EXISTS avis_insert_eligible ON public.avis;
CREATE POLICY avis_insert_eligible ON public.avis
  FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() = author_id
    AND (
      (logement_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.annonces a WHERE a.id = avis.logement_id AND a.user_id = auth.uid())
       AND EXISTS (
         SELECT 1 FROM public.reservations r
          WHERE r.guest_id = auth.uid()
            AND r.logement_id = avis.logement_id
            AND (r.status = 'terminée'
                 OR (r.status = 'confirmée' AND r.check_out <= (now() AT TIME ZONE 'Africa/Tunis')::date))
            AND r.check_out >= (now() AT TIME ZONE 'Africa/Tunis')::date - 14))
      OR
      (excursion_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.excursions e WHERE e.id = avis.excursion_id AND e.owner_id = auth.uid())
       AND EXISTS (
         SELECT 1 FROM public.excursion_bookings b
          WHERE b.guest_id = auth.uid()
            AND b.excursion_id = avis.excursion_id
            AND (b.status = 'terminée'
                 OR (b.status = 'confirmée' AND b.date < (now() AT TIME ZONE 'Africa/Tunis')::date))
            AND b.date >= (now() AT TIME ZONE 'Africa/Tunis')::date - 14))
    )
  );

COMMIT;
