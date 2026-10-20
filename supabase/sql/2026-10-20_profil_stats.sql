-- ============================================================================
-- MyTunigo — 2026-10-20 — Indicateurs de « Mon profil » calculés en base
-- ----------------------------------------------------------------------------
-- Avant : les 4 chiffres lisaient des listes du site chargées seulement en
-- visitant « Mes voyages », « Mes annonces »… (0 ou valeurs anciennes en
-- arrivant directement sur le profil ; favoris d'annonces non publiées ignorés).
--   reservations : séjours + excursions réservés comme voyageur, en attente,
--                  acceptés, confirmés ou terminés (hors refusés, expirés,
--                  annulés)
--   favorites    : tous les favoris
--   annonces     : hébergements non supprimés ; excursions à part
--   destinations : villes distinctes (sans tenir compte des majuscules) des
--                  séjours et excursions confirmés ou terminés
-- À exécuter dans le SQL Editor, AVANT la fusion de la PR.
-- ============================================================================

create or replace function public.fn_my_profile_stats()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with me as (select auth.uid() as id)
  select jsonb_build_object(
    'reservations',
        (select count(*) from public.reservations r, me
          where r.guest_id = me.id and r.status in ('en attente','acceptée','confirmée','terminée'))
      + (select count(*) from public.excursion_bookings b, me
          where b.guest_id = me.id and b.status in ('en attente','acceptée','confirmée','terminée')),
    'favorites',  (select count(*) from public.favorites f, me where f.user_id = me.id),
    'annonces',   (select count(*) from public.annonces a, me
                    where a.user_id = me.id and a.status is distinct from 'supprimée'),
    'excursions', (select count(*) from public.excursions e, me
                    where e.owner_id = me.id and e.status is distinct from 'supprimée'),
    'destinations', (select count(distinct c) from (
        select lower(btrim(a.city)) c
          from public.reservations r join public.annonces a on a.id = r.logement_id, me
         where r.guest_id = me.id and r.status in ('confirmée','terminée')
        union
        select lower(btrim(e.city))
          from public.excursion_bookings b join public.excursions e on e.id = b.excursion_id, me
         where b.guest_id = me.id and b.status in ('confirmée','terminée')
      ) v where coalesce(c, '') not in ('', '—'))
  )
  where auth.uid() is not null
$$;

revoke all on function public.fn_my_profile_stats() from public, anon;
grant execute on function public.fn_my_profile_stats() to authenticated;
