-- =====================================================================
-- MyTunigo — Avis des hôtes sur les voyageurs
-- Projet : fxbetakueqkzipsqvtck — 11/10/2026
--
-- Après un séjour, l'hôte peut noter le voyageur (1 à 5) et laisser un
-- commentaire. Règles :
--   ÉCRITURE : uniquement l'hôte du logement réservé, pour une réservation
--              terminée (ou confirmée dont le départ est passé), une seule
--              fois par réservation, sans modification ni suppression.
--   LECTURE  : - le voyageur concerné (« Avis des hôtes » dans son profil),
--                une fois qu'il a lui-même laissé son avis sur le logement
--                ou 14 jours après l'avis de l'hôte (pas de représailles) ;
--              - l'hôte auteur de l'avis ;
--              - tout hôte qui a reçu une demande de ce voyageur (pour
--                décider d'accepter ou non) ;
--              - l'administrateur.
--   Ce n'est pas public : un visiteur ou un autre voyageur ne voit rien.
--
-- + colonne host_review_email_sent_at sur reservations : rappel envoyé à
--   l'hôte après le séjour (notify-review, tâche horaire existante). Les
--   réservations passées existantes sont marquées comme déjà traitées.
--
-- À exécuter AVANT de fusionner la Pull Request et de redéployer notify-review.
-- =====================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.guest_reviews (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id uuid NOT NULL UNIQUE REFERENCES public.reservations(id) ON DELETE CASCADE,
  logement_id    uuid NOT NULL REFERENCES public.annonces(id) ON DELETE CASCADE,
  guest_id       uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  author_id      uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  rating         int  NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment        text CHECK (comment IS NULL OR length(comment) <= 1000),
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS guest_reviews_guest_idx ON public.guest_reviews (guest_id);

ALTER TABLE public.guest_reviews ENABLE ROW LEVEL SECURITY;

-- Écriture : l'hôte de la réservation, après le séjour
DROP POLICY IF EXISTS guest_reviews_insert_host ON public.guest_reviews;
CREATE POLICY guest_reviews_insert_host ON public.guest_reviews
  FOR INSERT TO authenticated
  WITH CHECK (
    author_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.reservations r
        JOIN public.annonces a ON a.id = r.logement_id
       WHERE r.id = guest_reviews.reservation_id
         AND r.guest_id = guest_reviews.guest_id
         AND r.logement_id = guest_reviews.logement_id
         AND a.user_id = auth.uid()
         AND (r.status = 'terminée'
              OR (r.status = 'confirmée' AND r.check_out <= (now() AT TIME ZONE 'Africa/Tunis')::date))
    )
  );

-- Lecture
DROP POLICY IF EXISTS guest_reviews_select ON public.guest_reviews;
CREATE POLICY guest_reviews_select ON public.guest_reviews
  FOR SELECT TO authenticated
  USING (
    author_id = auth.uid()
    OR public.fn_is_admin()
    -- le voyageur concerné, une fois son propre avis laissé ou après 14 jours
    OR (guest_id = auth.uid() AND (
          created_at <= now() - interval '14 days'
          OR EXISTS (SELECT 1 FROM public.avis v
                      WHERE v.author_id = guest_reviews.guest_id
                        AND v.logement_id = guest_reviews.logement_id)))
    -- un hôte qui a reçu une demande de ce voyageur
    OR EXISTS (SELECT 1 FROM public.reservations r
                 JOIN public.annonces a ON a.id = r.logement_id
                WHERE r.guest_id = guest_reviews.guest_id
                  AND a.user_id = auth.uid())
  );
-- (aucune règle UPDATE / DELETE : un avis publié est définitif)

REVOKE ALL ON public.guest_reviews FROM anon;
GRANT SELECT, INSERT ON public.guest_reviews TO authenticated;
GRANT SELECT ON public.guest_reviews TO service_role;

-- Rappel e-mail à l'hôte après le séjour
ALTER TABLE public.reservations ADD COLUMN IF NOT EXISTS host_review_email_sent_at timestamptz;
UPDATE public.reservations
   SET host_review_email_sent_at = now()
 WHERE host_review_email_sent_at IS NULL
   AND check_out < (now() AT TIME ZONE 'Africa/Tunis')::date;

COMMIT;
