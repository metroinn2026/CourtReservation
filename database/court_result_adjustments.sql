-- Atomic, audited result corrections. Canonical statuses remain compatible with existing publication/export APIs.
create table if not exists private.court_lottery_original_results_v1 (
 record_id uuid primary key references public.lottery_records(id) on delete cascade,
 original_status text not null, captured_at timestamptz not null default now()
);
create table if not exists private.court_lottery_result_changes_v1 (
 id bigint generated always as identity primary key,
 batch_id uuid not null,record_id uuid not null references public.lottery_records(id) on delete cascade,
 version integer not null,before_status text not null,after_status text not null,
 action text not null check(action in ('promoted','usage_excluded','time_excluded','withdrawn','original')),
 reason text not null check(length(btrim(reason)) between 1 and 1500),
 admin_id uuid not null,admin_label text not null,changed_at timestamptz not null default now(),
 unique(record_id,version)
);
alter table private.court_lottery_original_results_v1 enable row level security;
alter table private.court_lottery_result_changes_v1 enable row level security;
revoke all on private.court_lottery_original_results_v1,private.court_lottery_result_changes_v1 from public,anon,authenticated;
-- First retained status is immutable. Existing results are retained at feature activation.
insert into private.court_lottery_original_results_v1(record_id,original_status)
select id,lottery_status from public.lottery_records where coalesce(lottery_status,'') not in ('','未抽籤') on conflict do nothing;
create or replace function private.court_retain_original_result_v1() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' and coalesce(old.lottery_status,'') not in ('','未抽籤') then
   insert into private.court_lottery_original_results_v1(record_id,original_status) values(new.id,old.lottery_status) on conflict do nothing;
 elsif coalesce(new.lottery_status,'') not in ('','未抽籤') then
   insert into private.court_lottery_original_results_v1(record_id,original_status) values(new.id,new.lottery_status) on conflict do nothing;
 end if;
 return new;
end $$;
revoke all on function private.court_retain_original_result_v1() from public,anon,authenticated;
drop trigger if exists court_retain_original_result_v1 on public.lottery_records;
create trigger court_retain_original_result_v1 after insert or update of lottery_status on public.lottery_records for each row execute function private.court_retain_original_result_v1();
create or replace function private.court_result_overlap_v1(a text,b text) returns boolean language sql immutable set search_path='' as $$
 select case when a ~ '^\d{2}:\d{2}-\d{2}:\d{2}$' and b ~ '^\d{2}:\d{2}-\d{2}:\d{2}$' then
 ((substring(a,1,2)::int*60+substring(a,4,2)::int)<(substring(b,7,2)::int*60+substring(b,10,2)::int+case when right(b,2)='59' then 1 else 0 end)) and
 ((substring(b,1,2)::int*60+substring(b,4,2)::int)<(substring(a,7,2)::int*60+substring(a,10,2)::int+case when right(a,2)='59' then 1 else 0 end)) else false end
$$;
revoke all on function private.court_result_overlap_v1(text,text) from public,anon,authenticated;
create or replace function public.court_result_history_v1() returns table(record_id uuid,original_status text,captured_at timestamptz,version integer,before_status text,after_status text,action text,reason text,admin_label text,changed_at timestamptz,batch_id uuid)
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or coalesce(public.get_court_admin_identity_v1()->>'role','') not in ('super_admin','staff') then raise exception '無權讀取結果調整紀錄' using errcode='42501';end if;
 return query select o.record_id,o.original_status,o.captured_at,coalesce(h.version,0),h.before_status,h.after_status,h.action,h.reason,h.admin_label,h.changed_at,h.batch_id
 from private.court_lottery_original_results_v1 o left join private.court_lottery_result_changes_v1 h on h.record_id=o.record_id order by o.record_id,h.version desc;
end $$;
revoke all on function public.court_result_history_v1() from public,anon;
grant execute on function public.court_result_history_v1() to authenticated;
create or replace function public.court_adjust_results_v1(p_changes jsonb,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 a jsonb; item jsonb;r public.lottery_records%rowtype;anchor public.lottery_records%rowtype;
 q record;v_action text;v_after text;v_original text;v_before text;v_version int;v_count int;v_cap int;v_closed boolean;
 v_batch uuid:=gen_random_uuid();v_target uuid;v_ids uuid[];v_promoted uuid[]:='{}';v_details jsonb:='[]';
begin
 a:=public.get_court_admin_identity_v1();
 if auth.uid() is null or coalesce(a->>'role','') not in ('super_admin','staff') then raise exception '無權調整抽籤結果' using errcode='42501';end if;
 if length(btrim(coalesce(p_reason,''))) not between 1 and 1500 then raise exception '請填寫調整原因（1500字內）';end if;
 if p_changes is null or jsonb_typeof(p_changes)<>'array' then raise exception '調整資料格式錯誤';end if;
 if jsonb_array_length(p_changes) not between 1 and 500 then raise exception '每次限同一場次1至500筆調整';end if;
 select array_agg((x->>'id')::uuid) into v_ids from jsonb_array_elements(p_changes) x;
 if (select count(distinct x) from unnest(v_ids) x)<>cardinality(v_ids) or array_position(v_ids,null) is not null then raise exception '登記序號重複或缺漏';end if;
 perform pg_advisory_xact_lock(hashtextextended('court-result-adjustments-v1',0));
 perform 1 from public.lottery_records t where t.id=any(v_ids) order by t.id for update;
 select count(*) into v_count from public.lottery_records t where t.id=any(v_ids);
 if v_count<>cardinality(v_ids) then raise exception '資料已變更，請重新載入' using errcode='40001';end if;
 select * into anchor from public.lottery_records t where t.id=v_ids[1];
 if exists(select 1 from public.lottery_records t where t.id=any(v_ids) and
 (coalesce(t.location_name,'北投會館')<>coalesce(anchor.location_name,'北投會館') or t.venue_type<>anchor.venue_type or replace(t.day_of_week,'週','周')<>replace(anchor.day_of_week,'週','周') or left(t.time_slot,5)<>left(anchor.time_slot,5))) then raise exception '連動遞補限同一場次';end if;
 for item in select value from jsonb_array_elements(p_changes) loop
   select * into r from public.lottery_records t where t.id=(item->>'id')::uuid;
   select coalesce(max(h.version),0) into v_version from private.court_lottery_result_changes_v1 h where h.record_id=r.id;
   if coalesce(r.result_published,false) then raise exception '已公布結果請先取消公布，再調整';end if;
   if r.updated_at is distinct from (item->>'expected_updated_at')::timestamptz or coalesce(r.lottery_status,'')<>coalesce(item->>'expected_status','') or v_version<>coalesce((item->>'expected_version')::int,-1) then raise exception '結果已由其他承辦更新，請重新載入' using errcode='40001';end if;
   v_action:=item->>'action';
   select o.original_status into v_original from private.court_lottery_original_results_v1 o where o.record_id=r.id;
   if v_original is null then raise exception '尚無原始抽籤結果，請先完成抽籤結果匯入';end if;
   if v_action='promoted' then
     if coalesce(r.lottery_status,'') !~ '^候補[1-9][0-9]*$' then raise exception '只有備取可以遞補';end if;v_after:='中籤';
   elsif v_action in ('usage_excluded','time_excluded','withdrawn') then
     if coalesce(r.lottery_status,'')<>'中籤' then raise exception '只有目前正取可以調整為未獲分配或放棄';end if;
     v_after:=case when v_action='withdrawn' then '放棄' else '未中籤' end;
   elsif v_action='original' then v_after:=v_original;
   else raise exception '不支援的調整結果';end if;
   if v_after='中籤' then
     select * into q from public.list_registration_qualifications_v54() t where t.record_id=r.id;
     if q.record_id is null or coalesce(q.review_status,'qualified')<>'qualified' or coalesce(q.member_check_status,'unchecked')<>'verified' or nullif(r.member_key_hash,'') is null or r.registered_at<'2026-10-21 08:46+08'::timestamptz or r.registered_at>='2026-11-13 00:00+08'::timestamptz then raise exception '會員及登記資格尚未確認合格，不能核定正取';end if;
     v_promoted:=array_append(v_promoted,r.id);
   end if;
   update public.lottery_records t set lottery_status=v_after,lottery_locked=true,result_published=false,updated_at=now() where t.id=r.id;
   insert into private.court_lottery_result_changes_v1(batch_id,record_id,version,before_status,after_status,action,reason,admin_id,admin_label)
   values(v_batch,r.id,v_version+1,r.lottery_status,v_after,v_action,btrim(p_reason),(a->>'id')::uuid,coalesce(a->>'display_name',a->>'username','管理員'));
   v_details:=v_details||jsonb_build_array(jsonb_build_object('id',r.id,'serial_number',r.serial_number,'before_status',r.lottery_status,'after_status',v_after,'action',v_action));
 end loop;
 -- Validate only after every stage change; all exclusions and promotions commit together.
 foreach v_target in array v_promoted loop
   select * into r from public.lottery_records t where t.id=v_target;
   select c.winner_count,c.is_closed into v_cap,v_closed from public.lottery_capacity_settings c
    where c.venue_type=r.venue_type and replace(c.day_of_week,'週','周')=replace(r.day_of_week,'週','周') and left(c.time_slot,5)=left(r.time_slot,5)
    order by length(c.time_slot) desc,c.updated_at desc limit 1;
   if v_cap is null or v_cap<1 or coalesce(v_closed,false) then raise exception '場次名額尚未設定或未開放';end if;
   select count(*) into v_count from public.lottery_records t where coalesce(t.location_name,'北投會館')=coalesce(r.location_name,'北投會館') and t.venue_type=r.venue_type and replace(t.day_of_week,'週','周')=replace(r.day_of_week,'週','周') and left(t.time_slot,5)=left(r.time_slot,5) and t.lottery_status='中籤';
   if v_count>v_cap then raise exception '調整後正取超過場次名額';end if;
   if r.venue_type='羽球' and ((v_cap<3 and coalesce(r.sport_usage,'羽球')<>'羽球') or exists(select 1 from public.lottery_records t where coalesce(t.location_name,'北投會館')=coalesce(r.location_name,'北投會館') and t.venue_type=r.venue_type and replace(t.day_of_week,'週','周')=replace(r.day_of_week,'週','周') and left(t.time_slot,5)=left(r.time_slot,5) and t.lottery_status='中籤' and coalesce(t.sport_usage,'羽球')<>coalesce(r.sport_usage,'羽球'))) then raise exception '調整後羽球場正取用途不一致或不符場地規定';end if;
   select x->>'expected_status' into v_before from jsonb_array_elements(p_changes) x where (x->>'id')::uuid=r.id and x->>'action'='promoted';
   if v_before is not null and exists(select 1 from public.lottery_records t where coalesce(t.location_name,'北投會館')=coalesce(r.location_name,'北投會館') and t.venue_type=r.venue_type and replace(t.day_of_week,'週','周')=replace(r.day_of_week,'週','周') and left(t.time_slot,5)=left(r.time_slot,5) and (case when t.lottery_status ~ '^候補[1-9][0-9]*$' then substring(t.lottery_status,3)::int end)<substring(v_before,3)::int and (r.venue_type<>'羽球' or coalesce(t.sport_usage,'羽球')=coalesce(r.sport_usage,'羽球'))) then raise exception '有較前備取順位尚待處理，請依原順位遞補';end if;
   if exists(select 1 from public.lottery_records t where t.id<>r.id and t.lottery_status='中籤' and t.member_key_hash=r.member_key_hash and (case when t.member_type ilike '%go%' then 'go' else 'hall' end)=(case when r.member_type ilike '%go%' then 'go' else 'hall' end) and replace(t.day_of_week,'週','周')=replace(r.day_of_week,'週','周') and private.court_result_overlap_v1(t.time_slot,r.time_slot)) then raise exception '同一會員在重疊時段已有正取，請先確認保留場次';end if;
 end loop;
 insert into public.admin_operation_logs(admin_id,admin_username,admin_display_name,action,detail,record_ids)
 values((a->>'id')::uuid,a->>'username',a->>'display_name','抽籤結果調整',jsonb_build_object('batch_id',v_batch,'reason',btrim(p_reason),'changes',v_details),array(select x::text from unnest(v_ids) x));
 return jsonb_build_object('updated_count',cardinality(v_ids),'batch_id',v_batch);
end $$;
revoke all on function public.court_adjust_results_v1(jsonb,text) from public,anon;
grant execute on function public.court_adjust_results_v1(jsonb,text) to authenticated;

-- Full-stage optimistic concurrency guard wraps the existing audited transaction.
create or replace function public.court_adjust_stage_results_v1(p_changes jsonb,p_reason text,p_stage_expected jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 a jsonb; anchor public.lottery_records%rowtype;r public.lottery_records%rowtype;
 expected jsonb;v_expected_ids uuid[];v_stage_ids uuid[];v_count int;v_version int;v_cap int;v_closed boolean;v_result jsonb;
begin
 a:=public.get_court_admin_identity_v1();
 if auth.uid() is null or coalesce(a->>'role','') not in ('super_admin','staff') then raise exception '無權整場調整抽籤結果' using errcode='42501';end if;
 if p_changes is null or jsonb_typeof(p_changes)<>'array' or jsonb_array_length(p_changes) not between 1 and 500 then raise exception '請選擇同一場次要調整的資料';end if;
 if p_stage_expected is null or jsonb_typeof(p_stage_expected)<>'object' or coalesce(jsonb_typeof(p_stage_expected->'records'),'')<>'array' then raise exception '缺少場次核對資料';end if;
 if jsonb_array_length(p_stage_expected->'records') not between 1 and 500 then raise exception '場次名單數量異常';end if;
 perform pg_advisory_xact_lock(hashtextextended('court-result-adjustments-v1',0));
 select * into anchor from public.lottery_records t where t.id=(p_changes->0->>'id')::uuid;
 if not found then raise exception '場次資料已變更' using errcode='40001';end if;
 perform 1 from public.lottery_records t where coalesce(t.location_name,'北投會館')=coalesce(anchor.location_name,'北投會館') and t.venue_type=anchor.venue_type and replace(t.day_of_week,'週','周')=replace(anchor.day_of_week,'週','周') and left(t.time_slot,5)=left(anchor.time_slot,5) order by t.id for update;
 select array_agg(t.id) into v_stage_ids from public.lottery_records t where coalesce(t.location_name,'北投會館')=coalesce(anchor.location_name,'北投會館') and t.venue_type=anchor.venue_type and replace(t.day_of_week,'週','周')=replace(anchor.day_of_week,'週','周') and left(t.time_slot,5)=left(anchor.time_slot,5);
 select array_agg((x->>'id')::uuid) into v_expected_ids from jsonb_array_elements(p_stage_expected->'records') x;
 if cardinality(v_expected_ids)<>cardinality(v_stage_ids) or not(v_expected_ids @> v_stage_ids) or (select count(distinct x) from unnest(v_expected_ids) x)<>cardinality(v_expected_ids) then raise exception '場次名單已增減，請重新載入後再調整' using errcode='40001';end if;
 if exists(select 1 from public.lottery_records t where t.id=any(v_stage_ids) and coalesce(t.result_published,false)) then raise exception '本場有已公布結果，請先取消公布再整場調整';end if;
 for expected in select value from jsonb_array_elements(p_stage_expected->'records') loop
   select * into r from public.lottery_records t where t.id=(expected->>'id')::uuid;
   select coalesce(max(h.version),0) into v_version from private.court_lottery_result_changes_v1 h where h.record_id=r.id;
   if coalesce(r.lottery_status,'')<>coalesce(expected->>'expected_status','') or r.updated_at is distinct from (expected->>'expected_updated_at')::timestamptz or v_version<>coalesce((expected->>'expected_version')::int,-1) then raise exception '同場次結果已被更新，請重新載入，所有調整均未儲存' using errcode='40001';end if;
 end loop;
 select c.winner_count,c.is_closed into v_cap,v_closed from public.lottery_capacity_settings c where c.venue_type=anchor.venue_type and replace(c.day_of_week,'週','周')=replace(anchor.day_of_week,'週','周') and left(c.time_slot,5)=left(anchor.time_slot,5) order by length(c.time_slot) desc,c.updated_at desc limit 1 for update;
 if v_cap is null or v_cap<1 or coalesce(v_closed,false) then raise exception '場次未開放或名額未設定';end if;
 if v_cap is distinct from (p_stage_expected->>'capacity')::int then raise exception '場次名額已變更，請重新預覽' using errcode='40001';end if;
 if exists(select 1 from public.lottery_records t where t.id=any(v_stage_ids) and t.lottery_status ~ '^候補[1-9][0-9]*$' group by t.lottery_status having count(*)>1) then raise exception '本場備取順位重複，請先核對原始抽籤結果';end if;
 v_result:=public.court_adjust_results_v1(p_changes,p_reason);
 select count(*) into v_count from public.lottery_records t where t.id=any(v_stage_ids) and t.lottery_status='中籤';
 if v_count>v_cap then raise exception '本場調整後正取超過名額，整批調整已停止';end if;
 if anchor.venue_type='羽球' and ((select count(distinct coalesce(t.sport_usage,'羽球')) from public.lottery_records t where t.id=any(v_stage_ids) and t.lottery_status='中籤')>1 or (v_cap<3 and exists(select 1 from public.lottery_records t where t.id=any(v_stage_ids) and t.lottery_status='中籤' and coalesce(t.sport_usage,'羽球')<>'羽球'))) then raise exception '本場正取用途仍衝突，請在同一張表完成其他用途的調整';end if;
 if exists(select 1 from public.lottery_records t left join public.list_registration_qualifications_v54() q on q.record_id=t.id where t.id=any(v_stage_ids) and t.lottery_status='中籤' and (q.record_id is null or coalesce(q.review_status,'qualified')<>'qualified' or coalesce(q.member_check_status,'unchecked')<>'verified' or nullif(t.member_key_hash,'') is null or t.registered_at<'2026-10-21 08:46+08'::timestamptz or t.registered_at>='2026-11-13 00:00+08'::timestamptz)) then raise exception '本場正取仍有資格尚未合格的登記，整批調整未儲存';end if;
 if exists(select 1 from public.lottery_records t join public.lottery_records peer on peer.id<>t.id and peer.lottery_status='中籤' and peer.member_key_hash=t.member_key_hash and (case when peer.member_type ilike '%go%' then 'go' else 'hall' end)=(case when t.member_type ilike '%go%' then 'go' else 'hall' end) and replace(peer.day_of_week,'週','周')=replace(t.day_of_week,'週','周') and private.court_result_overlap_v1(peer.time_slot,t.time_slot) where t.id=any(v_stage_ids) and t.lottery_status='中籤') then raise exception '本場正取仍有同時段重複中籤，請確認保留場次';end if;
 return v_result;
end $$;
revoke all on function public.court_adjust_stage_results_v1(jsonb,text,jsonb) from public,anon;
grant execute on function public.court_adjust_stage_results_v1(jsonb,text,jsonb) to authenticated;
