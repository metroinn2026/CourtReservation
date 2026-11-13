'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const moduleText=fs.readFileSync(path.join(__dirname,'../admin-mfa.js'),'utf8');
const admin=fs.readFileSync(path.join(__dirname,'../admin.html'),'utf8');
function setup(){
  const nodes=new Map();
  const get=id=>{
    if(!nodes.has(id)){
      const state={id,value:'',hidden:false,disabled:false,children:[],focused:false};
      state.classList={toggle:(_name,off)=>{state.hidden=!!off;}};
      state.replaceChildren=()=>{state.children=[];};
      state.appendChild=child=>{state.children.push(child);if(!state.value)state.value=child.value;};
      state.focus=()=>{state.focused=true;};
      nodes.set(id,state);
    }
    return nodes.get(id);
  };
  const document={
    getElementById:get,
    createElement:tag=>({tag,value:'',textContent:''})
  };
  const root={};
  vm.runInNewContext(moduleText,{window:root,document,console,encodeURIComponent});
  return {api:root.CourtAdminMfa,get};
}
test('MFA module is valid JavaScript and validates six-digit codes',()=>{
  assert.doesNotThrow(()=>new vm.Script(moduleText));
  const {api}=setup();
  assert.equal(api.sixDigits('123456'),true);
  assert.equal(api.sixDigits('000000'),true);
  assert.equal(api.sixDigits(' 123456 '),true);
  assert.equal(api.sixDigits('12345'),false);
  assert.equal(api.sixDigits('1234567'),false);
  assert.equal(api.sixDigits('<script>'),false);
});
test('password-only accounts keep legacy sign-in without MFA prompt',async()=>{
  const {api,get}=setup();
  const client={auth:{mfa:{
    getAuthenticatorAssuranceLevel:async()=>({data:{currentLevel:'aal1',nextLevel:'aal1'},error:null})
  }}};
  api.init(client,async()=>{},async()=>{});
  const challengeRequired=await api.gate(false);
  assert.equal(challengeRequired,false);
  assert.equal(get('adminMfaLoginBox').hidden,true);
  assert.equal(get('loginBox').hidden,false);
});
test('enrolled account is held at challenge until correct TOTP submitted',async()=>{
  const {api,get}=setup();
  const calls=[];
  let aal='aal1';
  const client={auth:{mfa:{
    getAuthenticatorAssuranceLevel:async()=>({data:{currentLevel:aal,nextLevel:'aal2'},error:null}),
    listFactors:async()=>({data:{totp:[{id:'totp-1',status:'verified'}]},error:null}),
    challenge:async p=>{calls.push(['challenge',p.factorId]);return{data:{id:'challenge-1'},error:null};},
    verify:async p=>{calls.push(['verify',p.code,p.factorId,p.challengeId]);aal='aal2';return{data:{},error:null};}
  }}};
  let entered=0,restoredWas=null;
  api.init(client,async restored=>{entered++;restoredWas=restored;},async()=>{});
  assert.equal(await api.gate(true),true);
  assert.equal(entered,0);
  assert.equal(get('loginBox').hidden,true);
  assert.equal(get('adminMfaLoginBox').hidden,false);
  get('adminMfaLoginCode').value='123456';
  await get('adminMfaVerifyBtn').onclick();
  assert.deepEqual(calls,[['challenge','totp-1'],['verify','123456','totp-1','challenge-1']]);
  assert.equal(entered,1);
  assert.equal(restoredWas,true);
  assert.equal(get('adminMfaLoginBox').hidden,true);
});
test('wrong TOTP does not enter admin console',async()=>{
  const {api,get}=setup();
  const client={auth:{mfa:{
    getAuthenticatorAssuranceLevel:async()=>({data:{currentLevel:'aal1',nextLevel:'aal2'},error:null}),
    listFactors:async()=>({data:{totp:[{id:'totp-1',status:'verified'}]},error:null}),
    challenge:async()=>({data:{id:'challenge-1'},error:null}),
    verify:async()=>({data:null,error:new Error('驗證碼錯誤')})
  }}};
  let entered=false;
  api.init(client,async()=>{entered=true;},async()=>{});
  await api.gate(false);
  get('adminMfaLoginCode').value='654321';
  await get('adminMfaVerifyBtn').onclick();
  assert.equal(entered,false);
  assert.match(get('adminMfaLoginMsg').textContent,/驗證碼錯誤/);
});
test('MFA service failures fail closed',async()=>{
  const {api}=setup();
  api.init({auth:{mfa:{
    getAuthenticatorAssuranceLevel:async()=>({data:null,error:new Error('network error')})
  }}},async()=>{throw Error('must not enter');},async()=>{});
  await assert.rejects(api.gate(false),/network error/);
});
test('normal and restored sign-in both challenge before administrator RPC',()=>{
  assert.match(admin,/<script src="\/admin-mfa\.js"><\/script>/);
  const login=admin.slice(admin.indexOf('async function loginWithCourtAuth(){'),admin.indexOf('async function deleteCourtRecords(',admin.indexOf('async function loginWithCourtAuth(){')));
  assert.ok(login.indexOf('CourtAdminMfa.gate(false)')<login.indexOf('completeAdminSignIn(false)'));
  const init=admin.slice(admin.indexOf('(async function init(){'));
  assert.ok(init.indexOf('CourtAdminMfa.gate(true)')<init.indexOf('completeAdminSignIn(true)'));
  assert.match(admin,/CourtAdminMfa\?\.closeSettings\?\.\(\)/);
});
test('MFA enrollment never persists QR secrets or OTP codes in browser storage',()=>{
  assert.match(moduleText,/auth\.mfa\.enroll\(\{factorType:'totp'\}\)/);
  assert.match(moduleText,/auth\.mfa\.challenge\(/);
  assert.match(moduleText,/auth\.mfa\.verify\(/);
  assert.match(moduleText,/state\.pendingId=null;/);
  assert.doesNotMatch(moduleText,/localStorage\./);
  assert.doesNotMatch(moduleText,/sessionStorage\./);
});
