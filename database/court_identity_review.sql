begin;

alter table private.court_review_notes_v1
  add column if not exists identity_review_key text;

create or replace function public.court_list_qualifications_with_identity_v1()
returns table (
  record_id uuid, review_status text, review_note text, reviewer_email text,
  reviewed_at timestamptz, member_check_status text, member_checked_at timestamptz,
  duplicate_check_status text, processing_note text, processing_note_version integer,
  identity_review_key text
)
language sql
security definer
set search_path = ''
as $function$
  select q.*, n.identity_review_key
  from public.court_list_qualifications_with_notes_v1() q
  left join private.court_review_notes_v1 n using (record_id);
$function$;

create or replace function public.court_save_review_and_notice_progress_v2(
  p_record_id uuid, p_status text, p_member_status text, p_note text,
  p_note_version integer, p_notice_edits jsonb, p_linked_notices jsonb,
  p_identity_review_key text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_member_hash text;
  v_closed integer;
begin
  if auth.uid() is null
     or coalesce(public.get_court_admin_identity_v1()->>'role','') not in ('super_admin','staff') then
    raise exception '無權儲存案件處理結果' using errcode='42501';
  end if;
  if char_length(p_identity_review_key) > 500000 then
    raise exception '關聯登記資料過多，請先核對清單' using errcode='22023';
  end if;

  if p_status is not null then
    select nullif(member_key_hash,'') into v_member_hash
    from public.lottery_records where id=p_record_id;

    if v_member_hash is not null then
      -- Serialize final decisions for the same verified member identifier.
      perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_member_hash,117));
      if p_status='qualified' and nullif(p_identity_review_key,'') is null and exists (
        select 1 from public.lottery_records sibling
        where sibling.member_key_hash=v_member_hash and sibling.id<>p_record_id
      ) then
        raise exception '同一會員識別另有登記，請重新載入並核對關聯登記。' using errcode='40001';
      end if;
      if p_status='qualified' and exists (
        select 1
        from public.lottery_records sibling
        join public.lottery_registration_qualifications q on q.record_id=sibling.id
        join private.court_review_notes_v1 n on n.record_id=sibling.id
        where sibling.member_key_hash=v_member_hash and sibling.id<>p_record_id
          and q.review_status='qualified' and n.identity_review_key is not null
      ) then
        raise exception '同一會員識別已有一筆登記確認合格，請先核對原合格紀錄。' using errcode='23514';
      end if;
    end if;
  end if;

  -- Keep qualification, notes, notice progress, and the identity review in one transaction.
  v_closed := public.court_save_review_and_notice_progress_v1(
    p_record_id,p_status,p_member_status,p_note,p_note_version,p_notice_edits,p_linked_notices
  );
  if p_status is not null then
    update private.court_review_notes_v1
    set identity_review_key=case when p_status='qualified' then nullif(p_identity_review_key,'') end
    where record_id=p_record_id;
  end if;
  return v_closed;
end;
$function$;

revoke all on function public.court_list_qualifications_with_identity_v1() from public, anon, authenticated, service_role;
grant execute on function public.court_list_qualifications_with_identity_v1() to authenticated;
revoke all on function public.court_save_review_and_notice_progress_v2(uuid,text,text,text,integer,jsonb,jsonb,text) from public, anon, authenticated, service_role;
grant execute on function public.court_save_review_and_notice_progress_v2(uuid,text,text,text,integer,jsonb,jsonb,text) to authenticated;

commit;
