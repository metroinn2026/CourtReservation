create table if not exists private.court_phone_corrections_v1 (
  id bigint generated always as identity primary key,
  record_id uuid not null references public.lottery_records(id) on delete cascade,
  previous_phone text,
  current_phone text not null check (current_phone ~ '^09[0-9]{8}$'),
  reason text not null,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);
alter table private.court_phone_corrections_v1 enable row level security;
revoke all on private.court_phone_corrections_v1 from public, anon, authenticated, service_role;
create index if not exists court_phone_corrections_record_idx
  on private.court_phone_corrections_v1(record_id,id desc);

create or replace function public.court_admin_phone_history_v1()
returns table(record_id uuid, changes jsonb)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if auth.uid() is null or coalesce(public.get_court_admin_identity_v1()->>'role','') not in ('super_admin','staff') then
    raise exception '無權查詢手機更正紀錄' using errcode='42501';
  end if;
  return query
  select h.record_id, jsonb_agg(jsonb_build_object(
    'previous_phone',h.previous_phone,'current_phone',h.current_phone,'reason',h.reason,
    'changed_at',h.changed_at,'display_name',coalesce(a.display_name,a.username,'承辦人')
  ) order by h.id desc)
  from private.court_phone_corrections_v1 h
  left join public.admin_users a on a.id=h.changed_by
  group by h.record_id;
end;
$$;

create or replace function public.court_admin_correct_phone_v1(
  p_record_id uuid, p_expected_phone text, p_new_phone text, p_reason text
) returns uuid[]
language plpgsql security definer set search_path = ''
as $$
declare
  v_admin jsonb := public.get_court_admin_identity_v1();
  v_anchor public.lottery_records%rowtype;
  v_record public.lottery_records%rowtype;
  v_submission_key text;
  v_ids uuid[] := '{}';
  v_member_hash text;
  v_go boolean;
  v_reason text := btrim(coalesce(p_reason,''));
begin
  if auth.uid() is null or coalesce(v_admin->>'role','') not in ('super_admin','staff') then
    raise exception '無權更正手機號碼' using errcode='42501';
  end if;
  if coalesce(p_new_phone,'') !~ '^09[0-9]{8}$' or char_length(v_reason) not between 1 and 300 then
    raise exception '請輸入 10 碼手機號碼及更正原因' using errcode='22023';
  end if;
  select * into v_anchor from public.lottery_records where id=p_record_id;
  if not found then raise exception '找不到登記資料' using errcode='P0002'; end if;
  v_submission_key := nullif(v_anchor.import_submission_key,'');
  v_go := coalesce(v_anchor.member_type,'') ~* 'go會員';

  -- Same lock order as the existing form correction workflow.
  if v_submission_key is not null then
    perform 1 from public.lottery_form_submissions where submission_key=v_submission_key for update;
  end if;
  for v_record in
    select * from public.lottery_records
    where id=p_record_id or (v_submission_key is not null and import_submission_key=v_submission_key)
    order by id for update
  loop
    if v_record.phone is distinct from p_expected_phone or
       nullif(v_record.import_submission_key,'') is distinct from v_submission_key or
       v_record.member_type is distinct from v_anchor.member_type or
       v_record.member_key_hash is distinct from v_anchor.member_key_hash then
      raise exception '登記資料已異動或同一份回覆的資料不一致，請重新整理後核對' using errcode='40001';
    end if;
    if v_record.lottery_locked or v_record.result_published or
       coalesce(btrim(v_record.lottery_status),'') not in ('','未抽籤') then
      raise exception '同一份回覆有已鎖定、抽籤或公告的場次，無法更正手機' using errcode='23514';
    end if;
    v_ids:=array_append(v_ids,v_record.id);
  end loop;
  if not (p_record_id=any(v_ids)) then
    raise exception '找不到登記資料' using errcode='P0002';
  end if;
  if p_new_phone is not distinct from p_expected_phone then
    raise exception '更正後手機與目前號碼相同' using errcode='22023';
  end if;

  if v_go then
    v_member_hash:=private.secure_member_key_hash('台北捷運Go會員',p_new_phone);
  end if;

  update public.lottery_form_submissions
  set contact_phone=p_new_phone,
      member_identifier=case when v_go then right(p_new_phone,4) else member_identifier end,
      member_key_hash=case when v_go then v_member_hash else member_key_hash end,
      identifier_hash_version=case when v_go then 'hmac-v1' else identifier_hash_version end
  where submission_key=v_submission_key;

  update public.lottery_records
  set phone=p_new_phone,updated_at=now(),
      member_identifier_last4=case when v_go then right(p_new_phone,4) else member_identifier_last4 end,
      member_key_hash=case when v_go then v_member_hash else member_key_hash end
  where id=any(v_ids);

  if v_go then
    insert into public.lottery_registration_qualifications
      (record_id,review_status,member_check_status)
    select changed_id,'pending','unchecked' from unnest(v_ids) as ids(changed_id)
    on conflict (record_id) do update set
      review_status=case when public.lottery_registration_qualifications.review_status='invalid' then 'invalid' else 'pending' end,
      member_check_status='unchecked', member_checked_by=null, member_checked_at=null, updated_at=now();
    update private.court_review_notes_v1
      set identity_review_key=null, version=version+1, updated_at=now(), updated_by=auth.uid()
      where record_id=any(v_ids) and identity_review_key is not null;
  end if;

  insert into private.court_phone_corrections_v1(record_id,previous_phone,current_phone,reason,changed_by)
  select changed_id,p_expected_phone,p_new_phone,v_reason,(v_admin->>'id')::uuid
  from unnest(v_ids) as ids(changed_id);

  insert into public.admin_operation_logs(admin_id,admin_username,admin_display_name,action,detail,record_ids,created_at)
  values ((v_admin->>'id')::uuid,v_admin->>'username',v_admin->>'display_name','更正手機',
    jsonb_build_object('之前末三碼',right(p_expected_phone,3),'更正後末三碼',right(p_new_phone,3),'筆數',cardinality(v_ids)),
    v_ids::text[],now());
  return v_ids;
end;
$$;

revoke all on function public.court_admin_phone_history_v1() from public, anon, authenticated, service_role;
revoke all on function public.court_admin_correct_phone_v1(uuid,text,text,text) from public, anon, authenticated, service_role;
grant execute on function public.court_admin_phone_history_v1() to authenticated;
grant execute on function public.court_admin_correct_phone_v1(uuid,text,text,text) to authenticated;
