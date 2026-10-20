-- ============================================================================
-- MyTunigo — 2026-10-20 — Téléphone verrouillé (voyageurs et hôtes)
-- ----------------------------------------------------------------------------
-- Décision de Bassem du 20/10 : le numéro de téléphone du profil rejoint
-- prénom, nom et date de naissance. Un numéro jamais saisi peut l'être une
-- fois ; ensuite, tout changement passe par une demande de correction
-- validée par l'admin (onglet « ✏️ Corrections »).
-- Suite de 2026-10-20_identite_verrouillee.sql (à exécuter après lui, déjà
-- fait). À exécuter en une fois dans le SQL Editor, AVANT la fusion de la PR.
-- ============================================================================

begin;

-- 1. Verrou étendu au téléphone ---------------------------------------------
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
     or (new.birthdate is distinct from old.birthdate and old.birthdate is not null)
     or (new.phone is distinct from old.phone and coalesce(btrim(old.phone), '') <> '') then
    raise exception 'IDENTITY_LOCKED' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists trg_profile_identity_lock on public.profiles;
create trigger trg_profile_identity_lock
  before update of first_name, last_name, birthdate, phone on public.profiles
  for each row execute function public.fn_profile_identity_lock();

-- 2. Demandes de correction : téléphone -------------------------------------
alter table public.profile_change_requests
  add column if not exists old_phone text,
  add column if not exists new_phone text;

drop function if exists public.fn_request_profile_change(text, text, date, text);

create or replace function public.fn_request_profile_change(
  p_first text, p_last text, p_birthdate date, p_reason text, p_phone text default null)
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
  v_phone  text := nullif(btrim(regexp_replace(coalesce(p_phone, ''), '\s+', ' ', 'g')), '');
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
  if v_phone is not null and public.fn_phone_norm(v_phone) is not distinct from public.fn_phone_norm(p.phone) then v_phone := null; end if;
  if v_phone is not null then
    if public.fn_phone_norm(v_phone) is null or char_length(v_phone) > 30 then raise exception 'PHONE_INVALID'; end if;
    if exists (select 1 from public.profiles where id <> v_uid and public.fn_phone_norm(phone) = public.fn_phone_norm(v_phone)) then
      raise exception 'PHONE_TAKEN';
    end if;
  end if;
  if v_first is null and v_last is null and p_birthdate is null and v_phone is null then raise exception 'NO_CHANGE'; end if;

  insert into public.profile_change_requests
    (user_id, old_first_name, old_last_name, old_birthdate, old_phone,
     new_first_name, new_last_name, new_birthdate, new_phone, reason)
  values (v_uid, p.first_name, p.last_name, p.birthdate, p.phone,
          v_first, v_last, p_birthdate, v_phone, left(v_reason, 500))
  returning id into v_id;

  begin
    perform public.fn_push_admins('✏️ Correction de profil à valider',
      coalesce(nullif(btrim(p.first_name || ' ' || p.last_name), ''), 'Un utilisateur') || ' demande une correction', 'profile-change-' || v_id);
  exception when others then raise warning 'push admins: %', sqlerrm;
  end;
  return jsonb_build_object('id', v_id);
end $$;

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
            'new_phone', r.new_phone, 'admin_note', r.admin_note)
            from public.profile_change_requests r
           where r.user_id = auth.uid()
           order by r.created_at desc limit 1)
$$;

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
      birthdate  = coalesce(r.new_birthdate, birthdate),
      phone      = coalesce(r.new_phone, phone)
    where id = r.user_id;   -- un numéro pris entre-temps est refusé par l'index unique
  end if;
  update public.profile_change_requests
     set status = case when p_accept then 'acceptée' else 'refusée' end,
         admin_note = nullif(left(btrim(coalesce(p_note, '')), 500), ''),
         processed_at = now()
   where id = p_request;
  return jsonb_build_object('id', p_request, 'status', case when p_accept then 'acceptée' else 'refusée' end);
end $$;

revoke all on function public.fn_request_profile_change(text, text, date, text, text) from public, anon;
grant execute on function public.fn_request_profile_change(text, text, date, text, text) to authenticated;

commit;
