-- ============================================================================
-- MyTunigo — 2026-10-20 — Point de rendez-vous et adresse obligatoires
-- ----------------------------------------------------------------------------
-- Décision de Bassem du 20/10 : une excursion doit avoir un point de
-- rendez-vous et une adresse.
--   * à la création : les deux obligatoires ;
--   * à la modification : refusé si l'un des deux est envoyé vide.
-- Les excursions existantes incomplètes (annonces de test) restent en ligne :
-- suspendre / republier ne touche pas à ces champs ; la prochaine
-- modification par le propriétaire imposera de les remplir.
-- L'admin et les fonctions serveur ne sont pas concernés.
-- À exécuter dans le SQL Editor, AVANT la fusion de la PR.
-- ============================================================================

create or replace function public.fn_excursion_place_required()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if current_user in ('postgres','service_role','supabase_admin') or public.fn_is_admin() then
    return new;
  end if;
  if tg_op = 'INSERT' or new.meeting_point is distinct from old.meeting_point then
    if coalesce(btrim(new.meeting_point), '') = '' then raise exception 'MEETING_POINT_REQUIRED'; end if;
  end if;
  if tg_op = 'INSERT' or new.address is distinct from old.address then
    if coalesce(btrim(new.address), '') = '' then raise exception 'ADDRESS_REQUIRED'; end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_excursion_place_required on public.excursions;
create trigger trg_excursion_place_required
  before insert or update of meeting_point, address on public.excursions
  for each row execute function public.fn_excursion_place_required();
