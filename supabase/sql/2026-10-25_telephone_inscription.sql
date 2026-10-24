-- ============================================================================
-- MyTunigo — 2026-10-25 — Téléphone obligatoire à l'inscription
-- ----------------------------------------------------------------------------
-- 1. phone_exists(text) : le formulaire vérifie, avant l'inscription, que le
--    numéro n'est pas déjà utilisé (même comparaison que l'index unique
--    profiles_phone_norm_key : fn_phone_norm).
-- 2. handle_new_user recopie aussi le téléphone saisi (user_metadata.phone)
--    dans le profil. Numéro invalide ou déjà pris entre-temps : le profil est
--    créé sans numéro (l'inscription n'échoue pas), la fenêtre « Complétez
--    votre profil » le redemandera.
-- À exécuter en une fois dans le SQL Editor, AVANT la fusion de la PR.
-- ============================================================================

begin;

create or replace function public.phone_exists(check_phone text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.fn_phone_norm(check_phone) is not null
     and exists (select 1 from public.profiles
                  where public.fn_phone_norm(phone) = public.fn_phone_norm(check_phone))
$$;

revoke all on function public.phone_exists(text) from public;
grant execute on function public.phone_exists(text) to anon, authenticated;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text := nullif(btrim(regexp_replace(coalesce(new.raw_user_meta_data->>'phone', ''), '\s+', ' ', 'g')), '');
begin
  if v_phone is not null and (
       public.fn_phone_norm(v_phone) is null
       or char_length(v_phone) > 30
       or exists (select 1 from public.profiles where public.fn_phone_norm(phone) = public.fn_phone_norm(v_phone))) then
    v_phone := null;
  end if;
  insert into public.profiles (id, email, first_name, last_name, phone)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'first_name', ''),
    coalesce(new.raw_user_meta_data->>'last_name', ''),
    v_phone
  );
  return new;
end;
$$;

commit;

-- Vérification : select public.phone_exists('+216 00 000 000');  -- false
