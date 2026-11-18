CREATE OR REPLACE FUNCTION public.court_save_correction_notices_v1(p_items jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  reopen_unsent boolean;
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
    -- An unsent notice may have been closed while another registration still needs correction.
    reopen_unsent := prior.status='closed' and prior.sent_at is null and notice_status='sent'
      and exists (
        select 1
        from public.lottery_records r
        left join public.list_registration_qualifications_v54() q on q.record_id=r.id
        where r.id=any(ids)
          and not coalesce(r.lottery_locked,false) and not coalesce(r.result_published,false)
          and coalesce(btrim(r.lottery_status),'') in ('','未抽籤')
          and q.review_status is distinct from 'invalid'
          and case when notice_kind='membership' then q.member_check_status='not_member'
            else coalesce(q.review_status,'pending') in ('pending','correction')
                 and private.court_has_registration_limit_conflict(r.id,false) end
      );
    if (prior.status='closed' and notice_status<>'closed' and not coalesce(reopen_unsent,false))
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
        closed_at=case when reopen_unsent then null else coalesce(prior.closed_at,case when notice_status='closed' then now() end) end,
        version=prior.version+1, updated_at=now(), updated_by=auth.uid()
      where subject_key=subject and kind=notice_kind;
    end if;
  end loop;
end;
$function$;
