-- CourtReservation: concurrent administrator capacity edits with transactional audit.
-- Reproducible schema for IT handover. No production data rows are bundled here.
-- Requires existing public.lottery_capacity_settings, public.admin_operation_logs,
-- public.admin_users and private.court_admin_session_active_v1().
CREATE OR REPLACE FUNCTION public.court_admin_save_capacity_v2(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
 v_row jsonb; v_existing public.lottery_capacity_settings%rowtype;
 v_venue text;v_day text;v_slot text;v_winners integer;v_closed boolean;
 v_expected timestamptz;v_stamp timestamptz;v_result jsonb:='[]'::jsonb;

 v_count integer:=0;
 v_actor public.admin_users%rowtype;
 v_changes jsonb:='[]'::jsonb;
begin
 if not private.court_admin_session_active_v1() or auth.uid() is null
 or not exists (
   select 1 from private.lottery_admin_auth_links_v1 l
   join public.admin_users a on a.id=l.legacy_admin_id
   where l.auth_user_id=auth.uid() and a.is_active=true
     and a.role in ('super_admin','staff')
 ) then raise exception 'not authorized';end if;
 select a.* into v_actor from private.lottery_admin_auth_links_v1 l
 join public.admin_users a on a.id=l.legacy_admin_id
 where l.auth_user_id=auth.uid() and a.is_active=true
   and a.role in ('super_admin','staff')
 limit 1;
 if v_actor.id is null then raise exception 'not authorized'; end if;
 if p_rows is null or jsonb_typeof(p_rows)<>'array'
  or jsonb_array_length(p_rows) not between 1 and 100 then
  raise exception 'invalid capacity batch';end if;
 if (select count(*) from (
  select distinct r->>'venue_type' v,r->>'day_of_week' d,r->>'time_slot' t
  from jsonb_array_elements(p_rows) r
 ) unique_slots) <> jsonb_array_length(p_rows) then
   raise exception 'duplicate capacity slot';end if;
 for v_row in select value from jsonb_array_elements(p_rows) loop
  if jsonb_typeof(v_row)<>'object'
   or not (v_row ?& array['venue_type','day_of_week','time_slot','winner_count','is_closed','expected_updated_at'])
   or jsonb_typeof(v_row->'winner_count')<>'number'
   or jsonb_typeof(v_row->'is_closed')<>'boolean' then
   raise exception 'invalid capacity fields';end if;
  v_venue:=v_row->>'venue_type';v_day:=v_row->>'day_of_week';v_slot:=v_row->>'time_slot';
  if v_venue not in ('羽球','籃球','B1桌球','B2桌球')
    or v_day not in ('周一','周二','周三','周四','周五','周六','周日')
    or v_slot is null or length(v_slot) not between 5 and 40
    or (v_row->>'winner_count') !~ '^[0-9]+$' then
    raise exception 'invalid capacity values';end if;
  v_winners:=(v_row->>'winner_count')::integer;
  v_closed:=(v_row->>'is_closed')::boolean;
  if v_winners not between 1 and 100 then raise exception 'invalid winner count';end if;
  v_expected:=case when jsonb_typeof(v_row->'expected_updated_at')='null'
    then null else (v_row->>'expected_updated_at')::timestamptz end;
  select * into v_existing from public.lottery_capacity_settings c
   where c.venue_type=v_venue and c.day_of_week=v_day and c.time_slot=v_slot
   for update;
  if found then
   if v_existing.updated_at is distinct from v_expected then
    raise exception 'capacity_conflict: % % %',v_venue,v_day,v_slot using errcode='P0001';end if;
   update public.lottery_capacity_settings
   set winner_count=v_winners,is_closed=v_closed,updated_at=clock_timestamp()
   where id=v_existing.id returning updated_at into v_stamp;
  else
   if v_expected is not null then
    raise exception 'capacity_conflict: % % %',v_venue,v_day,v_slot using errcode='P0001';end if;
   insert into public.lottery_capacity_settings(venue_type,day_of_week,time_slot,winner_count,is_closed,updated_at)
   values(v_venue,v_day,v_slot,v_winners,v_closed,clock_timestamp())
   returning updated_at into v_stamp;
  end if;

  v_changes:=v_changes||jsonb_build_array(jsonb_build_object(
    'venue_type',v_venue,'day_of_week',v_day,'time_slot',v_slot,
    'before',case when v_existing.id is null then 'null'::jsonb
      else jsonb_build_object('winner_count',v_existing.winner_count,'is_closed',v_existing.is_closed) end,
    'after',jsonb_build_object('winner_count',v_winners,'is_closed',v_closed)
  ));
  v_result:=v_result||jsonb_build_array(jsonb_build_object(
   'venue_type',v_venue,'day_of_week',v_day,'time_slot',v_slot,
   'winner_count',v_winners,'is_closed',v_closed,'updated_at',v_stamp));
  v_count:=v_count+1;
 end loop;

 insert into public.admin_operation_logs(
   admin_id,admin_username,admin_display_name,action,detail,record_ids,created_at
 ) values(
   v_actor.id,v_actor.username,v_actor.display_name,'修改場次名額',
   jsonb_build_object('total',v_count,'changes',v_changes),
   '{}'::text[],now()
 );
 return jsonb_build_object('updated',v_count,'rows',v_result);
end
$function$
;
revoke all on function public.court_admin_save_capacity_v2(jsonb) from public, anon;
grant execute on function public.court_admin_save_capacity_v2(jsonb) to authenticated;
-- Old API has no optimistic-lock protection. Keep it unavailable to client roles.
revoke execute on function public.court_admin_save_capacity_v1(jsonb) from public, anon, authenticated;
