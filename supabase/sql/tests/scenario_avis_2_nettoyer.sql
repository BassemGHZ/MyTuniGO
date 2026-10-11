-- =====================================================================
-- MyTunigo — Scénario de test des avis
-- 2/2 : NETTOYAGE (à lancer une fois les tests terminés)
-- Supprime les avis du scénario puis les deux séjours de test.
-- =====================================================================
BEGIN;
-- avis des hôtes sur le voyageur (supprimés aussi par cascade, ici par clarté)
DELETE FROM public.guest_reviews
 WHERE reservation_id IN (SELECT id FROM public.reservations WHERE reference LIKE 'TEST-AVIS-%');
-- avis du voyageur sur StudioGmail et PePe
DELETE FROM public.avis v
 USING public.profiles g
 WHERE g.email = 'ghezalbassem@yahoo.com' AND v.author_id = g.id
   AND v.logement_id IN ('76e2239c-5ecc-4a87-9dce-b24fd10474f9', 'c58de4cc-9188-42c7-a313-73a30dfec04e');
DELETE FROM public.reservations WHERE reference LIKE 'TEST-AVIS-%';
COMMIT;
SELECT count(*) AS reste_test FROM public.reservations WHERE reference LIKE 'TEST-AVIS-%';
