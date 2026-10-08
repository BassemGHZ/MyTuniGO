-- =====================================================================
-- MyTunigo — Droits du rôle serveur (service_role) pour les Edge Functions
-- Projet : fxbetakueqkzipsqvtck — 08/10/2026
--
-- Dans ce projet, service_role n'a que les droits accordés explicitement
-- (aujourd'hui : SELECT sur annonces, conversations, excursions,
-- excursion_bookings, messages, profiles ; SELECT + UPDATE sur reservations).
-- Les Edge Functions réécrites ont besoin en plus de :
--
--   notify-review            : lire avis
--   notify-price-drop        : lire et mettre à jour price_alerts
--   notify-excursion-booking : mettre à jour excursion_bookings (expire_pending)
--   notify-deletion-request  : lire deletion_requests
--
-- Seuls ces droits sont ajoutés, et uniquement au rôle serveur : les
-- visiteurs et utilisateurs connectés (anon / authenticated) ne gagnent rien.
-- =====================================================================

BEGIN;

GRANT SELECT          ON public.avis               TO service_role;
GRANT SELECT, UPDATE  ON public.price_alerts       TO service_role;
GRANT UPDATE          ON public.excursion_bookings TO service_role;
GRANT SELECT          ON public.deletion_requests  TO service_role;

COMMIT;

-- Vérification : les 3 tâches planifiées, puis leurs réponses
--   select public.fn_send_review_requests();
--   select public.fn_check_price_alerts();
--   select public.fn_auto_reject_expired_excursion_bookings();
--   select id, status_code, left(content::text, 200) from net._http_response order by id desc limit 3;
-- Attendu : 3 réponses 200 avec {"ok":true,...}.
