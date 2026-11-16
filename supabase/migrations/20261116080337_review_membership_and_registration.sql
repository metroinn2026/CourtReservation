CREATE OR REPLACE FUNCTION public.list_registration_qualifications_v54()
 RETURNS TABLE(record_id uuid, review_status text, review_note text, reviewer_email text, reviewed_at timestamp with time zone, member_check_status text, member_checked_at timestamp with time zone, duplicate_check_status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private', 'pg_temp'
AS $function$
begin
 if not private.court_admin_session_active_v1() then raise exception '管理員 Session 無效';end if;
 if auth.uid() is null or not exists(
  select 1 from private.lottery_admin_auth_links_v1 l
  join public.admin_users a on a.id=l.legacy_admin_id
  where l.auth_user_id=auth.uid() and a.is_active=true and a.role in ('super_admin','staff')
 ) then raise exception 'not authorized';end if;
 return query
 select
   coalesce(q.record_id,d.record_id,c.record_id),
   q.review_status,
   q.review_note,
   coalesce(a.admin_label,'已授權管理員')::text,
   greatest(q.reviewed_at,d.reviewed_at,c.checked_at),
   case
     -- Explicit admin decision takes priority over imported roster evidence.
     when q.member_checked_at is not null then coalesce(q.member_check_status,'unchecked')
     when c.roster_scope='hall' and c.roster_match='found'
       and r.member_type like '%會館會員%' then 'verified'::text
     when d.member_check_status in ('verified','not_member')
       then d.member_check_status
     when c.roster_scope='hall' and c.roster_match='not_found'
       and r.member_type like '%會館會員%' then 'not_member'::text
     else coalesce(q.member_check_status,'unchecked') end,
   greatest(q.member_checked_at,d.reviewed_at,c.checked_at),
   coalesce(d.duplicate_check_status,'none')
 from public.lottery_registration_qualifications q
 full join private.court_offline_review_decisions_v1 d on d.record_id=q.record_id
 full join private.court_member_roster_checks_v1 c on c.record_id=coalesce(q.record_id,d.record_id)
 left join public.lottery_records r on r.id=coalesce(q.record_id,d.record_id,c.record_id)
 left join public.lottery_import_admins a on a.user_id=q.reviewed_by;
end
$function$;

CREATE OR REPLACE FUNCTION public.save_registration_qualification_v52(p_record_id uuid, p_status text, p_note text DEFAULT ''::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare v_actor uuid:=auth.uid();
begin
 if not private.court_admin_session_active_v1() then raise exception 'invalid or revoked administrator session';end if;
 if v_actor is null or not exists(select 1 from private.lottery_admin_auth_links_v1 l
 join public.admin_users a on a.id=l.legacy_admin_id
 where l.auth_user_id=v_actor and a.is_active=true and a.role in ('super_admin','staff'))
 then raise exception 'not authorized';end if;
 if p_status not in ('qualified','pending','correction','invalid') then raise exception 'invalid qualification status';end if;
 if p_status='invalid' and nullif(btrim(coalesce(p_note,'')),'') is null then raise exception '審查不合格必須提供原因';end if;
 perform 1 from public.lottery_records where id=p_record_id for update;
 if not found then raise exception 'record not found';end if;
 if p_status='qualified' and exists(select 1 from public.lottery_registration_qualifications
 where record_id=p_record_id and member_check_status='not_member') then
 raise exception '請先將會員查核結果改為「是」，再將審查結果設為合格';end if;
 insert into public.lottery_registration_qualifications(record_id,review_status,review_note,reviewed_by,reviewed_at,updated_at)
 values(p_record_id,p_status,left(coalesce(p_note,''),1000),v_actor,now(),now())
 on conflict(record_id) do update set review_status=excluded.review_status,review_note=excluded.review_note,
 reviewed_by=excluded.reviewed_by,reviewed_at=excluded.reviewed_at,updated_at=now();
 return true;
end $function$;

CREATE OR REPLACE FUNCTION public.court_set_membership_check_v2(p_record_id uuid, p_status text, p_note text DEFAULT ''::text, p_initial_review_status text DEFAULT 'pending'::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private', 'pg_temp'
AS $function$
declare v_actor uuid:=auth.uid(); v_previous text;
begin
 if not private.court_admin_session_active_v1() then raise exception 'invalid administrator session';end if;
 if v_actor is null or not exists(select 1 from private.lottery_admin_auth_links_v1 l
 join public.admin_users a on a.id=l.legacy_admin_id
 where l.auth_user_id=v_actor and a.is_active and a.role in ('super_admin','staff')) then raise exception 'not authorized';end if;
 if p_initial_review_status is null or p_initial_review_status not in ('qualified','pending') then raise exception 'invalid initial qualification';end if;
 if p_status is null or p_status not in ('unchecked','verified','not_member') then raise exception 'invalid membership status';end if;
 if p_status='not_member' and nullif(btrim(coalesce(p_note,'')),'') is null then raise exception '非會員請填寫查核原因';end if;
 if char_length(coalesce(p_note,''))>850 then raise exception 'reason too long';end if;
 perform 1 from public.lottery_records where id=p_record_id for update;
 if not found then raise exception 'record not found';end if;
 select member_check_status into v_previous
 from public.lottery_registration_qualifications where record_id=p_record_id for update;
 insert into public.lottery_registration_qualifications
 (record_id,review_status,review_note,reviewed_by,reviewed_at,updated_at,member_check_status,member_checked_by,member_checked_at)
 values(p_record_id,
 case when p_status='not_member' then 'pending' else p_initial_review_status end,
 case when p_status='not_member' then '會員查核：非會員。'||p_note else '' end,
 v_actor,now(),now(),p_status,v_actor,now())
 on conflict(record_id) do update set
 member_check_status=excluded.member_check_status,member_checked_by=v_actor,member_checked_at=now(),
 review_status=case
  when p_status in ('not_member','unchecked')
    and public.lottery_registration_qualifications.review_status='qualified' then 'pending'
  else public.lottery_registration_qualifications.review_status end,
 review_note=case
  when p_status='not_member'
    and coalesce(public.lottery_registration_qualifications.review_note,'')='' then excluded.review_note
  else public.lottery_registration_qualifications.review_note end,
 reviewed_by=v_actor,reviewed_at=now(),updated_at=now();
 insert into public.admin_operation_logs(admin_id,admin_username,admin_display_name,action,detail,record_ids,created_at)
 select a.id,a.username,a.display_name,'會員身分查核',
 jsonb_build_object('before',coalesce(v_previous,'unchecked'),'after',p_status,'reason',left(coalesce(p_note,''),850)),
 array[p_record_id::text],now() from private.lottery_admin_auth_links_v1 l
 join public.admin_users a on a.id=l.legacy_admin_id
 where l.auth_user_id=v_actor and a.is_active limit 1;
 return true;
end $function$;

CREATE OR REPLACE FUNCTION public.court_set_membership_check_v1(
  p_record_id uuid, p_status text, p_note text DEFAULT ''
)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $function$
  SELECT public.court_set_membership_check_v2(p_record_id,p_status,p_note,'pending');
$function$;

CREATE OR REPLACE FUNCTION public.save_registration_qualification_v53(
  p_record_id uuid,
  p_status text,
  p_member_status text,
  p_note text DEFAULT ''
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
begin
  if p_status is null or p_status not in ('qualified','pending','correction','invalid')
    or p_member_status is null or p_member_status not in ('unchecked','verified','not_member') then
    raise exception '審查結果或會員狀態無效';
  end if;
  if p_status='qualified' and p_member_status<>'verified' then
    raise exception '審查合格須同時確認會員為「是」';
  end if;
  if p_status='invalid' and nullif(btrim(coalesce(p_note,'')),'') is null then
    raise exception '審查不合格必須提供原因';
  end if;

  -- Both existing write functions authorize the caller and lock this registration.
  perform public.court_set_membership_check_v2(
    p_record_id, p_member_status,
    left(coalesce(nullif(btrim(p_note),''),case when p_member_status='not_member' then '資格審查確認會員為否' else '' end),850),
    case when p_status='qualified' then 'qualified' else 'pending' end
  );
  return public.save_registration_qualification_v52(p_record_id,p_status,p_note);
end
$function$;

REVOKE ALL ON FUNCTION public.save_registration_qualification_v53(uuid,text,text,text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.save_registration_qualification_v53(uuid,text,text,text)
  TO authenticated;

-- Reopen decisions the old membership RPC made automatically. A later formal
-- qualification write has a separate reviewed_at and is preserved.
UPDATE public.lottery_registration_qualifications q
SET review_status='pending', updated_at=now()
FROM public.lottery_records r
WHERE r.id=q.record_id
  AND q.member_check_status='not_member'
  AND q.review_status='invalid'
  AND q.reviewed_at=q.member_checked_at
  AND q.review_note LIKE '會員查核：非會員。%'
  AND NOT coalesce(r.lottery_locked,false)
  AND NOT coalesce(r.result_published,false)
  AND btrim(coalesce(r.lottery_status,'')) IN ('','未抽籤');
