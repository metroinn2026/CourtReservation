const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const source=fs.readFileSync(process.env.COURT_ADMIN_SOURCE||path.join(__dirname,'../admin.html'),'utf8');
const start=source.indexOf('let exemptApprovalBusy=false;');
const implementation=source.slice(start,source.indexOf('function renderLotteryPage(){',start));
function setup(records,options={}){
 const logs=[],writes=[],messages=[];let loads=0,confirms=0;
 const stage={location:'北投會館',venue:'羽球',day:'周一',time:'06:00-08:00',records};
 const ctx=vm.createContext({console,Map,Set,Date,
 qualificationReviewsLoaded:true,capacitySettingsLoaded:true,capacityMap:{'羽球':3},
 qualificationState:r=>r.state||'qualified',getStageCapacity:()=>options.capacity??3,isStageClosed:()=>!!options.closed,
 personKey:r=>r.identity||r.id,courtUsage:r=>r.usage||'羽球',sp88StageKey:()=> 'stage-one',
 compactRecordCode:r=>r.serial_number||r.id,escapeHtml:s=>String(s),locationLabel:s=>s,
 courtAuthLoginActive:true,adminSigningOut:false,adminSessionEpoch:1,backupBusy:false,backupDrafts:new Map(),currentPage:'lottery',
 backupStages:()=>[stage],loadAllData:async()=>{loads++;if(options.onLoad)options.onLoad(loads,records);return true;},
 confirmModal:async(title,body)=>{confirms++;messages.push(body);return options.confirm!==false;},
 updateAuthorizedRecords:async(ids,changes,guards)=>{writes.push({ids:[...ids],changes,guards});return options.failure?{data:[],error:Error('fixture failure')}:{data:ids.map(id=>({id})),error:null};},
 writeOperationLog:async(...args)=>logs.push(args),alert:s=>messages.push(s),renderLotteryPage:()=>{},
 });
 vm.runInContext(implementation,ctx);
 return {ctx,stage,logs,writes,messages,run:()=>ctx.approveExemptStages(['stage-one']),plan:()=>ctx.buildExemptApprovalPlan(stage),get confirms(){return confirms;}};
}
const row=(id,extra={})=>({id,serial_number:id,name:'測試人員',lottery_status:'',result_published:false,lottery_locked:false,...extra});
test('below capacity: qualified only; invalid records do not become winners',async()=>{
 const a=setup([row('A'),row('B'),row('C',{state:'invalid'})]);
 await a.run();assert.equal(a.writes.length,1);assert.deepEqual(a.writes[0].ids,['A','B']);
 assert.equal(a.writes[0].changes.lottery_status,'中籤');assert.equal(a.writes[0].changes.result_published,false);
 assert.equal(a.writes[0].changes.lottery_locked,true);assert.equal(a.writes[0].guards.expectUnpublished,true);assert.equal(a.writes[0].guards.expectUnlocked,true);
 assert.equal(a.logs[0][0],'免抽籤場次核定正取');assert.equal(a.confirms,1);
});
test('exact capacity can approve; no need to fill unused quota',()=>{
 assert.equal(setup([row('A'),row('B'),row('C')]).plan().reason,'');
 assert.equal(setup([row('A')]).plan().targets.length,1);
});
test('existing winner is retained and only blanks are written',async()=>{
 const a=setup([row('A',{lottery_status:'中籤',lottery_locked:true}),row('B')]);await a.run();assert.deepEqual(a.writes[0].ids,['B']);
});
test('cancel preview never writes',async()=>{const a=setup([row('A')],{confirm:false});await a.run();assert.equal(a.writes.length,0);});
test('overquota and pending qualification are blocked',()=>{
 assert.match(setup([row('A'),row('B')],{capacity:1}).plan().reason,/超過/);
 assert.match(setup([row('A'),row('B',{state:'pending'})]).plan().reason,/待審查/);
});
test('published, locked blank and existing waitlist are not overwritten',()=>{
 for(const extra of [{result_published:true},{lottery_locked:true},{lottery_status:'候補1'}])assert(setup([row('A',extra)]).plan().reason);
});
test('duplicate or unverified identity cannot take multiple places',()=>{
 assert.match(setup([row('A',{identity:'same'}),row('B',{identity:'same'})]).plan().reason,/會員識別/);
 assert.match(setup([row('A',{identity:'UNVERIFIED:A'})]).plan().reason,/會員識別/);
});
test('closed and mixed-use badminton stages require review',()=>{
 assert(setup([row('A')],{closed:true}).plan().reason);
 assert.match(setup([row('A'),row('B',{usage:'匹克球'})]).plan().reason,/不同使用球類/);
 assert.match(setup([row('A',{usage:'匹克球'})],{capacity:2}).plan().reason,/非三面/);
});
test('ineligible existing result requires review',()=>assert.match(setup([row('A'),row('B',{state:'invalid',lottery_status:'中籤'})]).plan().reason,/不合格/));
test('post-preview data change stops all writes',async()=>{
 const a=setup([row('A')],{onLoad:(n,records)=>{if(n===2)records[0].lottery_status='候補1';}});
 await a.run();assert.equal(a.writes.length,0);assert(a.messages.some(s=>s.includes('已異動')));
});
test('server failure logs the batch and does not report success',async()=>{
 const a=setup([row('A')],{failure:true});await a.run();assert.equal(a.logs[0][0],'免抽籤場次核定異常');assert(a.messages.some(s=>s.includes('未全部完成')));
});
test('UI provides per-stage and visible-filter bulk approval',()=>{
 assert(source.includes('id="approveVisibleExemptStages"'));
 assert(source.includes('class="btn btn-primary approve-exempt-stage"'));
 assert(source.includes("visibleStages.filter(s=>s.progress==='exempt_pending').map(s=>sp88StageKey(s))"));
});
test('bulk processes each eligible stage and shows skipped stages in preview',async()=>{
 const a=setup([row('A')]);
 const other={...a.stage,key:'stage-two',records:[row('B'),row('C'),row('D'),row('E')]};
 a.ctx.sp88StageKey=s=>s.key||'stage-one';a.ctx.backupStages=()=>[a.stage,other];
 await a.ctx.approveExemptStages(['stage-one','stage-two']);
 assert.equal(a.writes.length,1);assert(a.messages.some(s=>s.includes('以下 1 場不處理')));
});
test('bulk writes all eligible stages and logs all updated IDs',async()=>{
 const a=setup([row('A')]);
 const other={...a.stage,key:'stage-two',records:[row('B')]};
 a.ctx.sp88StageKey=s=>s.key||'stage-one';a.ctx.backupStages=()=>[a.stage,other];
 await a.ctx.approveExemptStages(['stage-one','stage-two']);
 assert.equal(a.writes.length,2);assert.equal(a.logs[0][1].stage_count,2);assert.deepEqual([...a.logs[0][2]],['A','B']);
});
