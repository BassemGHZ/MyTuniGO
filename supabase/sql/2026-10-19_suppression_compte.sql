-- ============================================================================
-- MyTunigo — 2026-10-19 — Suppression de compte sur demande, validée par l'admin
-- ----------------------------------------------------------------------------
-- Décision de Bassem du 19/10 :
--   1. Plus de suppression immédiate : l'utilisateur DEMANDE la suppression
--      (deletion_requests, nouveau type 'compte').
--   2. Dès la demande, ses annonces et excursions publiées ou en attente de
--      validation sont suspendues ; il ne peut plus les republier ni en créer
--      tant que la demande est en cours. Les réservations déjà prises se
--      déroulent normalement. Il peut annuler sa demande (annonces rétablies).
--   3. La demande reste en attente tant qu'il reste des séjours ou des
--      excursions à venir (voyageur ou hôte, demandes en cours comprises).
--   4. Seul l'admin finalise (Edge Function delete-account) : compte de
--      connexion supprimé (suppression douce de Supabase Auth), profil
--      anonymisé, annonces/excursions archivées ('supprimée', contacts
--      effacés), favoris, alertes et appareils supprimés. Réservations, avis
--      et messages sont conservés pour l'autre partie, au nom
--      « Utilisateur supprimé ».
--
-- À exécuter en une fois dans le SQL Editor, AVANT la fusion de la PR.
-- ============================================================================

begin;

-- 1. Table deletion_requests --------------------------------------------------
alter table public.deletion_requests drop constraint if exists deletion_requests_item_type_check;
alter table public.deletion_requests add constraint deletion_requests_item_type_check
  check (item_type = any (array['annonce','excursion','compte']));

alter table public.deletion_requests drop constraint if exists deletion_requests_status_check;
alter table public.deletion_requests add constraint deletion_requests_status_check
  check (status = any (array['en attente','traitée','refusée','annulée']));

alter table public.deletion_requests
  add column if not exists reason       text,
  add column if not exists details      jsonb,
  add column if not exists admin_note   text,
  add column if not exists processed_at timestamptz;

-- Une seule demande de suppression de compte en cours par utilisateur
create unique index if not exists deletion_requests_one_account_pending
  on public.deletion_requests (host_id)
  where item_type = 'compte' and status = 'en attente';

-- Le site ne peut plus insérer une demande 'compte' directement : il passe par
-- fn_request_account_deletion (qui suspend aussi les annonces).
drop policy if exists "hosts insert own deletion requests" on public.deletion_requests;
create policy "hosts insert own deletion requests" on public.deletion_requests
  for insert to authenticated
  with check (host_id = auth.uid() and item_type in ('annonce','excursion'));

-- 2. Demande en cours ? ---------------------------------------------------------
create or replace function public.fn_account_deletion_pending(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.deletion_requests
     where item_type = 'compte' and status = 'en attente' and host_id = p_user
  )
$$;

-- 3. Ce qui empêche encore la suppression -----------------------------------
-- Séjours et excursions non terminés (en attente, acceptés ou confirmés),
-- côté voyageur et côté hôte/organisateur. Heure de Tunis.
create or replace function public.fn_account_deletion_blockers(p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := (now() at time zone 'Africa/Tunis')::date;
  gs int; gs_until date; hs int; hs_until date;
  ge int; ge_until date; he int; he_until date;
begin
  if p_user is distinct from auth.uid()
     and not public.fn_is_admin()
     and coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'FORBIDDEN';
  end if;

  select count(*), max(r.check_out) into gs, gs_until
    from public.reservations r
   where r.guest_id = p_user
     and r.status in ('en attente','acceptée','confirmée')
     and r.check_out >= v_today;

  select count(*), max(r.check_out) into hs, hs_until
    from public.reservations r
    join public.annonces a on a.id = r.logement_id
   where a.user_id = p_user
     and r.status in ('en attente','acceptée','confirmée')
     and r.check_out >= v_today;

  select count(*), max(b.date) into ge, ge_until
    from public.excursion_bookings b
   where b.guest_id = p_user
     and b.status in ('en attente','acceptée','confirmée')
     and b.date >= v_today;

  select count(*), max(b.date) into he, he_until
    from public.excursion_bookings b
    join public.excursions e on e.id = b.excursion_id
   where e.owner_id = p_user
     and b.status in ('en attente','acceptée','confirmée')
     and b.date >= v_today;

  return jsonb_build_object(
    'guest_stays',      gs,
    'host_stays',       hs,
    'guest_excursions', ge,
    'host_excursions',  he,
    'total',            gs + hs + ge + he,
    -- dernier jour encore engagé : suppression possible le lendemain
    'until', (select max(d) from unnest(array[gs_until, hs_until, ge_until, he_until]) d)
  );
end $$;

-- 4. Rétablir les annonces suspendues par une demande (annulée ou refusée) --
create or replace function public.fn_account_deletion_restore(p_request uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  it jsonb;
begin
  for it in
    select jsonb_array_elements(coalesce(details -> 'suspended', '[]'::jsonb))
      from public.deletion_requests where id = p_request
  loop
    if it ->> 't' = 'annonce' then
      update public.annonces   set status = it ->> 'status'
       where id = (it ->> 'id')::uuid and status = 'suspendue';
    else
      update public.excursions set status = it ->> 'status'
       where id = (it ->> 'id')::uuid and status = 'suspendue';
    end if;
  end loop;
end $$;

-- 5. Demander la suppression (utilisateur connecté) -------------------------
create or replace function public.fn_request_account_deletion(p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text;
  v_name  text;
  v_list  jsonb;
  v_id    uuid;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if public.fn_account_deletion_pending(v_uid) then raise exception 'ALREADY_PENDING'; end if;

  select u.email into v_email from auth.users u where u.id = v_uid;
  select nullif(btrim(coalesce(p.first_name,'') || ' ' || coalesce(p.last_name,'')), '')
    into v_name from public.profiles p where p.id = v_uid;

  -- Annonces et excursions visibles ou en attente de validation : suspendues
  with a as (
    update public.annonces x set status = 'suspendue'
      from (select id, status from public.annonces
             where user_id = v_uid and status in ('publiée','en attente')) o
     where x.id = o.id
    returning jsonb_build_object('t','annonce','id',x.id,'status',o.status) j
  ), e as (
    update public.excursions x set status = 'suspendue'
      from (select id, status from public.excursions
             where owner_id = v_uid and status in ('publiée','en attente')) o
     where x.id = o.id
    returning jsonb_build_object('t','excursion','id',x.id,'status',o.status) j
  )
  select coalesce(jsonb_agg(j), '[]'::jsonb) into v_list
    from (select j from a union all select j from e) s;

  insert into public.deletion_requests (item_type, item_id, item_name, host_id, host_email, status, reason, details)
  values ('compte', v_uid, coalesce(v_name, v_email), v_uid, v_email, 'en attente',
          nullif(left(btrim(coalesce(p_reason, '')), 500), ''),
          jsonb_build_object('suspended', v_list))
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'suspended', jsonb_array_length(v_list),
                            'blockers', public.fn_account_deletion_blockers(v_uid));
end $$;

-- 6. Annuler sa demande (utilisateur) ------------------------------------------
create or replace function public.fn_cancel_account_deletion()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.deletion_requests
   where item_type = 'compte' and status = 'en attente' and host_id = auth.uid();
  if v_id is null then raise exception 'NOT_FOUND'; end if;
  -- statut changé d'abord : le verrou des annonces ne s'applique plus
  update public.deletion_requests set status = 'annulée', processed_at = now() where id = v_id;
  perform public.fn_account_deletion_restore(v_id);
  return jsonb_build_object('id', v_id, 'status', 'annulée');
end $$;

-- 7. Ma dernière demande (profil) ------------------------------------------
create or replace function public.fn_my_account_deletion()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select (
    select jsonb_build_object(
      'id', d.id, 'status', d.status, 'created_at', d.created_at, 'reason', d.reason,
      'admin_note', d.admin_note, 'processed_at', d.processed_at,
      'suspended', jsonb_array_length(coalesce(d.details -> 'suspended', '[]'::jsonb)),
      'blockers', case when d.status = 'en attente' then public.fn_account_deletion_blockers(auth.uid()) end)
      from public.deletion_requests d
     where d.item_type = 'compte' and d.host_id = auth.uid()
     order by d.created_at desc limit 1
  )
$$;

-- 8. Liste admin --------------------------------------------------------------
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
               case when d.status = 'en attente' then public.fn_account_deletion_blockers(d.host_id) end as blockers
          from public.deletion_requests d
         where d.item_type = 'compte'
           and (d.status = 'en attente' or d.created_at > now() - interval '180 days')
      ) x
  ), '[]'::jsonb);
end $$;

-- 9. Refus par l'admin (motif affiché à l'utilisateur) -------------------
create or replace function public.fn_admin_refuse_account_deletion(p_request uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.fn_is_admin() then raise exception 'FORBIDDEN'; end if;
  update public.deletion_requests
     set status = 'refusée', processed_at = now(),
         admin_note = nullif(left(btrim(coalesce(p_note, '')), 500), '')
   where id = p_request and item_type = 'compte' and status = 'en attente';
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public.fn_account_deletion_restore(p_request);
  return jsonb_build_object('id', p_request, 'status', 'refusée');
end $$;

-- 10. Finalisation (Edge Function delete-account, clé de service uniquement) --
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

-- 11. Verrou : pas de republication ni de nouvelle annonce pendant la demande --
create or replace function public.fn_listing_deletion_lock()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_owner uuid := case when tg_table_name = 'annonces'
                       then (to_jsonb(new) ->> 'user_id')::uuid
                       else (to_jsonb(new) ->> 'owner_id')::uuid end;
begin
  if current_user in ('postgres','service_role','supabase_admin') or public.fn_is_admin() then
    return new;
  end if;
  if (tg_op = 'INSERT'
      or (new.status in ('publiée','en attente') and new.status is distinct from old.status))
     and public.fn_account_deletion_pending(v_owner) then
    raise exception 'ACCOUNT_DELETION_PENDING';
  end if;
  return new;
end $$;

drop trigger if exists trg_annonces_deletion_lock on public.annonces;
create trigger trg_annonces_deletion_lock before insert or update of status on public.annonces
  for each row execute function public.fn_listing_deletion_lock();

drop trigger if exists trg_excursions_deletion_lock on public.excursions;
create trigger trg_excursions_deletion_lock before insert or update of status on public.excursions
  for each row execute function public.fn_listing_deletion_lock();

-- 12. Droits -----------------------------------------------------------------
revoke all on function public.fn_account_deletion_pending(uuid)            from public, anon;
revoke all on function public.fn_account_deletion_blockers(uuid)           from public, anon;
revoke all on function public.fn_account_deletion_restore(uuid)            from public, anon, authenticated, service_role;
revoke all on function public.fn_request_account_deletion(text)            from public, anon;
revoke all on function public.fn_cancel_account_deletion()                 from public, anon;
revoke all on function public.fn_my_account_deletion()                     from public, anon;
revoke all on function public.fn_admin_account_deletions()                 from public, anon;
revoke all on function public.fn_admin_refuse_account_deletion(uuid, text) from public, anon;
revoke all on function public.fn_account_deletion_finalize(uuid)           from public, anon, authenticated;

grant execute on function public.fn_account_deletion_pending(uuid)            to authenticated, service_role;
grant execute on function public.fn_account_deletion_blockers(uuid)           to authenticated, service_role;
grant execute on function public.fn_request_account_deletion(text)            to authenticated;
grant execute on function public.fn_cancel_account_deletion()                 to authenticated;
grant execute on function public.fn_my_account_deletion()                     to authenticated;
grant execute on function public.fn_admin_account_deletions()                 to authenticated;
grant execute on function public.fn_admin_refuse_account_deletion(uuid, text) to authenticated;
grant execute on function public.fn_account_deletion_finalize(uuid)           to service_role;

-- delete-account lit la demande et le profil (déjà accordé), rien d'autre.

commit;

-- Vérifications ------------------------------------------------------------------
-- select pg_get_constraintdef(oid) from pg_constraint where conname like 'deletion_requests_%_check';
-- select proname, has_function_privilege('anon', oid, 'execute') anon,
--        has_function_privilege('authenticated', oid, 'execute') auth,
--        has_function_privilege('service_role', oid, 'execute') srv
--   from pg_proc where proname like 'fn_%account_deletion%' or proname = 'fn_listing_deletion_lock';
