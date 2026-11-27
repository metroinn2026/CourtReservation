const test=require('node:test'),path=require('node:path');
const assert=require('node:assert/strict'),fs=require('node:fs');
test('full-stage SQL transaction, concurrency, original snapshots and authorization',{skip:!process.env.COURT_PGLITE_MODULE},async()=>{
 const {PGlite}=require(process.env.COURT_PGLITE_MODULE);
 const db=new PGlite();
 await db.exec(`create schema private;create schema auth;create role anon;create role authenticated;
 create function auth.uid() returns uuid language sql stable as $$ select case when coalesce(current_setting('test.role',true),'admin')='anon' then null else '00000000-0000-4000-8000-000000000001'::uuid end $$;
 create function public.get_court_admin_identity_v1() returns jsonb language sql stable as $$ select jsonb_build_object('id','00000000-0000-4000-8000-000000000001','role',case when coalesce(current_setting('test.role',true),'admin')='anon' then 'none' else 'super_admin' end,'username','fixture','display_name','QA') $$;
 create table public.lottery_records(id uuid primary key default gen_random_uuid(),name text,phone text,location_name text,venue_type text,day_of_week text,time_slot text,serial_number text,registered_at timestamptz,id_last4 text,lottery_status text,lottery_locked boolean default false,result_published boolean default false,updated_at timestamptz default now(),member_type text,member_key_hash text,sport_usage text);
 create table public.lottery_capacity_settings(venue_type text,day_of_week text,time_slot text,winner_count int,is_closed boolean default false,updated_at timestamptz default now());
 create table public.admin_operation_logs(admin_id uuid,admin_username text,admin_display_name text,action text,detail jsonb,record_ids text[],created_at timestamptz default now());
 create table public.lottery_registration_qualifications(record_id uuid,review_status text,member_check_status text);
 create function public.list_registration_qualifications_v54() returns table(record_id uuid,review_status text,member_check_status text) language sql as $$ select * from public.lottery_registration_qualifications $$;
 `);
 await db.exec(fs.readFileSync(process.env.COURT_ADJUST_SQL||path.join(__dirname,'../database/court_result_adjustments.sql'),'utf8'));
 async function fixture(){
  await db.exec(`truncate public.lottery_records cascade;truncate public.lottery_registration_qualifications,public.admin_operation_logs,public.lottery_capacity_settings;insert into public.lottery_capacity_settings values ('羽球','周一','10:00-12:00',3,false,now());`);
  const rows=[];
  for(const [serial,status,usage] of [['A','中籤','羽球'],['B','中籤','其他球類'],['C','中籤','其他球類'],['D','候補1','其他球類'],['E','候補2','羽球'],['F','候補3','羽球']]){
   const r=(await db.query(`insert into public.lottery_records(name,phone,location_name,venue_type,day_of_week,time_slot,serial_number,registered_at,lottery_status,member_type,member_key_hash,sport_usage) values ($1,'0900000000','QA','羽球','周一','10:00-12:00',$1,'2026-10-25 12:00+08',$2,'Go會員',$1,$3) returning *`,[serial,status,usage])).rows[0];rows.push(r);
   await db.query(`insert into public.lottery_registration_qualifications values($1,'qualified','verified')`,[r.id]);
  }
  return rows;
 }
 const snapshot=rs=>({capacity:3,records:rs.map(r=>({id:r.id,expected_status:r.lottery_status,expected_updated_at:r.updated_at,expected_version:0}))});
 const change=(r,action)=>({id:r.id,action,expected_status:r.lottery_status,expected_updated_at:r.updated_at,expected_version:0});
 const call=(changes,rows,reason='本場改採羽球用途，依順位遞補')=>db.query('select public.court_adjust_stage_results_v1($1::jsonb,$2,$3::jsonb) result',[JSON.stringify(changes),reason,JSON.stringify(snapshot(rows))]);
 let rows=await fixture();
 let result=await call([change(rows[1],'usage_excluded'),change(rows[2],'usage_excluded'),change(rows[4],'promoted'),change(rows[5],'promoted')],rows);
 assert.equal(result.rows[0].result.updated_count,4);
 assert.equal((await db.query("select count(*)::int n from public.lottery_records where lottery_status='中籤' and sport_usage='羽球'")).rows[0].n,3);
 assert.equal((await db.query('select count(distinct batch_id)::int n from private.court_lottery_result_changes_v1')).rows[0].n,1);
 assert.equal((await db.query("select original_status from private.court_lottery_original_results_v1 where record_id=$1",[rows[4].id])).rows[0].original_status,'候補2');
 console.log('PASS: four result changes saved as one stage transaction, immutable standby rank retained');
 rows=await fixture();
 await assert.rejects(call([change(rows[1],'usage_excluded'),change(rows[4],'promoted')],rows),/用途/);
 assert.equal((await db.query('select count(*)::int n from private.court_lottery_result_changes_v1')).rows[0].n,0);
 assert.equal((await db.query("select count(*)::int n from public.lottery_records where lottery_status='中籤'")).rows[0].n,3);
 console.log('PASS: invalid final usage rolls back every change and audit row');
 rows=await fixture();await db.query('update public.lottery_records set updated_at=updated_at+interval \'1 second\' where id=$1',[rows[0].id]);
 await assert.rejects(call([change(rows[1],'usage_excluded')],rows),/同場次結果已被更新/);
 console.log('PASS: concurrent edit of an unchanged stage row rejects whole snapshot');
 rows=await fixture();await assert.rejects(call([change(rows[1],'usage_excluded'),change(rows[2],'usage_excluded'),change(rows[5],'promoted')],rows),/較前備取/);
 assert.equal((await db.query('select count(*)::int n from private.court_lottery_result_changes_v1')).rows[0].n,0);
 console.log('PASS: skipping earlier compatible standby rolls back all changes');
 rows=await fixture();await assert.rejects(db.query('select public.court_adjust_stage_results_v1($1::jsonb,$2,$3::jsonb)',[JSON.stringify([change(rows[1],'usage_excluded')]),'原因',JSON.stringify({capacity:3})]),/核對資料/);
 await assert.rejects(call([change(rows[1],'usage_excluded')],rows,''),/調整原因/);
 await db.exec("set test.role='anon'");await assert.rejects(call([change(rows[1],'usage_excluded')],rows),/無權/);
 console.log('PASS: missing reasons and unauthorized access rejected');
 await db.close();
});
