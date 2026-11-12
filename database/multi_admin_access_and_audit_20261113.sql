-- CourtReservation | active admin control, import RLS, and audited account operations.
-- Source of truth: Supabase project wsvsdwuksuzcjisnpyin, 2026-11-13.
-- Intended for IT review/controlled migration. No user records are changed by this DDL.
-- PREREQUISITE: private.court_admin_session_active_v1() already installed.
begin;

CREATE OR REPLACE FUNCTION public.court_active_import_admin_v1()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
 select private.court_admin_session_active_v1()
 and exists (
  select 1
  from public.lottery_import_admins ia
  join private.lottery_admin_auth_links_v1 l on l.auth_user_id=ia.user_id
  join public.admin_users a on a.id=l.legacy_admin_id
  where ia.user_id=auth.uid()
    and a.is_active=true
    and a.role in ('super_admin','staff')
 )
$function$
;
revoke all on function public.court_active_import_admin_v1() from public, anon;
grant execute on function public.court_active_import_admin_v1() to authenticated;

alter policy lottery_form_batches_admin_read on public.lottery_form_import_batches
 using ((select public.court_active_import_admin_v1()));
alter policy lottery_form_submissions_admin_read on public.lottery_form_submissions
 using ((select public.court_active_import_admin_v1()));
alter policy lottery_import_anomalies_admin_read on public.lottery_import_anomalies
 using ((select public.court_active_import_admin_v1()));
alter policy lottery_import_audit_admin_read on public.lottery_import_audit
 using ((select public.court_active_import_admin_v1()));
alter policy lottery_import_admins_self_read on public.lottery_import_admins
 using (user_id=auth.uid() and (select public.court_active_import_admin_v1()));

-- Add active admin and current-session checks to importer RPCs without altering business rules.
do $guard$
declare p record;src text;revised text;
 session_guard text:='if not private.court_admin_session_active_v1() then raise exception ''invalid or revoked administrator session''; end if;';
begin
 for p in select x.oid,x.proname from pg_proc x join pg_namespace n on x.pronamespace=n.oid
 where n.nspname='public' and x.proname in (
 'admin_get_member_identifiers','correct_google_form_duplicates_v1','import_google_form_batch',
 'import_google_form_batch_v2','import_google_form_batch_v3','list_anomaly_reviews_v44',
 'replace_google_form_source_v50','resolve_google_form_anomaly','restore_missing_lottery_records',
 'save_anomaly_review_v44')
 loop
  src:=pg_get_functiondef(p.oid);
  if src like '%public.court_active_import_admin_v1()%' then continue;end if;
  if strpos(src,session_guard)=0 then raise exception 'Missing session guard in %',p.proname;end if;
  revised:=replace(src,session_guard,session_guard||E'\n  if not public.court_active_import_admin_v1() then raise exception ''not authorized''; end if;');
  execute revised;
 end loop;
 for p in select x.oid,x.proname from pg_proc x join pg_namespace n on x.pronamespace=n.oid
 where n.nspname='public' and x.proname in ('list_registration_qualifications_v52','save_registration_qualification_v52')
 loop
  src:=pg_get_functiondef(p.oid);
  if src like '%public.court_active_import_admin_v1()%' then continue;end if;
  if p.proname='list_registration_qualifications_v52' then
    revised:=replace(src,'exists(select 1 from public.lottery_import_admins where user_id=auth.uid())','public.court_active_import_admin_v1()');
  else
    revised:=replace(src,'exists(select 1 from public.lottery_import_admins where user_id=v_actor)','public.court_active_import_admin_v1()');
  end if;
  if src=revised then raise exception 'Unexpected qualification RPC definition %',p.proname;end if;
  execute revised;
 end loop;
end $guard$;

-- Administrative state transitions share a transaction-scoped lock.
-- This ensures the last active super administrator cannot be lost in concurrent operations.
CREATE OR REPLACE FUNCTION public.court_admin_toggle_account_v1(p_id uuid, p_active boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
 v_actor public.admin_users%rowtype;
 v_target public.admin_users%rowtype;
 v_super_count integer;
begin
 if not private.court_admin_session_active_v1() then raise exception 'invalid or revoked administrator session';end if;
 -- Serialize administrative changes, preventing concurrent loss of all active super admins.
 perform pg_advisory_xact_lock(150710,1);
 select a.* into v_actor from private.lottery_admin_auth_links_v1 l
 join public.admin_users a on a.id=l.legacy_admin_id
 where l.auth_user_id=auth.uid() and a.is_active=true and a.role='super_admin' limit 1;
 if v_actor.id is null then raise exception 'not authorized';end if;
 if p_id is null or p_active is null then raise exception 'invalid request';end if;
 if p_id=v_actor.id and not p_active then raise exception 'cannot disable current account';end if;
 select * into v_target from public.admin_users where id=p_id for update;
 if not found then raise exception 'account not found';end if;
 if v_target.is_active=p_active then return true;end if;
 if not p_active and v_target.role='super_admin' then
   select count(*) into v_super_count from public.admin_users
   where role='super_admin' and is_active=true and id<>p_id;
   if v_super_count<1 then raise exception 'cannot disable last active super admin';end if;
 end if;
 update public.admin_users set is_active=p_active,updated_at=now() where id=p_id;
 insert into public.admin_operation_logs(
  admin_id,admin_username,admin_display_name,action,detail,record_ids,created_at
 ) values(
  v_actor.id,v_actor.username,v_actor.display_name,
  case when p_active then '啟用管理員帳號' else '停用管理員帳號' end,
  jsonb_build_object(
    'target_admin_id',v_target.id,
    'target_username',v_target.username,
    'target_display_name',v_target.display_name,
    'target_role',v_target.role,
    'before_active',v_target.is_active,
    'after_active',p_active
  ),
  '{}'::text[],now()
 );
 return true;
end
$function$
;
CREATE OR REPLACE FUNCTION public.court_admin_set_account_role_v1(p_id uuid, p_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  v_actor public.admin_users%rowtype;
  v_target public.admin_users%rowtype;
  v_active_superadmins integer;
begin
  if not private.court_admin_session_active_v1() then raise exception 'invalid or revoked administrator session'; end if;
  perform pg_advisory_xact_lock(150710,1);
  select a.* into v_actor
  from private.lottery_admin_auth_links_v1 l
  join public.admin_users a on a.id=l.legacy_admin_id
  where l.auth_user_id=auth.uid()
    and a.is_active=true
    and a.role='super_admin'
  limit 1;

  if not found then raise exception 'not authorized'; end if;
  if p_id is null or p_role not in ('super_admin','staff') then raise exception 'invalid request'; end if;
  if p_id=v_actor.id then raise exception 'cannot change current account role'; end if;

  select * into v_target from public.admin_users where id=p_id for update;
  if not found then raise exception 'account not found'; end if;

  if v_target.role='super_admin' and p_role='staff' and v_target.is_active then
    select count(*) into v_active_superadmins
    from public.admin_users
    where role='super_admin' and is_active=true and id<>p_id;
    if v_active_superadmins<1 then raise exception 'cannot demote last active super admin'; end if;
  end if;

  if v_target.role=p_role then
    return jsonb_build_object('updated',false,'id',v_target.id,'role',v_target.role);
  end if;

  update public.admin_users
  set role=p_role,updated_at=now()
  where id=p_id;

  insert into public.admin_operation_logs(
    admin_id,admin_username,admin_display_name,action,detail,record_ids,created_at
  ) values(
    v_actor.id,v_actor.username,v_actor.display_name,
    '修改管理員權限',
    jsonb_build_object(
      'target_admin_id',v_target.id,
      'target_username',v_target.username,
      'target_display_name',v_target.display_name,
      'before_role',v_target.role,
      'after_role',p_role
    ),
    array[]::text[],
    now()
  );

  return jsonb_build_object('updated',true,'id',v_target.id,'role',p_role);
end
$function$
;
CREATE OR REPLACE FUNCTION public.court_admin_delete_account_v1(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  v_actor public.admin_users%rowtype;
  v_target public.admin_users%rowtype;
  v_auth_user_id uuid;
  v_other_active_superadmins integer;
begin
  if not private.court_admin_session_active_v1() then raise exception 'invalid or revoked administrator session'; end if;
  perform pg_advisory_xact_lock(150710,1);
  select a.* into v_actor
  from private.lottery_admin_auth_links_v1 l
  join public.admin_users a on a.id=l.legacy_admin_id
  where l.auth_user_id=auth.uid()
    and a.is_active=true
    and a.role='super_admin'
  limit 1;

  if not found then
    raise exception 'not authorized';
  end if;

  if p_id is null then
    raise exception 'invalid request';
  end if;

  if p_id=v_actor.id then
    raise exception 'cannot delete current account';
  end if;

  select * into v_target
  from public.admin_users
  where id=p_id
  for update;

  if not found then
    raise exception 'account not found';
  end if;

  if v_target.is_active then
    raise exception 'disable account before deletion';
  end if;

  if v_target.role='super_admin' then
    select count(*) into v_other_active_superadmins
    from public.admin_users
    where role='super_admin'
      and is_active=true
      and id<>p_id;

    if v_other_active_superadmins < 1 then
      raise exception 'cannot delete last active super admin';
    end if;
  end if;

  select auth_user_id into v_auth_user_id
  from private.lottery_admin_auth_links_v1
  where legacy_admin_id=p_id
  limit 1;

  insert into public.admin_operation_logs(
    admin_id,admin_username,admin_display_name,action,detail,record_ids,created_at
  ) values (
    v_actor.id,v_actor.username,v_actor.display_name,
    '刪除管理員帳號',
    jsonb_build_object(
      'deleted_admin_id',v_target.id,
      'deleted_username',v_target.username,
      'deleted_display_name',v_target.display_name,
      'deleted_role',v_target.role,
      'had_auth_link',v_auth_user_id is not null
    ),
    array[]::text[],
    now()
  );

  delete from private.lottery_admin_auth_links_v1
  where legacy_admin_id=p_id;

  delete from public.admin_users
  where id=p_id;

  return jsonb_build_object(
    'deleted',true,
    'id',v_target.id,
    'username',v_target.username,
    'display_name',v_target.display_name,
    'auth_link_removed',v_auth_user_id is not null
  );
end
$function$
;
commit;
