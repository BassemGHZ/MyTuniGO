-- ============================================================================
-- MyTunigo — 2026-10-19 — Un seul compte par e-mail et par numéro de téléphone
-- ----------------------------------------------------------------------------
-- 1. fn_phone_norm(text) : forme comparable d'un numéro (chiffres, indicatif).
--      "+216 50 676 798", "0021650676798", "50 676 798" -> 21650676798
--      "06 50 03 12 34", "+33 6 50 03 12 34"            -> 33650031234
--    Moins de 8 chiffres -> NULL (non contrôlé).
-- 2. Doublon existant (décision de Bassem du 19/10) : le numéro reste sur
--    adem.ben.ali@live.fr, il est vidé sur fathiachebba2026@gmail.com.
-- 3. Index uniques sur profiles : téléphone normalisé, e-mail en minuscules.
-- 4. email_exists : comparaison insensible à la casse, aussi sur auth.users.
-- À exécuter en une fois dans le SQL Editor.
-- ============================================================================

begin;

-- 1. Normalisation -----------------------------------------------------------
create or replace function public.fn_phone_norm(p text)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
  select case
    when d is null or length(d) < 8          then null
    when d like '00%'                        then substr(d, 3)
    when plus                                then d
    when length(d) = 8                       then '216' || d   -- numéro tunisien local
    when length(d) = 10 and d like '0%'      then '33' || substr(d, 2) -- numéro français local
    else d
  end
  from (
    select nullif(regexp_replace(coalesce(p, ''), '\D', '', 'g'), '') as d,
           ltrim(coalesce(p, '')) like '+%'                         as plus
  ) s
$$;

-- 2. Doublon existant ----------------------------------------------------------
update public.profiles
   set phone = null
 where id = (select id from auth.users where lower(email) = 'fathiachebba2026@gmail.com')
   and public.fn_phone_norm(phone) = '21650676798';

-- 3. Index uniques -------------------------------------------------------------
create unique index if not exists profiles_phone_norm_key
  on public.profiles (public.fn_phone_norm(phone))
  where public.fn_phone_norm(phone) is not null;

create unique index if not exists profiles_email_lower_key
  on public.profiles (lower(btrim(email)))
  where email is not null;

-- 4. Vérification à l'inscription ---------------------------------------------
create or replace function public.email_exists(check_email text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from auth.users      where lower(email) = lower(btrim(check_email)))
      or exists (select 1 from public.profiles where lower(btrim(email)) = lower(btrim(check_email)))
$$;

commit;

-- Vérifications (doivent renvoyer 0 ligne / true) ------------------------------
-- select public.fn_phone_norm(phone) n, count(*) from public.profiles
--   where public.fn_phone_norm(phone) is not null group by 1 having count(*) > 1;
-- select public.email_exists('ADEM.BEN.ALI@LIVE.FR');
