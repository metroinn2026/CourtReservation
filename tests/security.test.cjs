'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const root=path.resolve(__dirname,'..');
const load=name=>fs.readFileSync(path.join(root,name),'utf8');
const policy=require('../admin-session-policy.js');
const admin=load('admin.html');
const front=load('index.html');
const applicant=load('applicant-safe.html');

test('20-minute inactivity requires reauthentication',()=>{
  const now=1700000000000;
  assert.equal(policy.expired(now-19*60000,now),false);
  assert.equal(policy.expired(now-20*60000,now),true);
  assert.equal(policy.expired(now-21*60000,now),true);
  assert.equal(policy.expired(0,now),true);
  assert.equal(policy.expired('garbage',now),true);
});
test('5-minute recheck interval is enforced',()=>{
  const now=1700000000000;
  assert.equal(policy.needsVerification(now-4*60000,now),false);
  assert.equal(policy.needsVerification(now-5*60000,now),true);
  assert.equal(policy.needsVerification(0,now),true);
});
test('maximum login lifetime is eight hours regardless of activity',()=>{
  const now=1700000000000;
  assert.equal(policy.mustReauthenticate(now-7*3600000,now),false);
  assert.equal(policy.mustReauthenticate(now-8*3600000,now),true);
});
test('future timestamps and missing timestamps fail closed',()=>{
  const now=1700000000000;
  assert.equal(policy.expired(now+1000,now),true);
  assert.equal(policy.mustReauthenticate(null,now),true);
});
test('admin uses tab-scoped storage and no service role keys',()=>{
  assert.match(admin,/storage:window\.sessionStorage/);
  assert.doesNotMatch(admin,/sb_secret_|SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(admin,/authMigrationClient\.rpc\('get_court_admin_identity_v1'\)/);
  assert.match(admin,/authMigrationClient\.auth\.getUser\(\)/);
});
test('admin has idle, foreground and role revalidation',()=>{
  assert.match(admin,/function adminSessionHasExpired\(/);
  assert.match(admin,/function beginAdminSession\(/);
  assert.match(admin,/function validateAdminSession\(/);
  assert.match(admin,/function endAdminSession\(/);
  assert.match(admin,/addEventListener\('visibilitychange'/);
  assert.match(admin,/window\.addEventListener\('focus'/);
  assert.match(admin,/if\(!beginAdminSession\(true\)\)/);
  assert.match(admin,/if\(!beginAdminSession\(false\)\)/);
});
test('first click after idle does not extend an expired admin session',()=>{
  const start=admin.indexOf('function markAdminActivity(event){');
  const end=admin.indexOf('function adminSessionHasExpired(',start);
  assert.ok(start>=0 && end>start);
  const handler=admin.slice(start,end);
  assert.ok(handler.indexOf('adminSessionHasExpired(now)')>=0);
  assert.ok(handler.indexOf('adminSaveTimestamp(ADMIN_SESSION_LAST_KEY,now)')>handler.indexOf('adminSessionHasExpired(now)'));
  assert.match(admin,/addEventListener\(type,markAdminActivity,\{capture:true,passive:false\}\)/);
});
test('admin logout clears local identity and masks sensitive UI',()=>{
  assert.match(admin,/clearAdminSessionMarkers\(\)/);
  assert.match(admin,/secureIdentityBySubmission\.clear\(\)/);
  assert.match(admin,/app\.classList\.add\('hidden'\)/);
  assert.match(admin,/auth\.signOut\(\{scope:'local'\}\)/);
});
test('sensitive data updates require authenticated RPC',()=>{
  assert.match(admin,/court_admin_update_records_v1/);
  assert.match(admin,/court_admin_delete_records_v1/);
  assert.match(admin,/court_admin_publish_v1/);
  assert.doesNotMatch(admin,/db\.rpc\('admin_login'/);
  assert.doesNotMatch(admin,/db\.from\(RECORD_TABLE\)\.update\(payload,\{single:true/);
});
test('all inline JavaScript parses without executing or accessing DB',()=>{
  for(const name of ['index.html','admin.html','applicant-safe.html']){
    const html=load(name);
    const scripts=[...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi)];
    assert.ok(scripts.length>0,name);
    for(const [i,m] of scripts.entries())
      assert.doesNotThrow(()=>new vm.Script(m[1],{filename:name+'#'+i}));
  }
});
test('public dynamic text escapes HTML while preserving newlines',()=>{
  const match=front.match(/function frontEscapeHtml\(value\)\{[\s\S]*?function renderSystemTextSettings\(/);
  assert.ok(match);
  const functions=match[0].replace(/function renderSystemTextSettings\($/,'');
  const sandbox={};
  vm.createContext(sandbox);
  vm.runInContext(functions,sandbox);
  assert.equal(sandbox.frontEscapeHtml('<img src=x onerror="alert(1)">'),
               '&lt;img src=x onerror=&quot;alert(1)&quot;&gt;');
  assert.equal(sandbox.frontTextWithBreaks('甲\n乙'),'甲<br>乙');
  assert.match(front,/frontTextWithBreaks\(systemSettings\.register_notice\)/);
  assert.match(front,/frontEscapeHtml\(record\.serial_number/);
});
test('public browser code never includes privileged server keys',()=>{
  for(const name of ['index.html','admin.html','applicant-safe.html']){
    const html=load(name);
    assert.doesNotMatch(html,/sb_secret_|SUPABASE_SERVICE_ROLE_KEY/);
    assert.match(html,/@supabase\/supabase-js@2\.95\.0/);
  }
});
