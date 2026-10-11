-- =====================================================================
-- MyTunigo — Scénario de test des avis (hôte <-> voyageur)
-- 1/2 : CRÉATION de deux séjours de test terminés hier
--
-- Hôte     : ghezal.bassem@gmail.com
-- Voyageur : ghezalbassem@yahoo.com
--
--   TEST-AVIS-01 (StudioGmail) : scénario A — l'hôte note en premier
--   TEST-AVIS-02 (PePe)        : scénario B — le voyageur note en premier
--
-- Séjour du J-4 au J-1 (départ hier), statut « terminée » : les deux côtés
-- sont dans la fenêtre d'avis de 14 jours.
-- Dans l'heure qui suit, la tâche horaire enverra pour chaque séjour :
--   - au voyageur : « Comment s'est passé votre séjour ? » ;
--   - à l'hôte    : « Comment s'est passé le séjour de bassem ? ».
-- Rejouable : ne crée rien si les références existent déjà.
-- Nettoyage ensuite : scenario_avis_2_nettoyer.sql
-- =====================================================================
INSERT INTO public.reservations
  (logement_id, guest_id, check_in, check_out, nights, rooms, guests_count, total,
   status, reference, notes, payment_method, paid_at, accepted_at)
SELECT a.id, g.id,
       (now() AT TIME ZONE 'Africa/Tunis')::date - 4,
       (now() AT TIME ZONE 'Africa/Tunis')::date - 1,
       3, 1, 2, v.total, 'terminée', v.ref, 'Réservation de test — scénario avis',
       'en ligne', now() - interval '5 days', now() - interval '6 days'
  FROM (VALUES ('TEST-AVIS-01', '76e2239c-5ecc-4a87-9dce-b24fd10474f9'::text, 150),
               ('TEST-AVIS-02', 'c58de4cc-9188-42c7-a313-73a30dfec04e'::text, 180)) AS v(ref, ann_id, total)
  JOIN public.annonces a ON a.id::text = v.ann_id
  JOIN public.profiles g ON g.email = 'ghezalbassem@yahoo.com'
 WHERE NOT EXISTS (SELECT 1 FROM public.reservations r WHERE r.reference = v.ref);

-- Vérification : 2 lignes attendues
SELECT r.reference, a.name AS logement, r.check_in, r.check_out, r.status
  FROM public.reservations r JOIN public.annonces a ON a.id = r.logement_id
 WHERE r.reference LIKE 'TEST-AVIS-%' ORDER BY r.reference;
