-- =====================================================================
-- MyTunigo — Excursions à proximité d'un hébergement (≤ 50 km)
-- Projet : fxbetakueqkzipsqvtck — 09/10/2026
--
-- 1. Position GPS des excursions (lat / lng).
-- 2. Positions des excursions existantes : centre de leur ville
--    (Bizerte, Djerba, Mahdia, Monastir, Sfax), sinon de leur gouvernorat.
--    Les prestataires peuvent ensuite affiner le point sur la carte.
-- 3. Fonction fn_excursions_near_annonce(annonce, rayon) : excursions
--    publiées à moins de 50 km du logement, triées des mieux notées aux
--    moins bien notées. Utilisée par le site (fin de réservation) et par
--    reservation-flow (e-mails « demande acceptée » et « réservation
--    confirmée »).
--
-- À exécuter AVANT de fusionner la Pull Request et de déployer
-- reservation-flow (les deux utilisent la fonction).
-- =====================================================================

BEGIN;

-- 1. Colonnes GPS ------------------------------------------------------
ALTER TABLE public.excursions ADD COLUMN IF NOT EXISTS lat numeric;
ALTER TABLE public.excursions ADD COLUMN IF NOT EXISTS lng numeric;


-- 2. Positions des excursions existantes ---------------------------------
--    Centres approximatifs (chef-lieu) des 24 gouvernorats, et de quelques
--    villes utilisées dans les excursions actuelles.
CREATE TEMP TABLE _centres(nom text PRIMARY KEY, lat numeric, lng numeric) ON COMMIT DROP;
INSERT INTO _centres VALUES
  ('ariana',36.8625,10.1956), ('béja',36.7256,9.1817), ('ben arous',36.7531,10.2189),
  ('bizerte',37.2744,9.8739), ('gabès',33.8815,10.0982), ('gafsa',34.4250,8.7842),
  ('jendouba',36.5011,8.7802), ('kairouan',35.6781,10.0963), ('kasserine',35.1676,8.8365),
  ('kébili',33.7044,8.9690), ('le kef',36.1822,8.7148), ('mahdia',35.5047,11.0622),
  ('manouba',36.8081,10.0972), ('médenine',33.3549,10.5055), ('monastir',35.7643,10.8113),
  ('nabeul',36.4561,10.7376), ('sfax',34.7406,10.7603), ('sidi bouzid',35.0382,9.4849),
  ('siliana',36.0849,9.3708), ('sousse',35.8256,10.6084), ('tataouine',32.9297,10.4518),
  ('tozeur',33.9197,8.1335), ('tunis',36.8065,10.1815), ('zaghouan',36.4029,10.1429),
  -- villes
  ('djerba',33.8750,10.8575), ('jerba',33.8750,10.8575), ('djerba houmt souk',33.8750,10.8575),
  ('hammamet',36.4000,10.6167), ('tabarka',36.9544,8.7580), ('chebba',35.2372,11.1150);

-- d'abord par ville, puis par gouvernorat
UPDATE public.excursions e SET lat = c.lat, lng = c.lng
  FROM _centres c
 WHERE e.lat IS NULL AND lower(trim(e.city)) = c.nom;

UPDATE public.excursions e SET lat = c.lat, lng = c.lng
  FROM _centres c
 WHERE e.lat IS NULL AND lower(trim(e.governorate)) = c.nom;


-- 3. Recherche des excursions proches d'un logement ---------------------
--    Distance « à vol d'oiseau » (formule de Haversine, rayon terrestre
--    6371 km). Repli : une excursion sans position est retenue si elle est
--    dans la même ville ou le même gouvernorat que le logement.
--    SECURITY INVOKER : la fonction ne voit que ce que l'appelant a le droit
--    de lire (excursions publiées, annonce publiée) ; rien de privé n'est
--    renvoyé.
CREATE OR REPLACE FUNCTION public.fn_excursions_near_annonce(
  p_annonce_id uuid,
  p_radius_km  numeric DEFAULT 50
)
RETURNS TABLE (
  id           uuid,
  title        text,
  city         text,
  price        numeric,
  price_type   text,
  photo        text,
  rating       numeric,
  review_count integer,
  instant_book boolean,
  distance_km  numeric
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
  WITH a AS (
    SELECT lat, lng, lower(trim(city)) AS city, governorate
      FROM public.annonces WHERE id = p_annonce_id
  )
  SELECT e.id, e.title, e.city, e.price, e.price_type,
         e.photos[1]                    AS photo,
         coalesce(e.rating, 0)          AS rating,
         coalesce(e.review_count, 0)    AS review_count,
         coalesce(e.instant_book, false) AS instant_book,
         round(d.km::numeric, 1)        AS distance_km
    FROM public.excursions e
   CROSS JOIN a
   CROSS JOIN LATERAL (
     SELECT CASE WHEN a.lat IS NOT NULL AND a.lng IS NOT NULL
                  AND e.lat IS NOT NULL AND e.lng IS NOT NULL
       THEN 6371 * 2 * asin(sqrt(
              power(sin(radians((e.lat - a.lat)::float8) / 2), 2)
            + cos(radians(a.lat::float8)) * cos(radians(e.lat::float8))
            * power(sin(radians((e.lng - a.lng)::float8) / 2), 2)))
     END AS km
   ) d
   WHERE e.status = 'publiée'
     AND (  d.km <= p_radius_km
         OR (d.km IS NULL AND (lower(trim(e.city)) = a.city
                               OR (e.governorate IS NOT NULL AND e.governorate = a.governorate))))
   ORDER BY coalesce(e.rating, 0) DESC,
            coalesce(e.review_count, 0) DESC,
            d.km NULLS LAST,
            e.title
$$;

GRANT EXECUTE ON FUNCTION public.fn_excursions_near_annonce(uuid, numeric) TO anon, authenticated, service_role;

COMMIT;

-- Vérification (facultative) : excursions proches d'un logement de Mahdia
--   select title, city, rating, distance_km
--     from public.fn_excursions_near_annonce(
--       (select id from public.annonces where city ilike 'mahdia' and status = 'publiée' limit 1));
