-- ============================================================================
-- MyTunigo — 2026-10-20 — Prénom, nom et date de naissance verrouillés
-- ----------------------------------------------------------------------------
-- Décision de Bassem du 20/10 :
--   * bloqués : prénom, nom, date de naissance (confiance entre hôtes et
--     voyageurs, cohérence avec le titulaire du RIB) ;
--   * modifiables : téléphone, pays, photo, bio ;
--   * une correction se demande (droit de rectification RGPD) et l'admin
--     l'accepte ou la refuse.
-- Une valeur vide peut être renseignée une fois (prénom ou nom vide à
-- l'inscription, date de naissance jamais saisie), puis elle est bloquée.
-- À exécuter en une fois dans le SQL Editor, AVANT la fusion de la PR.
-- ============================================================================

begin;

-- 1. Verrou ------------------------------------------------------------------
create or replace function public.fn_profile_identity_lock()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if current_user in ('postgres','service_role','supabase_admin') or public.fn_is_admin() then
    return new;
  end if;
  if (new.first_name is distinct from old.first_name and coalesce(btrim(old.first_name), '') <> '')
     or (new.last_name is distinct from old.last_name and coalesce(btrim(old.last_name), '') <> '')
     or (new.birthdate is distinct from old.birthdate and old.birthdate is not null) then
    raise exception 'IDENTITY_LOCKED' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists trg_profile_identity_lock on public.profiles;
create trigger trg_profile_identity_lock
  before update of first_name, last_name, birthdate on public.profiles
  for each row execute function public.fn_profile_identity_lock();

-- 2. Demandes de correction -------------------------------------------------
create table if not exists public.profile_change_requests (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  old_first_name text, old_last_name text, old_birthdate date,
  new_first_name text, new_last_name text, new_birthdate date,
  reason        text not null check (char_length(reason) between 3 and 500),
  status        text not null default 'en attente'
                check (status in ('en attente','acceptée','refusée','annulée')),
  admin_note    text,
  created_at    timestamptz not null default now(),
  processed_at  timestamptz
);
create unique index if not exists profile_change_requests_one_pending
  on public.profile_change_requests (user_id) where status = 'en attente';
alter table public.profile_change_requests enable row level security;
revoke all on public.profile_change_requests from public, anon, authenticated;

-- 3. Demander une correction (utilisateur) ----------------------------------
create or replace function public.fn_request_profile_change(
  p_first text, p_last text, p_birthdate date, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  p        public.profiles%rowtype;
  v_first  text := nullif(btrim(regexp_replace(coalesce(p_first, ''), '\s+', ' ', 'g')), '');
  v_last   text := nullif(btrim(regexp_replace(coalesce(p_last, ''), '\s+', ' ', 'g')), '');
  v_reason text := btrim(coalesce(p_reason, ''));
  v_id     uuid;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  select * into p from public.profiles where id = v_uid;
  if not found then raise exception 'NOT_FOUND'; end if;
  if exists (select 1 from public.profile_change_requests where user_id = v_uid and status = 'en attente') then
    raise exception 'ALREADY_PENDING';
  end if;
  if char_length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if (v_first is not null and char_length(v_first) > 60) or (v_last is not null and char_length(v_last) > 60) then
    raise exception 'NAME_INVALID';
  end if;
  if p_birthdate is not null and (p_birthdate > current_date - interval '16 years' or p_birthdate < date '1900-01-01') then
    raise exception 'BIRTHDATE_INVALID';
  end if;
  -- uniquement les champs réellement modifiés
  if v_first is not distinct from p.first_name then v_first := null; end if;
  if v_last  is not distinct from p.last_name  then v_last  := null; end if;
  if p_birthdate is not distinct from p.birthdate then p_birthdate := null; end if;
  if v_first is null and v_last is null and p_birthdate is null then raise exception 'NO_CHANGE'; end if;

  insert into public.profile_change_requests
    (user_id, old_first_name, old_last_name, old_birthdate, new_first_name, new_last_name, new_birthdate, reason)
  values (v_uid, p.first_name, p.last_name, p.birthdate, v_first, v_last, p_birthdate, left(v_reason, 500))
  returning id into v_id;

  begin
    perform public.fn_push_admins('✏️ Correction de profil à valider',
      coalesce(nullif(btrim(p.first_name || ' ' || p.last_name), ''), 'Un utilisateur') || ' demande une correction', 'profile-change-' || v_id);
  exception when others then raise warning 'push admins: %', sqlerrm;
  end;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.fn_cancel_profile_change()
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.profile_change_requests set status = 'annulée', processed_at = now()
   where user_id = auth.uid() and status = 'en attente'
$$;

-- Ma dernière demande (affichée dans le profil)
create or replace function public.fn_my_profile_change()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select (select jsonb_build_object(
            'id', r.id, 'status', r.status, 'created_at', r.created_at, 'processed_at', r.processed_at,
            'new_first_name', r.new_first_name, 'new_last_name', r.new_last_name, 'new_birthdate', r.new_birthdate,
            'admin_note', r.admin_note)
            from public.profile_change_requests r
           where r.user_id = auth.uid()
           order by r.created_at desc limit 1)
$$;

-- 4. Admin -------------------------------------------------------------------
create or replace function public.fn_admin_profile_changes()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.fn_is_admin() then raise exception 'FORBIDDEN'; end if;
  return coalesce((
    select jsonb_agg(row_to_json(x) order by x.pending desc, x.created_at desc)
      from (select r.*, r.status = 'en attente' as pending, u.email
              from public.profile_change_requests r
              left join auth.users u on u.id = r.user_id
             where r.status = 'en attente' or r.created_at > now() - interval '180 days') x
  ), '[]'::jsonb);
end $$;

create or replace function public.fn_admin_decide_profile_change(p_request uuid, p_accept boolean, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r public.profile_change_requests%rowtype;
begin
  if not public.fn_is_admin() then raise exception 'FORBIDDEN'; end if;
  select * into r from public.profile_change_requests where id = p_request and status = 'en attente' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_accept then
    update public.profiles set
      first_name = coalesce(r.new_first_name, first_name),
      last_name  = coalesce(r.new_last_name, last_name),
      birthdate  = coalesce(r.new_birthdate, birthdate)
    where id = r.user_id;
  end if;
  update public.profile_change_requests
     set status = case when p_accept then 'acceptée' else 'refusée' end,
         admin_note = nullif(left(btrim(coalesce(p_note, '')), 500), ''),
         processed_at = now()
   where id = p_request;
  return jsonb_build_object('id', p_request, 'status', case when p_accept then 'acceptée' else 'refusée' end);
end $$;

-- 5. Droits ------------------------------------------------------------------
revoke all on function public.fn_request_profile_change(text, text, date, text)   from public, anon;
revoke all on function public.fn_cancel_profile_change()                          from public, anon;
revoke all on function public.fn_my_profile_change()                              from public, anon;
revoke all on function public.fn_admin_profile_changes()                          from public, anon;
revoke all on function public.fn_admin_decide_profile_change(uuid, boolean, text) from public, anon;
grant execute on function public.fn_request_profile_change(text, text, date, text)   to authenticated;
grant execute on function public.fn_cancel_profile_change()                          to authenticated;
grant execute on function public.fn_my_profile_change()                              to authenticated;
grant execute on function public.fn_admin_profile_changes()                          to authenticated;
grant execute on function public.fn_admin_decide_profile_change(uuid, boolean, text) to authenticated;

commit;
