-- CourtReservation | read-only SQL security regression checks
-- Project: wsvsdwuksuzcjisnpyin
-- This script does not write to application tables.
-- Run in Supabase SQL Editor using the intended project.

do $check$
declare v_total integer;v_protected integer;v_public integer;v_helper_oid oid;
begin
  select count(*),
         count(*) filter(where pg_get_functiondef(p.oid) like '%private.court_admin_session_active_v1()%')
  into v_total,v_protected
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prosecdef
    and has_function_privilege('authenticated',p.oid,'EXECUTE')
    and not has_function_privilege('anon',p.oid,'EXECUTE')
    and (pg_get_functiondef(p.oid) like '%lottery_admin_auth_links_v1%'
      or pg_get_functiondef(p.oid) like '%lottery_import_admins%');

  if v_total < 30 or v_total <> v_protected then
    raise exception 'Admin RPC session protection incomplete: % / %',v_protected,v_total;
  end if;

  select count(*) into v_public
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname in ('court_admin_delete_records_v1','court_admin_update_records_v1',
      'court_admin_publish_v1','court_admin_records_v1','get_court_admin_identity_v1')
    and has_function_privilege('anon',p.oid,'EXECUTE');
  if v_public<>0 then raise exception 'Anonymous administration RPC access detected';end if;

  select p.oid into v_helper_oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private' and p.proname='court_admin_session_active_v1';
  if v_helper_oid is null or has_function_privilege('anon',v_helper_oid,'EXECUTE')
    or has_function_privilege('authenticated',v_helper_oid,'EXECUTE') then
    raise exception 'Private session guard is absent or public';
  end if;
  -- Concurrent capacity saves must be version-checked, audited and callable only by logged-in admins.
  if exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='court_admin_save_capacity_v1'
      and has_function_privilege('authenticated',p.oid,'EXECUTE')
  ) then raise exception 'Legacy unversioned capacity write API is still available';end if;

  if not exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='court_admin_save_capacity_v2'
      and not has_function_privilege('anon',p.oid,'EXECUTE')
      and has_function_privilege('authenticated',p.oid,'EXECUTE')
      and pg_get_functiondef(p.oid) like '%expected_updated_at%'
      and pg_get_functiondef(p.oid) like '%capacity_conflict%'
      and pg_get_functiondef(p.oid) like '%admin_operation_logs%'
      and pg_get_functiondef(p.oid) like '%court_admin_session_active_v1%'
  ) then raise exception 'Audited concurrency-safe capacity API not configured';end if;
end $check$;

-- Live-session check uses a temporary request.jwt.claims setting, no table changes.
do $sessions$
declare v_session uuid;v_user uuid;
begin
  select id,user_id into v_session,v_user
  from auth.sessions where not_after is null or not_after>now() limit 1;
  if v_session is null then
    raise notice 'No active session available; skipped active-session positive test';
  else
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub',v_user,'session_id',v_session,'role','authenticated')::text,true);
    if not private.court_admin_session_active_v1() then
      raise exception 'Existing Auth session was incorrectly rejected';
    end if;
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub',v_user,
        'session_id','00000000-0000-0000-0000-000000000000',
        'role','authenticated')::text,true);
    if private.court_admin_session_active_v1() then
      raise exception 'Invalid session was incorrectly authorized';
    end if;
  end if;
  perform set_config('request.jwt.claims','{}',true);
  if private.court_admin_session_active_v1() then
    raise exception 'Missing session was incorrectly authorized';
  end if;
end $sessions$;

select 'CourtReservation read-only security checks passed' as result;
