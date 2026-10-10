-- =====================================================================
-- MyTunigo — Demandes d'avis après une excursion
-- Projet : fxbetakueqkzipsqvtck — 11/10/2026
--
-- Comme pour les logements : le lendemain d'une excursion, le voyageur
-- reçoit un e-mail « Comment s'est passée votre excursion ? », puis une
-- relance unique 24 h plus tard s'il n'a toujours pas laissé d'avis.
-- L'envoi est fait par notify-review (action review_requests), déjà
-- appelée toutes les heures par la tâche planifiée send-review-requests :
-- aucune nouvelle tâche planifiée n'est nécessaire.
--
-- 1. Deux colonnes sur excursion_bookings pour mémoriser les envois
--    (empêchent tout double envoi).
-- 2. Les réservations passées existantes sont marquées comme déjà
--    traitées : seules les excursions à venir déclencheront un e-mail
--    (pas d'envoi en masse sur les anciennes réservations de test).
--
-- À exécuter AVANT de redéployer notify-review.
-- =====================================================================

BEGIN;

ALTER TABLE public.excursion_bookings ADD COLUMN IF NOT EXISTS review_email_sent_at timestamptz;
ALTER TABLE public.excursion_bookings ADD COLUMN IF NOT EXISTS review_reminder_sent_at timestamptz;

UPDATE public.excursion_bookings
   SET review_email_sent_at    = coalesce(review_email_sent_at, now()),
       review_reminder_sent_at = coalesce(review_reminder_sent_at, now())
 WHERE date < (now() AT TIME ZONE 'Africa/Tunis')::date;

COMMIT;

-- Vérification (facultative) : aucune réservation passée ne doit rester à traiter
--   select count(*) from public.excursion_bookings
--    where date < current_date and review_email_sent_at is null;
