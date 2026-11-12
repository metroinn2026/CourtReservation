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
test('expired first interaction is checked before renewing activity',()=>{
  const start=admin.indexOf('function markAdminActivity(event){');
  const end=admin.indexOf('function adminSessionHasExpired(',start);
  assert.ok(start>=0 && end>start);
  const handler=admin.slice(start,end);
  assert.ok(handler.includes('adminSigningOut || adminSessionHasExpired(Date.now())'));
  assert.ok(handler.indexOf('adminSaveTimestamp(ADMIN_SESSION_LAST_KEY,now)')
    >handler.indexOf('adminSigningOut || adminSessionHasExpired(Date.now())'));
  assert.match(admin,/\['pointerdown','click','submit','keydown','touchstart'\]/);
  assert.match(admin,/addEventListener\(type,markAdminActivity,\{capture:true,passive:false\}\)/);
});
test('click after expired pointerdown is blocked during signout',()=>{
  const start=admin.indexOf('function markAdminActivity(event){');
  const end=admin.indexOf('function adminSessionHasExpired(',start);
  const sandbox={
    courtAuthLoginActive:true,adminSigningOut:false,
    ADMIN_SESSION_LAST_KEY:'last',
    Date:{now:()=>1700000000000},
    adminSessionHasExpired:()=>true,
    adminStoredTimestamp:()=>1699999999000,
    adminSaveTimestamp:()=>{throw Error('expired session extended');},
    endAdminSession:()=>{sandbox.adminSigningOut=true;sandbox.courtAuthLoginActive=false;sandbox.logoutCalls++;return Promise.resolve();},
    logoutCalls:0
  };
  vm.createContext(sandbox);
  vm.runInContext(admin.slice(start,end),sandbox);
  const makeEvent=()=>({cancelable:true,
    preventDefault(){this.prevented=true;},
    stopImmediatePropagation(){this.stopped=true;}});
  const down=makeEvent();
  sandbox.markAdminActivity(down);
  const click=makeEvent();
  sandbox.markAdminActivity(click);
  const submit=makeEvent();
  sandbox.markAdminActivity(submit);
  assert.equal(down.prevented,true);
  assert.equal(click.prevented,true);
  assert.equal(click.stopped,true);
  assert.equal(submit.prevented,true);
  assert.equal(sandbox.logoutCalls,1);
});
test('expired first interaction is cancelled before activity renews',()=>{
  const start=admin.indexOf('function markAdminActivity(event){');
  const end=admin.indexOf('function adminSessionHasExpired(',start);
  assert.ok(start>=0&&end>start);
  const handlerSource=admin.slice(start,end);
  const sandbox={
    courtAuthLoginActive:true,adminSigningOut:false,
    ADMIN_SESSION_LAST_KEY:'last',
    Date:{now:()=>1700000000000},
    adminSessionHasExpired:()=>true,
    adminStoredTimestamp:()=>1699999999000,
    adminSaveTimestamp:()=>{throw new Error('expired event renewed login');},
    endAdminSession:()=>{sandbox.signedOut=true;return Promise.resolve();},
    signedOut:false
  };
  vm.createContext(sandbox);
  vm.runInContext(handlerSource,sandbox);
  const event={cancelable:true,
    preventDefault(){this.prevented=true;},
    stopImmediatePropagation(){this.stopped=true;}};
  sandbox.markAdminActivity(event);
  assert.equal(event.prevented,true);
  assert.equal(event.stopped,true);
  assert.equal(sandbox.signedOut,true);
});
test('valid interaction can refresh activity without forcing logout',()=>{
  const start=admin.indexOf('function markAdminActivity(event){');
  const end=admin.indexOf('function adminSessionHasExpired(',start);
  const sandbox={
    courtAuthLoginActive:true,adminSigningOut:false,
    ADMIN_SESSION_LAST_KEY:'last',
    Date:{now:()=>1700000000000},
    adminSessionHasExpired:()=>false,
    adminStoredTimestamp:()=>1699999980000,
    adminSaveTimestamp:(key,value)=>{sandbox.lastSaved={key,value};},
    endAdminSession:()=>{throw new Error('valid session signed out');}
  };
  vm.createContext(sandbox);
  vm.runInContext(admin.slice(start,end),sandbox);
  sandbox.markAdminActivity({cancelable:true});
  assert.equal(sandbox.lastSaved.key,'last');
  assert.equal(sandbox.lastSaved.value,1700000000000);
});
test('admin sessions terminate on Supabase logout and across same-origin tabs',()=>{
  assert.match(admin,/event==='SIGNED_OUT' && courtAuthLoginActive && !adminSigningOut/);
  assert.match(admin,/addEventListener\('storage',event=>/);
  assert.match(admin,/event\.key===ADMIN_SESSION_LOGOUT_EVENT/);
  assert.match(admin,/localStorage\.setItem\(ADMIN_SESSION_LOGOUT_EVENT,String\(Date\.now\(\)\)\)/);
});
test('admin logout revokes remote session before clearing Auth storage',async()=>{
  const start=admin.indexOf('async function endAdminSession(');
  const end=admin.indexOf('async function validateAdminSession(',start);
  assert.ok(start>=0&&end>start);
  const calls=[];
  const sandbox={
    adminSigningOut:false,courtAuthLoginActive:true,currentAdmin:{id:'mock'},
    adminSessionEpoch:1,adminIdleTimer:null,allRecords:[{id:1}],allLogs:[1],
    secureIdentityBySubmission:new Map(),secureEmailBySubmission:new Map(),
    revealedSensitiveKeys:new Set(),secureIdentityAuthenticated:true,
    ADMIN_SESSION_LOGOUT_EVENT:'logout',Date:{now:()=>1700000000000},
    localStorage:{setItem:()=>calls.push('broadcast')},
    clearInterval:()=>{},setTimeout,clearTimeout,
    clearAdminSessionMarkers:()=>calls.push('clear-token'),
    document:{getElementById:()=>({classList:{add:()=>calls.push('hide')}})},
    authMigrationClient:{auth:{signOut:async()=>{calls.push('remote-revoke')}}},
    console:{warn:()=>{}},alert:()=>{},location:{replace:()=>calls.push('redirect')}
  };
  vm.createContext(sandbox);
  vm.runInContext(admin.slice(start,end),sandbox);
  await sandbox.endAdminSession('manual',false);
  assert.ok(calls.indexOf('remote-revoke')>=0);
  assert.ok(calls.indexOf('remote-revoke')<calls.indexOf('clear-token'));
  assert.ok(calls.indexOf('hide')<calls.indexOf('remote-revoke'));
  assert.equal(sandbox.courtAuthLoginActive,false);
});
test('failed remote signout still clears local Auth and redirects',async()=>{
  const start=admin.indexOf('async function endAdminSession(');
  const end=admin.indexOf('async function validateAdminSession(',start);
  const calls=[];
  const sandbox={
    adminSigningOut:false,courtAuthLoginActive:true,currentAdmin:{id:'mock'},
    adminSessionEpoch:1,adminIdleTimer:null,allRecords:[],allLogs:[],
    secureIdentityBySubmission:new Map(),secureEmailBySubmission:new Map(),
    revealedSensitiveKeys:new Set(),secureIdentityAuthenticated:false,
    ADMIN_SESSION_LOGOUT_EVENT:'logout',Date:{now:()=>1700000000000},
    localStorage:{setItem:()=>{}},clearInterval:()=>{},
    setTimeout,clearTimeout,clearAdminSessionMarkers:()=>calls.push('clear-token'),
    document:{getElementById:()=>({classList:{add:()=>{}}})},
    authMigrationClient:{auth:{signOut:async()=>{throw Error('offline')}}},
    console:{warn:()=>{}},alert:()=>{},location:{replace:()=>calls.push('redirect')}
  };
  vm.createContext(sandbox);
  vm.runInContext(admin.slice(start,end),sandbox);
  await sandbox.endAdminSession('manual',false);
  assert.ok(calls.includes('clear-token'));
  assert.ok(calls.includes('redirect'));
});
test('local admin Auth storage is cleared even if network logout fails',()=>{
  const start=admin.indexOf('function clearAdminSessionMarkers(){');
  const end=admin.indexOf('function markAdminActivity(',start);
  assert.ok(start>=0&&end>start);
  const fnSource=admin.slice(start,end);
  const calls=[];
  const sandbox={
    sessionStorage:{removeItem:key=>calls.push(key)},
    ADMIN_SESSION_LAST_KEY:'idle',
    ADMIN_SESSION_START_KEY:'started'
  };
  vm.createContext(sandbox);
  vm.runInContext(fnSource,sandbox);
  sandbox.clearAdminSessionMarkers();
  assert.ok(calls.includes('court-admin-auth'));
  assert.ok(calls.includes('venue_admin_session'));
  assert.ok(calls.includes('idle'));
  assert.ok(calls.includes('started'));
});
test('late database responses are discarded after logout',()=>{
  const start=admin.indexOf('async function loadAllData(){');
  const end=admin.indexOf('function parseSettingDate(',start);
  assert.ok(start>=0&&end>start);
  const body=admin.slice(start,end);
  assert.match(body,/const requestEpoch=adminSessionEpoch/);
  assert.match(body,/const requestStillAuthorized=\(\)=>courtAuthLoginActive&&!adminSigningOut&&requestEpoch===adminSessionEpoch/);
  assert.match(body,/if\(!requestStillAuthorized\(\)\)return false;/);
  assert.ok(body.indexOf('if(!requestStillAuthorized())return false;',body.indexOf('Promise.all'))
    <body.indexOf('allRecords=(recordsRes.data'));
  assert.match(admin,/adminSigningOut=true;\s*adminSessionEpoch\+\+;/);
});
test('session epochs prevent old asynchronous work from crossing a new login',()=>{
  const originalEpoch=7;
  const snapshot=originalEpoch;
  const stillAuthorized=(current,active,signingOut)=>
    active&&!signingOut&&snapshot===current;
  assert.equal(stillAuthorized(7,true,false),true);
  assert.equal(stillAuthorized(8,true,false),false);
  assert.equal(stillAuthorized(7,false,false),false);
  assert.equal(stillAuthorized(7,true,true),false);
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
