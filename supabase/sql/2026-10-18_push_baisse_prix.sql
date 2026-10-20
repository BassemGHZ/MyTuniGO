-- =====================================================================
-- MyTunigo — 18/10/2026 : alerte de baisse de prix immédiate (push + e-mail)
--
-- Avant : l'e-mail « baisse de prix » partait au mieux 3 h plus tard (tâche
-- mytunigo-price-alerts) et aucune notification push n'était envoyée.
-- Après : dès que le prix par nuit d'un logement publié baisse,
--   - notification push à chaque voyageur qui suit ce logement en favori
--     (price_alerts) et dont le prix suivi est plus élevé ;
--   - réveil immédiat de notify-price-drop, qui envoie l'e-mail et met à
--     jour le prix suivi (idempotent : pas de double e-mail ; la tâche toutes
--     les 3 h reste en filet de sécurité).
-- Une erreur ici ne bloque jamais la modification de l'annonce.
--
-- À exécuter une fois dans le SQL Editor. Idempotent.
-- =====================================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.fn_push_price_drop()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record;
BEGIN
  BEGIN
    IF NEW.status <> 'publiée' OR NEW.price_night IS NULL OR OLD.price_night IS NULL
       OR NEW.price_night >= OLD.price_night THEN
      RETURN NULL;
    END IF;
    FOR r IN
      SELECT DISTINCT ON (pa.user_id) pa.user_id, pa.tracked_price
      FROM public.price_alerts pa
      WHERE pa.annonce_id = NEW.id AND pa.tracked_price > NEW.price_night
        AND pa.user_id IS DISTINCT FROM NEW.user_id
      ORDER BY pa.user_id, pa.tracked_price DESC
    LOOP
      PERFORM public.fn_push_enqueue(r.user_id, '💰 Baisse de prix sur un favori',
        coalesce(NEW.name, 'Un logement') || ' : ' || trim(to_char(NEW.price_night, 'FM999999990.##')) || ' € / nuit au lieu de '
          || trim(to_char(r.tracked_price, 'FM999999990.##')) || ' €',
        '/?logement=' || NEW.id, 'price-' || NEW.id);
    END LOOP;
    -- E-mail tout de suite (notify-price-drop relit tout en base)
    PERFORM net.http_post(
      url     := 'https://fxbetakueqkzipsqvtck.supabase.co/functions/v1/notify-price-drop',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ4YmV0YWt1ZXFremlwc3F2dGNrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI1NDk1MjAsImV4cCI6MjA5ODEyNTUyMH0.e3RRfDjfmH4EJjRiX2UDJhyNKzhWhiHYay8wJFoQYNk'
      ),
      body    := jsonb_build_object('action', 'check'));
  EXCEPTION WHEN others THEN
    RAISE WARNING 'push price drop: %', SQLERRM;
  END;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.fn_push_price_drop() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_push_price_drop ON public.annonces;
CREATE TRIGGER trg_push_price_drop AFTER UPDATE OF price_night ON public.annonces
  FOR EACH ROW EXECUTE FUNCTION public.fn_push_price_drop();

COMMIT;

-- Facultatif : envoyer tout de suite les e-mails des baisses déjà en attente
-- (ex. MaisonYahoo 60 € -> 40 €) au lieu d'attendre la prochaine tâche :
--   select public.fn_check_price_alerts();
