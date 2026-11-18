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

create or replace function private.court_has_registration_limit_conflict(
  p_record_id uuid, p_approved_only boolean
)
returns boolean
language sql
stable
set search_path = ''
as $function$
  with settings as (
    select case when pg_catalog.pg_input_is_valid(value, 'jsonb') then value::jsonb end as rules
    from public.system_settings
    where key='registration_limit_rules'
  ), candidate as (
    select r.*,
      regexp_replace(trim(coalesce(r.day_of_week,'')), '^週', '周') as slot_day,
      substring(r.time_slot from '[0-9]{2}:[0-9]{2}') as slot_start,
      coalesce(nullif(r.sport_usage,''), case when r.venue_type like '%桌球%' then '桌球' end) as sport
    from public.lottery_records r
    where r.id=p_record_id and nullif(trim(r.member_key_hash),'') is not null
      and r.member_type ~* '(go會員|會館會員)'
  ), peers as (
    select r.venue_type,
      regexp_replace(trim(coalesce(r.day_of_week,'')), '^週', '周') as slot_day,
      substring(r.time_slot from '[0-9]{2}:[0-9]{2}') as slot_start,
      coalesce(nullif(r.sport_usage,''), case when r.venue_type like '%桌球%' then '桌球' end) as sport
    from candidate c
    join public.lottery_records r on r.member_key_hash=c.member_key_hash and r.id<>c.id
      and (r.member_type ~* 'go會員')=(c.member_type ~* 'go會員')
      and r.member_type ~* '(go會員|會館會員)'
      and coalesce(nullif(trim(r.location_name),''),'北投會館')
        =coalesce(nullif(trim(c.location_name),''),'北投會館')
    where not p_approved_only or exists (
      select 1
      from public.lottery_registration_qualifications q
      join private.court_review_notes_v1 n using (record_id)
      where q.record_id=r.id and q.review_status='qualified'
        and n.identity_review_key is not null
    )
  ), limits as (
    select c.*,
      case
        when s.rules->'single'->>c.venue_type ~ '^[0-9]+$'
          then (s.rules->'single'->>c.venue_type)::numeric
        else case when c.venue_type in ('羽球','籃球') then 1 else 0 end
      end as venue_max,
      case when jsonb_typeof(s.rules->'groups')='array' then s.rules->'groups' else '[]'::jsonb end as groups
    from candidate c left join settings s on true
  )
  select exists (
    select 1 from limits c
    where exists (
      select 1 from peers r
      where c.slot_day<>'' and r.slot_day=c.slot_day and r.slot_start=c.slot_start
        and (r.venue_type=c.venue_type or r.sport<>c.sport)
    ) or (
      c.venue_max>0 and (select count(*) from peers r where r.venue_type=c.venue_type)>=c.venue_max
    ) or exists (
      select 1
      from jsonb_array_elements(c.groups) g
      where g->'venues' ? c.venue_type
        and (select count(*) from (values ('羽球'),('籃球'),('B1桌球'),('B2桌球')) v(venue)
             where g->'venues' ? v.venue)>=2
        and (select count(*) from peers r where g->'venues' ? r.venue_type)>=case
          when g->>'max' ~ '^[0-9]+$' then greatest(1,(g->>'max')::numeric)
          else 1 end
    )
  );
$function$;

revoke all on function private.court_has_registration_limit_conflict(uuid,boolean) from public, anon, authenticated, service_role;

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
      if p_status='qualified' and nullif(p_identity_review_key,'') is null
         and private.court_has_registration_limit_conflict(p_record_id,false) then
        raise exception '同一會員有時段衝突或超過登記上限，請重新載入並核對。' using errcode='40001';
      end if;
      if p_status='qualified' and private.court_has_registration_limit_conflict(p_record_id,true) then
        raise exception '同一會員已有確認合格的場次與本筆衝突，請先核對原合格紀錄。' using errcode='23514';
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
