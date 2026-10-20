-- ============================================================================
-- MyTunigo — 2026-10-20 — Coordonnées bancaires (RIB / IBAN) des hôtes
-- ----------------------------------------------------------------------------
-- Décision de Bassem du 20/10 :
--   * saisie dans « Mon profil » pour les hôtes et organisateurs (au moins une
--     annonce ou une excursion), rappel dans la demande de suppression ;
--   * IBAN de tout pays (clé contrôlée) ; un RIB tunisien de 20 chiffres est
--     accepté et converti en IBAN TN (clé RIB contrôlée aussi).
-- Sécurité : table payout_accounts sans aucun accès direct du navigateur.
-- Lecture et écriture par fonctions : le titulaire ne relit qu'un IBAN
-- masqué, l'admin voit l'IBAN complet (onglet « 🗑️ Comptes »).
-- Le RIB est effacé à la suppression du compte.
-- À exécuter en une fois dans le SQL Editor, AVANT la fusion de la PR.
-- ============================================================================

begin;

-- 1. Table -------------------------------------------------------------------
create table if not exists public.payout_accounts (
  user_id     uuid primary key references public.profiles(id) on delete cascade,
  holder_name text not null check (char_length(holder_name) between 2 and 100),
  iban        text not null check (iban ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$'),
  bic         text check (bic is null or bic ~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$'),
  bank_name   text check (bank_name is null or char_length(bank_name) <= 80),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.payout_accounts enable row level security;
revoke all on public.payout_accounts from public, anon, authenticated;
grant select on public.payout_accounts to service_role;   -- futurs reversements

-- 2. Contrôle des numéros ----------------------------------------------------
-- Reste modulo 97 d'un grand nombre écrit en chiffres
create or replace function public.fn_mod97(p_digits text)
returns int
language plpgsql
immutable
set search_path = pg_catalog
as $$
declare
  r bigint := 0;
  i int := 1;
begin
  while i <= length(p_digits) loop
    r := (r::text || substr(p_digits, i, 7))::bigint % 97;
    i := i + 7;
  end loop;
  return r::int;
end $$;

-- Lettres -> nombres (A=10 … Z=35), chiffres inchangés
create or replace function public.fn_iban_digits(p text)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
  select coalesce(string_agg(case when c ~ '[A-Z]' then (ascii(c) - 55)::text else c end, '' order by n), '')
    from regexp_split_to_table(p, '') with ordinality as t(c, n)
$$;

-- IBAN normalisé, ou exception IBAN_INVALID / RIB_KEY_INVALID
create or replace function public.fn_iban_normalize(p_input text)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v   text := upper(regexp_replace(coalesce(p_input, ''), '[\s.-]', '', 'g'));
  len int;
  rib text;
begin
  -- RIB tunisien : 20 chiffres (banque 2, agence 3, compte 13, clé 2)
  if v ~ '^[0-9]{20}$' then
    v := 'TN' || lpad((98 - public.fn_mod97(v || public.fn_iban_digits('TN') || '00'))::text, 2, '0') || v;
  end if;
  if v !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$' then raise exception 'IBAN_INVALID'; end if;

  len := case left(v, 2)
           when 'TN' then 24 when 'FR' then 27 when 'MC' then 27 when 'BE' then 16 when 'DE' then 22
           when 'IT' then 27 when 'ES' then 24 when 'CH' then 21 when 'LU' then 20 when 'NL' then 18
           when 'GB' then 22 when 'PT' then 25 when 'DZ' then 26 when 'MA' then 28 when 'LY' then 25
           else null end;
  if len is not null and length(v) <> len then raise exception 'IBAN_INVALID'; end if;

  if public.fn_mod97(public.fn_iban_digits(substr(v, 5) || left(v, 4))) <> 1 then
    raise exception 'IBAN_INVALID';
  end if;

  -- Tunisie : clé RIB = 97 - ((banque + agence + compte) × 100 mod 97)
  if left(v, 2) = 'TN' then
    rib := substr(v, 5);
    if rib !~ '^[0-9]{20}$'
       or (97 - public.fn_mod97(left(rib, 18) || '00')) <> right(rib, 2)::int then
      raise exception 'RIB_KEY_INVALID';
    end if;
  end if;
  return v;
end $$;

-- 3. Est-ce un hôte / organisateur ? -------------------------------------
create or replace function public.fn_is_host(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.annonces   where user_id  = p_user)
      or exists (select 1 from public.excursions where owner_id = p_user)
$$;

-- 4. Mon RIB (masqué) ------------------------------------------------------
create or replace function public.fn_my_payout_account()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'is_host', public.fn_is_host(auth.uid()),
    'account', (select jsonb_build_object(
                  'holder_name', holder_name, 'bank_name', bank_name, 'bic', bic,
                  'iban_masked', left(iban, 4) || ' •••• •••• ' || right(iban, 4),
                  'country', left(iban, 2), 'updated_at', updated_at)
                  from public.payout_accounts where user_id = auth.uid()))
$$;

-- 5. Enregistrer / supprimer mon RIB -------------------------------------
create or replace function public.fn_set_payout_account(p_holder text, p_iban text, p_bic text default null, p_bank text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_iban   text;
  v_bic    text := nullif(upper(regexp_replace(coalesce(p_bic, ''), '\s', '', 'g')), '');
  v_holder text := btrim(regexp_replace(coalesce(p_holder, ''), '\s+', ' ', 'g'));
  v_bank   text := left(nullif(btrim(coalesce(p_bank, '')), ''), 80);
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if not public.fn_is_host(v_uid) then raise exception 'NOT_HOST'; end if;
  if char_length(v_holder) not between 2 and 100 then raise exception 'HOLDER_INVALID'; end if;
  if v_bic is not null and v_bic !~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$' then raise exception 'BIC_INVALID'; end if;
  v_iban := public.fn_iban_normalize(p_iban);

  insert into public.payout_accounts (user_id, holder_name, iban, bic, bank_name)
  values (v_uid, v_holder, v_iban, v_bic, v_bank)
  on conflict (user_id) do update
    set holder_name = excluded.holder_name, iban = excluded.iban, bic = excluded.bic,
        bank_name = excluded.bank_name, updated_at = now();

  return public.fn_my_payout_account();
end $$;

create or replace function public.fn_delete_payout_account()
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  delete from public.payout_accounts where user_id = auth.uid()
$$;

-- 6. Liste admin des demandes de suppression : RIB inclus ---------------
create or replace function public.fn_admin_account_deletions()
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
      from (
        select d.id, d.host_id as user_id, d.item_name as name, d.host_email as email,
               d.reason, d.status, d.created_at, d.processed_at, d.admin_note,
               d.status = 'en attente' as pending,
               jsonb_array_length(coalesce(d.details -> 'suspended', '[]'::jsonb)) as suspended,
               (select count(*) from public.annonces  a where a.user_id  = d.host_id) as annonces,
               (select count(*) from public.excursions e where e.owner_id = d.host_id) as excursions,
               case when d.status = 'en attente' then public.fn_account_deletion_blockers(d.host_id) end as blockers,
               -- RIB complet, pour les derniers reversements (admin uniquement)
               (select jsonb_build_object('holder_name', pa.holder_name, 'iban', pa.iban, 'bic', pa.bic,
                                          'bank_name', pa.bank_name, 'updated_at', pa.updated_at)
                  from public.payout_accounts pa where pa.user_id = d.host_id) as payout
          from public.deletion_requests d
         where d.item_type = 'compte'
           and (d.status = 'en attente' or d.created_at > now() - interval '180 days')
      ) x
  ), '[]'::jsonb);
end $$;

-- 7. Finalisation de la suppression : RIB effacé ------------------------
create or replace function public.fn_account_deletion_finalize(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid;
  v_blk jsonb;
  n_ann int; n_exc int;
begin
  select host_id into v_uid from public.deletion_requests
   where id = p_request and item_type = 'compte' and status = 'en attente'
   for update;
  if v_uid is null then raise exception 'NOT_FOUND'; end if;

  v_blk := public.fn_account_deletion_blockers(v_uid);
  if (v_blk ->> 'total')::int > 0 then raise exception 'BLOCKED: %', v_blk; end if;

  -- Profil : anonymisé (la ligne reste, pour les réservations, avis et messages)
  update public.profiles set
    email = 'supprime-' || id || '@mytunigo.invalid',
    first_name = 'Utilisateur', last_name = 'supprimé',
    phone = null, avatar_url = null, photo = null, bio = null,
    country = null, city = null, birthdate = null, verified = false
  where id = v_uid;

  -- Annonces et excursions : archivées, contacts effacés (l'historique des
  -- voyageurs garde le nom et les photos du bien)
  update public.annonces set status = 'supprimée', pending_changes = null,
    contact_firstname = null, contact_lastname = null, contact_email = null, contact_phone = null
  where user_id = v_uid;
  get diagnostics n_ann = row_count;

  update public.excursions set status = 'supprimée',
    contact_firstname = null, contact_lastname = null, contact_email = null, contact_phone = null
  where owner_id = v_uid;
  get diagnostics n_exc = row_count;

  -- Données propres au compte
  delete from public.favorites          where user_id = v_uid;
  delete from public.price_alerts       where user_id = v_uid;
  delete from public.push_subscriptions where user_id = v_uid;
  delete from public.push_queue         where user_id = v_uid;
  delete from public.payout_accounts    where user_id = v_uid;
  update public.annonce_views set viewer_id = null where viewer_id = v_uid;

  -- Plus d'e-mails de demande d'avis liés à ce compte (voyageur ou hôte)
  update public.reservations r set
    review_email_sent_at      = coalesce(r.review_email_sent_at, now()),
    review_reminder_sent_at   = coalesce(r.review_reminder_sent_at, now()),
    host_review_email_sent_at = coalesce(r.host_review_email_sent_at, now())
  where r.guest_id = v_uid
     or r.logement_id in (select id from public.annonces where user_id = v_uid);

  update public.excursion_bookings b set
    review_email_sent_at    = coalesce(b.review_email_sent_at, now()),
    review_reminder_sent_at = coalesce(b.review_reminder_sent_at, now())
  where b.guest_id = v_uid
     or b.excursion_id in (select id from public.excursions where owner_id = v_uid);

  -- Demandes de cet utilisateur : plus d'e-mail en clair
  update public.deletion_requests
     set host_email = null,
         item_name  = case when item_type = 'compte' then 'Utilisateur supprimé' else item_name end
   where host_id = v_uid;
  update public.deletion_requests
     set status = 'traitée', processed_at = now(), item_name = 'Utilisateur supprimé'
   where id = p_request;

  return jsonb_build_object('user_id', v_uid, 'annonces', n_ann, 'excursions', n_exc);
end $$;

-- 8. Droits ------------------------------------------------------------------
revoke all on function public.fn_mod97(text)                                from public, anon, authenticated;
revoke all on function public.fn_iban_digits(text)                          from public, anon, authenticated;
revoke all on function public.fn_iban_normalize(text)                       from public, anon, authenticated;
revoke all on function public.fn_is_host(uuid)                              from public, anon, authenticated;
revoke all on function public.fn_my_payout_account()                        from public, anon;
revoke all on function public.fn_set_payout_account(text, text, text, text) from public, anon;
revoke all on function public.fn_delete_payout_account()                    from public, anon;
grant execute on function public.fn_my_payout_account()                        to authenticated;
grant execute on function public.fn_set_payout_account(text, text, text, text) to authenticated;
grant execute on function public.fn_delete_payout_account()                    to authenticated;
-- fn_admin_account_deletions et fn_account_deletion_finalize : create or
-- replace conserve les droits posés le 19/10.

commit;

-- Vérifications ------------------------------------------------------------------
-- select public.fn_iban_normalize('TN59 1000 6035 1835 9847 8831');   -- TN5910006035183598478831
-- select public.fn_iban_normalize('10006035183598478831');            -- même résultat
-- select public.fn_iban_normalize('FR76 3000 6000 0112 3456 7890 189');
-- select has_table_privilege('authenticated', 'public.payout_accounts', 'select');  -- false
