const assert = require('node:assert/strict');
const {test} = require('node:test');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../admin.html'),'utf8');
function section(start,end){
  const i=html.indexOf(start),j=html.indexOf(end,i+start.length);
  assert.ok(i>=0&&j>i,`missing ${start}`);return html.slice(i,j);
}
function setup(records,state){
  const calls=[];
  const context={allRecords:records,importDb:{auth:{getUser:async()=>({data:{user:{id:'admin'}}})},
    rpc:async(name,args)=>{calls.push({name,args});return {data:name==='court_v16_lottery_eligibility'?state:{updated_count:args.p_rows.length}};}}};
  vm.createContext(context);
  vm.runInContext(section('async function getLotteryEligibility(){','async function verifyFormAnomaliesForLotteryExport'),context);
  return {context,calls};
}
const row={id:'1',import_record_key:'rk',member_key_hash:'hash',location_name:'北投會館',venue_type:'羽球',day_of_week:'周一',time_slot:'08:00-09:00'};
const server={...row,record_key:'rk',eligible:true,lottery_status:'',lottery_locked:false,result_published:false};
test('all inline frontend and admin scripts compile',()=>{
  for(const filename of ['admin.html','index.html']){
    const source=fs.readFileSync(path.join(__dirname,'..',filename),'utf8');
    for(const match of source.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi))new vm.Script(match[1],{filename});
  }
});
test('eligibility uses authoritative server keys and retains snapshot',async()=>{
  const {context}=setup([row],{records:[server],snapshot:'s1'});
  const eligible=await context.getLotteryEligibility();
  assert.equal(eligible(row),true);assert.equal(eligible({id:'other'}),false);assert.equal(eligible.snapshot,'s1');
});
test('invalid records are excluded and incomplete local data is blocked',async()=>{
  const a=setup([row],{records:[{...server,eligible:false}],snapshot:'s1'});
  assert.equal((await a.context.getLotteryEligibility())(row),false);
  const b=setup([],{records:[server],snapshot:'s1'});
  await assert.rejects(b.context.getLotteryEligibility(),/筆數/);
});
test('stale stage or membership data cannot use a fresh snapshot',async()=>{
  for(const field of ['member_key_hash','time_slot','venue_type']){
    const {context}=setup([{...row,[field]:'changed'}],{records:[server],snapshot:'s1'});
    await assert.rejects(context.getLotteryEligibility(),/內容已變更/);
  }
});
test('atomic result client only sends allowlisted fields to Auth RPC',async()=>{
  const {context,calls}=setup([row],{records:[server],snapshot:'s1'});
  assert.equal(await context.commitLotteryResults([{id:'1',status:'中籤',phone:'secret'}],'s1','test'),1);
  assert.equal(calls[0].name,'court_v16_commit_lottery_results');
  assert.equal(JSON.stringify(calls[0].args.p_rows),'[{"id":"1","status":"中籤"}]');
});
test('pagination loads beyond the Data API default row cap',async()=>{
  const data=Array.from({length:1201},(_,i)=>({id:String(i)}));
  const context={RECORD_TABLE:'records',db:{from:()=>({select(){return this;},order(){return this;},range:async(a,b)=>({data:data.slice(a,b+1),count:data.length})})}};
  vm.createContext(context);vm.runInContext(section('async function loadAllRegistrationRows(){','async function loadAllData(){'),context);
  assert.equal((await context.loadAllRegistrationRows()).data.length,1201);
});
test('unexpected truncation is an error, never a partial draw list',async()=>{
  const context={RECORD_TABLE:'records',db:{from:()=>({select(){return this;},order(){return this;},range:async()=>({data:[{id:'1'}],count:1201})})}};
  vm.createContext(context);vm.runInContext(section('async function loadAllRegistrationRows(){','async function loadAllData(){'),context);
  const r=await context.loadAllRegistrationRows();assert.equal(r.data,null);assert.match(r.error.message,/不完整/);
});
test('four initial result paths call atomic RPC instead of direct per-row updates',()=>{
  assert.ok(html.includes('snapshot:eligible.snapshot,sourceIds:'));
  assert.equal((html.match(/await commitLotteryResults\(/g)||[]).length,4);
  assert.ok(!html.includes("update({lottery_status:item.status"));
});
