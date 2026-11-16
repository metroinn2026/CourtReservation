create or replace function public.court_import_go_membership_checks_v1(p_rows jsonb, p_checked_on date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_entry jsonb;
  v_id uuid;
  v_record public.lottery_records%rowtype;
  v_prior text;
  v_status text;
  v_initial text;
  v_reason text;
  v_note text;
  v_verified int := 0;
  v_not_member int := 0;
  v_unchanged int := 0;
  v_skipped jsonb := '[]'::jsonb;
begin
  if not public.court_active_import_admin_v1()
     or (public.get_court_admin_identity_v1()->>'role') is distinct from 'super_admin' then
    raise exception '僅授權超級管理員可回匯 Go 會員查核結果';
  end if;

  if p_rows is null or jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception '查核清單格式不正確';
  end if;
  if jsonb_array_length(p_rows) not between 1 and 3000 or p_checked_on is null
     or p_checked_on < date '2000-01-01' or p_checked_on >= date '10000-01-01' then
    raise exception '回匯筆數或查核日期不正確';
  end if;

  if exists (select 1 from jsonb_array_elements(p_rows) entry
      where coalesce(entry->>'record_id','') !~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
         or coalesce(entry->>'serial_number','') = ''
         or coalesce(entry->>'status','') not in ('verified','not_member')
         or coalesce(entry->>'initial_review_status','') not in ('qualified','pending')) then
    raise exception '紀錄 ID、序號或會員查核結果格式不正確';
  end if;
  if (select count(distinct (entry->>'record_id')::uuid) from jsonb_array_elements(p_rows) entry)
       <> jsonb_array_length(p_rows) then
    raise exception '完整紀錄 ID 重複';
  end if;

  for v_entry in
    select entry from jsonb_array_elements(p_rows) entry order by (entry->>'record_id')::uuid
  loop
    v_id := (v_entry->>'record_id')::uuid;
    v_status := v_entry->>'status';
    v_initial := v_entry->>'initial_review_status';
    select * into v_record from public.lottery_records where id=v_id for update;
    if not found or v_record.serial_number is distinct from v_entry->>'serial_number'
       or coalesce(v_record.member_type,'') !~* 'Go會員' then
      raise exception '紀錄不存在、序號不符或不屬於 Go 會員，請重新下載對照表';
    end if;

    select member_check_status into v_prior
      from public.lottery_registration_qualifications where record_id=v_id for update;
    v_reason := null;
    if v_prior = v_status then
      v_unchanged := v_unchanged + 1;
      continue;
    elsif v_record.lottery_locked or v_record.result_published
       or btrim(coalesce(v_record.lottery_status,'')) not in ('','未抽籤') then
      v_reason := '抽籤已處理、鎖定或公告';
    elsif coalesce(v_prior,'unchecked') <> 'unchecked' then
      v_reason := '與既有會員查核結果不同';
    end if;
    if v_reason is not null then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'serial_number',v_record.serial_number,'reason',v_reason));
      continue;
    end if;

    v_note := 'Go APP 查核（' || to_char(p_checked_on,'YYYY-MM-DD') || '）：'
      || case when v_status='verified' then '是' else '否' end;
    perform public.court_set_membership_check_v2(v_id, v_status, v_note, v_initial);
    if v_status='verified' then
      v_verified := v_verified + 1;
    else
      v_not_member := v_not_member + 1;
    end if;
  end loop;

  return jsonb_build_object('verified',v_verified,'not_member',v_not_member,
    'unchanged',v_unchanged,'skipped',v_skipped);
end
$function$;

revoke all on function public.court_import_go_membership_checks_v1(jsonb,date) from public, anon, authenticated, service_role;
grant execute on function public.court_import_go_membership_checks_v1(jsonb,date) to authenticated;
