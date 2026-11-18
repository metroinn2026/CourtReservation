alter table public.admin_operation_logs
  add column registration_context jsonb not null default '[]'::jsonb;

create function private.court_log_registration_context(p_ids text[])
returns jsonb
language sql stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'serial_number', r.serial_number, 'venue_type', r.venue_type,
    'day_of_week', r.day_of_week, 'time_slot', r.time_slot
  ) order by i.ordinality), '[]'::jsonb)
  from unnest(p_ids) with ordinality i(id, ordinality)
  join public.lottery_records r on r.id=case
    when i.id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then i.id::uuid end;
$$;

-- Recover serials for historical logs with a surviving registration.
update public.admin_operation_logs
set registration_context=private.court_log_registration_context(record_ids)
where cardinality(record_ids)>0;

create function private.court_snapshot_log_registrations()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if cardinality(new.record_ids)>0 then
    new.registration_context:=private.court_log_registration_context(new.record_ids);
  end if;
  return new;
end;
$$;

create trigger court_snapshot_log_registrations
before insert on public.admin_operation_logs
for each row execute function private.court_snapshot_log_registrations();

create function private.court_log_qualification_decision()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_admin jsonb;
  v_before text := 'pending';
begin
  if tg_op='UPDATE' then v_before:=coalesce(old.review_status,'pending'); end if;
  if new.review_status is not distinct from v_before then return new; end if;
  v_admin:=public.get_court_admin_identity_v1();
  if v_admin is null then return new; end if;

  insert into public.admin_operation_logs(admin_id,admin_username,admin_display_name,action,detail,record_ids,created_at)
  values ((v_admin->>'id')::uuid,v_admin->>'username',v_admin->>'display_name','資格審查',
    jsonb_build_object('before',v_before,'after',new.review_status),array[new.record_id::text],now());
  return new;
end;
$$;

create trigger court_log_qualification_decision
after insert or update of review_status on public.lottery_registration_qualifications
for each row execute function private.court_log_qualification_decision();

revoke all on function private.court_log_registration_context(text[]),
  private.court_snapshot_log_registrations(),
  private.court_log_qualification_decision()
  from public, anon, authenticated;

-- Keep existing clients on v1 while enforcing the same role restriction.
create or replace function public.court_admin_list_logs_v1(p_limit integer default 200)
returns table(id uuid,admin_id uuid,admin_username text,admin_display_name text,action text,detail jsonb,record_ids text[],created_at timestamptz)
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if coalesce(public.get_court_admin_identity_v1()->>'role','') <> 'super_admin' then
    raise exception '操作紀錄僅限超級管理員查詢' using errcode='42501';
  end if;
  return query
  select x.id,x.admin_id,x.admin_username,x.admin_display_name,x.action,x.detail,x.record_ids,x.created_at
  from public.admin_operation_logs x
  order by x.created_at desc,x.id desc
  limit greatest(1,least(coalesce(p_limit,200),500));
end;
$$;

create function public.court_admin_search_logs_v1(p_query text default '',p_offset integer default 0)
returns table(id uuid,admin_username text,admin_display_name text,action text,detail jsonb,
  record_ids text[],registration_context jsonb,created_at timestamptz)
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_query text:=lower(left(btrim(coalesce(p_query,'')),120));
begin
  if coalesce(public.get_court_admin_identity_v1()->>'role','') <> 'super_admin' then
    raise exception '操作紀錄僅限超級管理員查詢' using errcode='42501';
  end if;

  return query
  select x.id,x.admin_username,x.admin_display_name,x.action,x.detail,x.record_ids,x.registration_context,x.created_at
  from public.admin_operation_logs x
  where v_query='' or strpos(lower(concat_ws(' ',x.admin_display_name,x.admin_username,x.action,
    x.detail::text,x.registration_context::text,
    case x.detail->>'before'
      when 'unchecked' then '未查核' when 'verified' then '是會員' when 'not_member' then '非會員'
      when 'qualified' then '合格' when 'pending' then '待審查' when 'correction' then '待補正' when 'invalid' then '不合格' end,
    case x.detail->>'after'
      when 'unchecked' then '未查核' when 'verified' then '是會員' when 'not_member' then '非會員'
      when 'qualified' then '合格' when 'pending' then '待審查' when 'correction' then '待補正' when 'invalid' then '不合格' end
  )),v_query)>0
  order by x.created_at desc,x.id desc
  limit 31 offset greatest(0,coalesce(p_offset,0));
end;
$$;

revoke all on function public.court_admin_list_logs_v1(integer),
  public.court_admin_search_logs_v1(text,integer) from public, anon, authenticated;
grant execute on function public.court_admin_list_logs_v1(integer),
  public.court_admin_search_logs_v1(text,integer) to authenticated;
