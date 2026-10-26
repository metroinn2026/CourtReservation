import { PGlite } from '@electric-sql/pglite';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
import { before, after, beforeEach, test } from 'node:test';

const db = new PGlite();
const admin = '00000000-0000-0000-0000-000000000001';
const root = new URL('../', import.meta.url);
before(async () => {
  await db.exec(await readFile(new URL('tests/fixtures/schema.sql', root), 'utf8'));
  for (const file of ['v16_registration_unique_index_migration.sql', 'v16_import_existing_submissions_STAGING.sql', 'v16_reconcile_all_imports_STAGING.sql', 'v33_form_import_PRODUCTION_READY.sql']) {
    try { await db.exec(await readFile(new URL('sql/' + file, root), 'utf8')); }
    catch (e) { throw new Error(`${file}: ${e.message} at ${e.position || ''} ${e.where || ''}`); }
  }
});
after(async () => { await db.close(); });
beforeEach(async () => {
  await db.exec('RESET ROLE; TRUNCATE public.lottery_capacity_settings, public.lottery_import_audit, public.lottery_import_anomalies, public.lottery_records, public.lottery_form_submissions, public.lottery_form_import_batches CASCADE;');
  await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [admin]);
});

function payload({ key = randomUUID(), stamp = '2026-10-01T08:00:00+08:00', id = 'A123456789', phone = '0912345678', slots = [['羽球','周一','08:00-09:00','羽球']] } = {}) {
  const sub = { submission_key: key, submitted_at: stamp, member_type: '北投會館會員',
    member_identifier: id, name: '合成會員', phone, email: 'synthetic@example.invalid', raw_payload: {}, excel_row: 2 };
  return { batch_key: randomUUID(), submissions: [sub], anomalies: [], records: slots.map(([venue,day,time,usage], i) => ({
    submission_key: key, record_key: key + '-' + i, member_type: sub.member_type,
    name: sub.name, phone, member_identifier_last4: id.slice(-4), id_last4: 'FAKE',
    venue_type: venue, sport_usage: usage || (venue.includes('桌球') ? '桌球' : venue), day_of_week: day, time_slot: time, serial_number: 'GF-' + key + '-' + i,
    location_name: '北投會館', registered_at: '2099-01-01T00:00:00Z'
  })) };
}
const importBatch = async p => (await db.query('SELECT public.import_google_form_batch($1::jsonb) AS result', [JSON.stringify(p)])).rows[0].result;
const reconcile = async () => db.query('SELECT public.court_v16_reconcile_import_anomalies()');
const anomalies = async () => (await db.query('SELECT * FROM public.lottery_import_anomalies ORDER BY created_at,id')).rows;
const count = async table => Number((await db.query('SELECT count(*) AS n FROM public.' + table)).rows[0].n);
const resolve = async (id, status) => db.query('SELECT public.resolve_google_form_anomaly($1::uuid,$2)', [id,status]);
const eligibility = async () => (await db.query('SELECT public.court_v16_lottery_eligibility() AS state')).rows[0].state;
const commit = async (rows, snapshot) => (await db.query('SELECT public.court_v16_commit_lottery_results($1::jsonb,$2,$3) AS result', [JSON.stringify(rows),snapshot,'synthetic-draw'])).rows[0].result;

test('candidate SQL installs; independent sports and server-derived source fields', async () => {
  const p = payload({slots:[['羽球','周一','08:00-09:00','匹克球'],['籃球','周一','10:00-12:00','籃球']]});
  assert.equal((await importBatch(p)).inserted_records,2);
  await reconcile();
  assert.equal((await anomalies()).length,0);
  const rows = (await db.query('SELECT id_last4, registered_at, sport_usage FROM public.lottery_records')).rows;
  assert.ok(rows.every(r => r.id_last4 === '6789'));
  assert.ok(rows.every(r => new Date(r.registered_at).getFullYear() === 2026));
  assert.deepEqual(new Set(rows.map(r => r.sport_usage)), new Set(['匹克球','籃球']));
});

test('venue and sport usage mismatch is rejected atomically', async () => {
  await assert.rejects(importBatch(payload({slots:[['羽球','周一','08:00-10:00','籃球']]})),/場地與運動用途不一致/);
  assert.equal(await count('lottery_form_submissions'),0);
  assert.equal(await count('lottery_records'),0);
});
test('replay is idempotent and restores missing records without deleting submissions', async () => {
  const p = payload(); await importBatch(p);
  assert.equal((await importBatch(p)).inserted_records,0);
  await db.exec('DELETE FROM public.lottery_records'); // local synthetic fixture only
  assert.equal((await importBatch(p)).inserted_records,1);
  assert.equal(await count('lottery_form_submissions'),1);
  assert.equal(await count('lottery_records'),1);
  assert.equal((await db.query('SELECT record_count FROM public.lottery_form_import_batches')).rows[0].record_count,1);
});
test('conflicting replay rolls back atomically', async () => {
  const p = payload(); await importBatch(p);
  const changed = structuredClone(p); changed.batch_key = randomUUID(); changed.submissions[0].phone = '0999999999';
  await assert.rejects(importBatch(changed), /submission_key/);
  assert.equal(await count('lottery_form_import_batches'),1);
  assert.equal(await count('lottery_records'),1);
});
test('later batch imported first still loses to earlier submission', async () => {
  const later = payload({stamp:'2026-10-02T08:00:00+08:00'});
  const earlier = payload();
  await importBatch(later); await reconcile();
  await importBatch(earlier); await reconcile();
  const a = await anomalies();
  assert.equal(a.length,1); assert.deepEqual(a[0].record_keys,[later.records[0].record_key]);
});
test('same response overlapping sports creates separate review items', async () => {
  await importBatch(payload({slots:[['羽球','周一','08:00-09:00'],['籃球','周一','08:00-10:00']]}));
  await reconcile();
  const a = await anomalies(); assert.equal(a.length,2);
  assert.ok(a.every(x => x.record_keys.length === 1 && x.resolution_status === 'pending'));
  await resolve(a[0].id,'invalid'); await resolve(a[1].id,'valid');
  assert.equal((await anomalies()).filter(x => x.resolution_status === 'pending').length,0);
});
test('equal timestamps across separate replies require both reviewed', async () => {
  await importBatch(payload()); await importBatch(payload()); await reconcile();
  assert.equal((await anomalies()).filter(a => a.anomaly_type.includes('同時間提交')).length,2);
});
test('different members sharing a phone and slot are not conflicts', async () => {
  await importBatch(payload()); await importBatch(payload({id:'B123456789'})); await reconcile();
  assert.equal((await anomalies()).length,0);
});
test('table tennis distinct slots allowed, repeated same slot retained and flagged', async () => {
  await importBatch(payload({slots:[['B1桌球','周一','08:00-09:00'],['B1桌球','周一','10:00-11:00']]}));
  await importBatch(payload({stamp:'2026-10-02T08:00:00+08:00',slots:[['B1桌球','周一','08:00-09:00']]}));
  await reconcile(); assert.equal(await count('lottery_records'),3); assert.equal((await anomalies()).length,1);
});
test('non-allowlisted authenticated user cannot import or reconcile', async () => {
  await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)",[randomUUID()]);
  await db.exec('SET ROLE authenticated');
  await assert.rejects(importBatch(payload()),/not authorized/);
  await assert.rejects(reconcile(),/not authorized/);
});
test('anon has no execute privilege on administrative functions', async () => {
  await db.exec('SET ROLE anon');
  await assert.rejects(importBatch(payload()),/permission denied/);
  await assert.rejects(reconcile(),/permission denied/);
});
test('invalid slot causes full transaction rollback', async () => {
  await assert.rejects(importBatch(payload({slots:[['羽球','周一','25:00-26:00']]})),/時段/);
  assert.equal(await count('lottery_form_submissions'),0);
  assert.equal(await count('lottery_form_import_batches'),0);
});

test('import classifies cross-batch conflicts without a second browser RPC', async () => {
  await importBatch(payload());
  await importBatch(payload({stamp:'2026-10-02T08:00:00+08:00'}));
  assert.equal((await anomalies()).length,1);
  await assert.rejects(eligibility(),/異常待人工確認/);
});
test('manual valid cannot allow two conflicting registrations into the draw', async () => {
  await importBatch(payload({slots:[['羽球','周一','08:00-09:00'],['羽球','周二','10:00-11:00']]}));
  const a=await anomalies();
  for(const x of a) await resolve(x.id,'valid');
  await assert.rejects(eligibility(),/仍有會員名額或時段衝突/);
  await resolve(a[0].id,'invalid');
  assert.equal((await eligibility()).records.filter(r=>r.eligible).length,1);
});
test('authorized result RPC commits a complete stage atomically with audit', async () => {
  await importBatch(payload()); await importBatch(payload({id:'B123456789'}));
  await db.exec('SET ROLE authenticated');
  const e=await eligibility();
  const rows=e.records.map((r,i)=>({id:r.id,status:i===0?'中籤':'候補1'}));
  assert.equal((await commit(rows,e.snapshot)).updated_count,2);
  await db.exec('RESET ROLE');
  assert.equal((await db.query("SELECT count(*)::integer AS n FROM public.lottery_records WHERE lottery_locked AND NOT result_published")).rows[0].n,2);
  assert.equal((await db.query("SELECT count(*)::integer AS n FROM public.lottery_import_audit WHERE action='commit_lottery_results'")).rows[0].n,2);
});
test('unknown fields, duplicate IDs, invalid records and partial stages are rejected', async () => {
  await importBatch(payload()); await importBatch(payload({id:'B123456789'}));
  const e=await eligibility(), id=e.records[0].id;
  await assert.rejects(commit([{id,status:'中籤',result_published:true}],e.snapshot),/invalid result fields/);
  await assert.rejects(commit([{id,status:'中籤'},{id,status:'未中籤'}],e.snapshot),/duplicate IDs/);
  await assert.rejects(commit([{id:randomUUID(),status:'中籤'}],e.snapshot),/不存在/);
  await assert.rejects(commit([{id,status:'中籤'}],e.snapshot),/未涵蓋/);
  assert.equal((await db.query('SELECT count(*)::integer AS n FROM public.lottery_records WHERE lottery_locked')).rows[0].n,0);
});
test('snapshot rejects data changed after preview and leaves all results untouched', async () => {
  await importBatch(payload()); const e=await eligibility();
  await importBatch(payload({id:'B123456789'}));
  await assert.rejects(commit(e.records.map(r=>({id:r.id,status:'中籤'})),e.snapshot),/已變更/);
  assert.equal((await db.query('SELECT count(*)::integer AS n FROM public.lottery_records WHERE lottery_locked')).rows[0].n,0);
});
test('result RPC rejects over-capacity and discontinuous waitlist ranks', async () => {
  await importBatch(payload()); await importBatch(payload({id:'B123456789'}));
  await db.exec("INSERT INTO public.lottery_capacity_settings(venue_type,day_of_week,time_slot,winner_count) VALUES ('羽球','周一','08:00',1)");
  const e=await eligibility();
  await assert.rejects(commit(e.records.map(r=>({id:r.id,status:'中籤'})),e.snapshot),/超過名額/);
  await assert.rejects(commit(e.records.map((r,i)=>({id:r.id,status:i?'候補2':'中籤'})),e.snapshot),/不連續/);
});
test('anon and unlisted users cannot use result or eligibility APIs', async () => {
  await db.exec('SET ROLE anon');
  await assert.rejects(eligibility(),/permission denied/);
  await assert.rejects(commit([],''),/permission denied/);
  await db.exec('RESET ROLE; SET ROLE authenticated');
  await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)",[randomUUID()]);
  await assert.rejects(eligibility(),/not authorized/);
  await assert.rejects(commit([],''),/not authorized/);
});
test('more than 1000 anomalies cannot hide a pending item', async () => {
  await importBatch(payload());
  await db.exec("INSERT INTO public.lottery_import_anomalies(anomaly_type,resolution_status) SELECT 'synthetic historical review','valid' FROM generate_series(1,1001); INSERT INTO public.lottery_import_anomalies(anomaly_type) VALUES ('synthetic pending')");
  await assert.rejects(eligibility(),/異常待人工確認/);
});
test('closed stage rejects every result without partial writes', async () => {
  await importBatch(payload());
  await db.exec("INSERT INTO public.lottery_capacity_settings(venue_type,day_of_week,time_slot,winner_count,is_closed) VALUES ('羽球','周一','08:00',3,true)");
  const e=await eligibility();
  await assert.rejects(commit(e.records.map(r=>({id:r.id,status:'中籤'})),e.snapshot),/未開放/);
  assert.equal((await db.query('SELECT lottery_status FROM public.lottery_records')).rows[0].lottery_status,null);
});
test('source mismatch fails closed and never trusts client-side member identity', async () => {
  await importBatch(payload());
  await db.exec("UPDATE public.lottery_records SET member_key_hash='forged'");
  await assert.rejects(eligibility(),/會員識別/);
});
test('failure in reconciliation rolls back the entire import', async () => {
  await db.exec("CREATE OR REPLACE FUNCTION public.court_v16_reconcile_import_anomalies() RETURNS jsonb LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic reconciliation failure'; END; $$");
  try {
    await assert.rejects(importBatch(payload()),/synthetic reconciliation failure/);
    assert.equal(await count('lottery_form_submissions'),0);
    assert.equal(await count('lottery_records'),0);
    assert.equal(await count('lottery_form_import_batches'),0);
  } finally {
    await db.exec(await readFile(new URL('sql/v16_reconcile_all_imports_STAGING.sql',root),'utf8'));
  }
});
test('production importer remains usable when optional reconciler is not installed', async () => {
  await db.exec('ALTER FUNCTION public.court_v16_reconcile_import_anomalies() RENAME TO court_v16_reconcile_import_anomalies_temporarily_disabled');
  try {
    const result = await importBatch(payload());
    assert.equal(result.inserted_records, 1);
    assert.equal(result.reconciliation_performed, false);
    assert.equal(await count('lottery_records'), 1);
  } finally {
    await db.exec('ALTER FUNCTION public.court_v16_reconcile_import_anomalies_temporarily_disabled() RENAME TO court_v16_reconcile_import_anomalies');
  }
});
test('sensitive raw identity fields are stripped before persistence', async () => {
  const p=payload();p.submissions[0].raw_payload={'北投會館會員身分證字號（10碼）':'A123456789','台北捷運Go App會員綁定手機（10碼）':'0912345678',member_identifier:'A123456789',safe:'example'};
  await importBatch(p);
  const s=(await db.query('SELECT member_identifier,raw_payload FROM public.lottery_form_submissions')).rows[0];
  assert.equal(s.member_identifier,'6789');assert.deepEqual(s.raw_payload,{safe:'example'});
});
