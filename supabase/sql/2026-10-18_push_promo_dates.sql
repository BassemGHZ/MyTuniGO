-- =====================================================================
-- MyTunigo — 18/10/2026 : notification push quand un favori passe en promo
--
-- Cas : l'hôte fixe un prix spécial sur des dates (calendrier « Prix par
-- nuit pour ces dates », table date_discounts) sans changer le prix de base.
-- Avant : aucune alerte. Après : notification push aux voyageurs qui suivent
-- ce logement en favori (price_alerts), si au moins une date à venir (dans
-- les 6 prochains mois) passe sous le prix de base.
--   Ex. « MaisonYahoo : dès 30 € / nuit du 01/11 au 30/11 (au lieu de 40 €) »
-- Anti-doublon : une seule notification par voyageur et par logement par
-- heure (plusieurs enregistrements de suite dans le calendrier = 1 alerte).
-- Une erreur ici ne bloque jamais l'enregistrement des prix.
--
-- À exécuter une fois dans le SQL Editor. Idempotent.
-- =====================================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.fn_push_date_promo()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  a record;
  u record;
  v_today date := (now() AT TIME ZONE 'Africa/Tunis')::date;
  v_fmt   text;
BEGIN
  BEGIN
    FOR a IN
      SELECT an.id, an.user_id AS owner, an.name, an.price_night AS base,
             min(x.eff) AS min_price, min(x.date) AS d1, max(x.date) AS d2
      FROM (
        SELECT n.annonce_id, n.date,
               coalesce(n.price_override, round(an2.price_night * (1 - coalesce(n.discount_percent, 0) / 100.0))) AS eff
        FROM new_rows n JOIN public.annonces an2 ON an2.id = n.annonce_id
        WHERE n.date >= v_today AND n.date <= v_today + 183
      ) x
      JOIN public.annonces an ON an.id = x.annonce_id
      WHERE an.status = 'publiée' AND an.price_night > 0 AND x.eff > 0 AND x.eff < an.price_night
      GROUP BY an.id, an.user_id, an.name, an.price_night
    LOOP
      v_fmt := coalesce(a.name, 'Un logement') || ' : dès ' || trim(to_char(a.min_price, 'FM999999990.##')) || ' € / nuit '
        || CASE WHEN a.d1 = a.d2 THEN 'le ' || to_char(a.d1, 'DD/MM')
                ELSE 'du ' || to_char(a.d1, 'DD/MM') || ' au ' || to_char(a.d2, 'DD/MM') END
        || ' (au lieu de ' || trim(to_char(a.base, 'FM999999990.##')) || ' €)';
      FOR u IN
        SELECT DISTINCT pa.user_id FROM public.price_alerts pa
        WHERE pa.annonce_id = a.id AND pa.user_id IS DISTINCT FROM a.owner
      LOOP
        IF NOT EXISTS (SELECT 1 FROM public.push_queue q
                       WHERE q.user_id = u.user_id AND q.tag = 'promo-' || a.id
                         AND q.created_at > now() - interval '1 hour') THEN
          PERFORM public.fn_push_enqueue(u.user_id, '🏷️ Promo sur un de vos favoris', v_fmt,
            '/?logement=' || a.id, 'promo-' || a.id);
        END IF;
      END LOOP;
    END LOOP;
  EXCEPTION WHEN others THEN
    RAISE WARNING 'push date promo: %', SQLERRM;
  END;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.fn_push_date_promo() FROM PUBLIC, anon, authenticated;

-- Un enregistrement du calendrier (upsert) peut insérer et mettre à jour :
-- un trigger pour chaque cas, une fois par instruction.
DROP TRIGGER IF EXISTS trg_push_date_promo_ins ON public.date_discounts;
CREATE TRIGGER trg_push_date_promo_ins AFTER INSERT ON public.date_discounts
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_push_date_promo();
DROP TRIGGER IF EXISTS trg_push_date_promo_upd ON public.date_discounts;
CREATE TRIGGER trg_push_date_promo_upd AFTER UPDATE ON public.date_discounts
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_push_date_promo();

COMMIT;
