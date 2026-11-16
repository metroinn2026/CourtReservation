create table if not exists private.court_correction_notices_v1 (
  subject_key text not null,
  kind text not null check (kind in ('duplicate','membership')),
  record_ids uuid[] not null check (cardinality(record_ids) between 1 and 200),
  status text not null check (status in ('draft','sent','replied','closed')),
  due_at timestamptz,
  sent_at timestamptz,
  replied_at timestamptz,
  closed_at timestamptz,
  note text not null default '' check (char_length(note) <= 1500),
  version integer not null default 1 check (version > 0),
  updated_at timestamptz not null default now(),
  updated_by uuid not null,
  primary key (subject_key, kind),
  check (status not in ('sent','replied') or (due_at is not null and sent_at is not null)),
  check (status <> 'replied' or replied_at is not null),
  check (status <> 'closed' or closed_at is not null)
);

alter table private.court_correction_notices_v1 enable row level security;
revoke all on table private.court_correction_notices_v1 from public, anon, authenticated, service_role;

create or replace function public.court_list_correction_notices_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null or coalesce(public.get_court_admin_identity_v1()->>'role','') not in ('super_admin','staff') then
    raise exception '無權讀取補正通知' using errcode='42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(n) - 'updated_by' order by n.subject_key, n.kind)
    from private.court_correction_notices_v1 n
  ), '[]'::jsonb);
end;
$function$;

create or replace function public.court_save_correction_notices_v1(p_items jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  item jsonb;
  ids uuid[];
  subject text;
  first_subject text;
  found_records bigint;
  found_subjects bigint;
  notice_kind text;
  notice_status text;
  notice_due timestamptz;
  notice_note text;
  expected_version integer;
  prior private.court_correction_notices_v1%rowtype;
begin
  if auth.uid() is null or coalesce(public.get_court_admin_identity_v1()->>'role','') not in ('super_admin','staff') then
    raise exception '無權儲存補正通知' using errcode='42501';
  end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' then
    raise exception '補正通知資料格式不符';
  end if;
  if jsonb_array_length(p_items) not between 1 and 2
    or (select count(distinct value->>'kind') from jsonb_array_elements(p_items))<>jsonb_array_length(p_items) then
    raise exception '請確認補正通知類型';
  end if;

  for item in select value from jsonb_array_elements(p_items) order by value->>'kind' loop
    notice_kind:=coalesce(item->>'kind','');
    notice_status:=coalesce(item->>'status','');
    notice_due:=(item->>'due_at')::timestamptz;
    notice_note:=coalesce(item->>'note','');
    expected_version:=coalesce((item->>'version')::integer,-1);
    if notice_kind not in ('duplicate','membership') or notice_status not in ('draft','sent','replied','closed')
      or expected_version<0 or char_length(notice_note)>1500
      or coalesce(jsonb_typeof(item->'record_ids'),'')<>'array' then
      raise exception '補正通知資料格式不符';
    end if;
    if jsonb_array_length(item->'record_ids') not between 1 and 200 then
      raise exception '請確認補正通知所列的登記';
    end if;
    select array_agg(distinct value::uuid order by value::uuid) into ids
    from jsonb_array_elements_text(item->'record_ids');

    select count(*),count(distinct member_subject),min(member_subject)
      into found_records,found_subjects,subject
    from (
      select case
        when member_kind<>'UNKNOWN' and nullif(btrim(r.member_key_hash),'') is not null
          then member_kind||':'||btrim(r.member_key_hash)
        else 'UNVERIFIED:'||member_kind||':'||coalesce(nullif(r.import_submission_key,''),r.id::text)
      end as member_subject
      from public.lottery_records r
      cross join lateral (select case when r.member_type ~* 'Go會員' then 'GO'
        when r.member_type like '%會館會員%' then 'HALL' else 'UNKNOWN' end as member_kind) k
      where r.id=any(ids)
    ) members;
    if found_records<>cardinality(ids) or found_subjects<>1
      or (first_subject is not null and first_subject<>subject) then
      raise exception '登記已異動，或通知包含不同申請人，請重新整理後核對';
    end if;
    first_subject:=subject;

    select * into prior from private.court_correction_notices_v1
    where subject_key=subject and kind=notice_kind for update;
    if coalesce(prior.version,0)<>expected_version then
      raise exception '此案已由其他承辦人更新，請重新整理後再儲存' using errcode='40001';
    end if;
    if (prior.status='closed' and notice_status<>'closed')
      or (prior.sent_at is not null and notice_status='draft')
      or (prior.replied_at is not null and notice_status='sent') then
      raise exception '請保留已記錄的寄出、回覆及處理進度';
    end if;
    if (notice_status in ('sent','replied') and notice_due is null)
      or (notice_status='replied' and prior.sent_at is null) then
      raise exception '請填寫補正期限，並先記錄寄出後再登錄回覆';
    end if;

    if prior.version is null then
      insert into private.court_correction_notices_v1(
        subject_key,kind,record_ids,status,due_at,sent_at,closed_at,note,updated_by
      ) values (
        subject,notice_kind,ids,notice_status,notice_due,
        case when notice_status='sent' then now() end,
        case when notice_status='closed' then now() end,
        notice_note,auth.uid()
      ) on conflict (subject_key,kind) do nothing;
      if not found then
        raise exception '此案已由其他承辦人更新，請重新整理後再儲存' using errcode='40001';
      end if;
    else
      update private.court_correction_notices_v1 set
        record_ids=ids, status=notice_status, due_at=notice_due, note=notice_note,
        sent_at=coalesce(prior.sent_at,case when notice_status='sent' then now() end),
        replied_at=coalesce(prior.replied_at,case when notice_status='replied' then now() end),
        closed_at=coalesce(prior.closed_at,case when notice_status='closed' then now() end),
        version=prior.version+1, updated_at=now(), updated_by=auth.uid()
      where subject_key=subject and kind=notice_kind;
    end if;
  end loop;
end;
$function$;

revoke all on function public.court_list_correction_notices_v1() from public, anon, authenticated, service_role;
revoke all on function public.court_save_correction_notices_v1(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.court_list_correction_notices_v1() to authenticated;
grant execute on function public.court_save_correction_notices_v1(jsonb) to authenticated;
