const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const src=fs.readFileSync(process.env.COURT_ADMIN_SOURCE||path.join(__dirname,'../admin.html'),'utf8');
const checks=src.slice(src.indexOf('function lotteryTimesOverlap('),src.indexOf('function renderLotteryResultCheckSummary('));
const promote=src.slice(src.indexOf('function getPromotionSuggestions(){'),src.indexOf('function renderPromotionSuggestions(){'));
function setup(records){
 const ctx=vm.createContext({allRecords:records,Map,Set,qualificationReviewsLoaded:true,capacitySettingsLoaded:true,
 personKey:r=>r.identity||r.id,recordLocation:r=>r.location||'北投會館',normalizePhone:p=>String(p||'').replace(/\D/g,''),courtUsage:r=>r.usage||'羽球',
 slotRangeKey:s=>s.replace('11:59','12:00'),getStageCapacity:s=>s.venue==='羽球'?3:1,isStageClosed:()=>false,qualificationState:r=>r.state||'qualified',isQualifiedForLottery:r=>!r.state||r.state==='qualified',
 sp88StageKey:s=>JSON.stringify([s.location,s.venue,s.day,s.time]),});
 vm.runInContext(checks+promote,ctx);return ctx;
}
const r=(id,extra={})=>({id,identity:id,name:'測試'+id,phone:'0900000000',venue_type:'羽球',day_of_week:'周一',time_slot:'10:00-12:00',lottery_status:'中籤',...extra});
test('same identity with overlapping different courts is flagged, adjacent times and different days are not',()=>{
 const c=setup([r('A'),r('B',{identity:'A',venue_type:'籃球',time_slot:'11:00-13:00'}),r('C',{identity:'A',venue_type:'籃球',time_slot:'12:00-14:00'}),r('D',{identity:'A',venue_type:'籃球',day_of_week:'周二'})]).buildLotteryResultChecks();assert.equal(c.cross.length,1);
});
test('shared phone alone does not identify different hall members as same person',()=>{
 const c=setup([r('A'),r('B',{venue_type:'籃球'})]).buildLotteryResultChecks();assert.equal(c.cross.length,0);assert.equal(c.suspected.length,0);
});
test('name and phone match across identities is a suspicion, not confirmed conflict',()=>{
 const c=setup([r('A',{name:'王小明'}),r('B',{name:'王小明',venue_type:'籃球'})]).buildLotteryResultChecks();assert.equal(c.cross.length,0);assert.equal(c.suspected.length,1);
});
test('same venue at different location is also a conflict',()=>assert.equal(setup([r('A'),r('B',{identity:'A',location:'另一場地'})]).buildLotteryResultChecks().cross.length,1));
test('mixed badminton winners are flagged and standby records are included for comparison',()=>{
 const c=setup([r('A'),r('B',{usage:'其他球類'}),r('C',{lottery_status:'候補1'})]).buildLotteryResultChecks();assert.equal(c.usage.length,1);assert.equal(c.usage[0].records.length,3);
});
test('one and two court slots prohibit other usages',()=>{
 const c=setup([r('A',{usage:'其他球類'})]);c.getStageCapacity=()=>2;assert.equal(c.buildLotteryResultChecks().usage.length,1);
});
test('only winners are checked; published winners remain included',()=>{
 const c=setup([r('A',{result_published:true}),r('B',{identity:'A',venue_type:'籃球',result_published:true}),r('C',{identity:'A',venue_type:'B1桌球',lottery_status:'候補1'})]).buildLotteryResultChecks();assert.equal(c.cross.length,1);
});
test('promotion skips incompatible usage and preserves original standby rank',()=>{
 const c=setup([r('A'),r('B'),r('C',{lottery_status:'放棄'}),r('D',{lottery_status:'候補1',usage:'其他球類'}),r('E',{lottery_status:'候補2'})]);
 const s=c.getPromotionSuggestions()[0];assert.equal(s.promote[0].id,'E');assert.equal(s.promote[0].lottery_status,'候補2');assert.equal(s.skipped[0].record.id,'D');
});
test('standby with simultaneous winner blocks promotion until reviewed',()=>{
 const c=setup([r('A'),r('B'),r('C',{lottery_status:'放棄'}),r('D',{identity:'same',lottery_status:'候補1'}),r('E',{identity:'same',venue_type:'籃球'}),r('F',{lottery_status:'候補2'})]);
 const s=c.getPromotionSuggestions()[0];assert.equal(s.promote.length,0);assert(s.blocked.includes('較前順位'));
});
test('empty note prevents all writes, even before refreshing data',async()=>{
 const c=setup([]);let alerts=[],writes=0;c.alert=s=>alerts.push(s);c.updateAuthorizedRecords=()=>writes++;
 const a=src.indexOf('let promotionWriteBusy=false;'),b=src.indexOf('  async function confirmLotteryImport(',a);vm.runInContext(src.slice(a,b),c);
 await c.applyPromotionSuggestion({},' ');assert.equal(writes,0);assert(alerts[0].includes('填寫'));
});
test('manual standby promotion requires reason and dedicated flow',async()=>{
 const c=setup([r('A',{lottery_status:'候補1'})]);
 const a=src.indexOf('async function updateAuthorizedRecords('),b=src.indexOf('async function saveAuthorizedCapacity(',a);vm.runInContext(src.slice(a,b),c);
 const response=await c.updateAuthorizedRecords(['A'],{lottery_status:'中籤'});assert(response.error.message.includes('附遞補說明'));
});
test('confirmed promotion records required explanation and original rank without renumbering remaining standby',async()=>{
 const records=[r('A'),r('B'),r('C',{lottery_status:'放棄'}),r('D',{lottery_status:'候補1'}),r('E',{lottery_status:'候補2'})],c=setup(records);
 let writes=[],logs=[],alerts=[];
 Object.assign(c,{courtAuthLoginActive:true,adminSigningOut:false,adminSessionEpoch:1,currentPage:'test',alert:s=>alerts.push(s),loadAllData:async()=>true,escapeHtml:s=>String(s),compactRecordCode:r=>r.id,confirmModal:async()=>true,
 updateAuthorizedRecords:async(ids,changes,options)=>{writes.push({ids:[...ids],changes,options});return{data:ids.map(id=>({id})),error:null};},writeOperationLog:async(...args)=>logs.push(args)});
 const a=src.indexOf('let promotionWriteBusy=false;'),b=src.indexOf('  async function confirmLotteryImport(',a);vm.runInContext(src.slice(a,b),c);
 await c.applyPromotionSuggestion(c.getPromotionSuggestions()[0],'原正取取消，依原備取順位遞補');
 assert.equal(writes.length,1);assert.deepEqual(writes[0].ids,['D']);assert(writes[0].options.promotionReason);
 assert.equal(logs[0][1].reason,'原正取取消，依原備取順位遞補');assert.equal(logs[0][1].changes[0].before_status,'候補1');
 assert.equal(records[4].lottery_status,'候補2');assert.equal(writes[0].changes.result_published,false);
});
test('preview followed by a new conflicting winner stops promotion',async()=>{
 const records=[r('A'),r('B'),r('C',{lottery_status:'放棄'}),r('D',{identity:'memberD',lottery_status:'候補1'})],c=setup(records);
 let calls=0,writes=0,alerts=[];
 Object.assign(c,{courtAuthLoginActive:true,adminSigningOut:false,adminSessionEpoch:1,currentPage:'test',alert:s=>alerts.push(s),loadAllData:async()=>{calls++;if(calls===2)records.push(r('X',{identity:'memberD',venue_type:'籃球'}));return true;},escapeHtml:s=>String(s),compactRecordCode:r=>r.id,confirmModal:async()=>true,updateAuthorizedRecords:async()=>{writes++;},writeOperationLog:async()=>{}});
 const a=src.indexOf('let promotionWriteBusy=false;'),b=src.indexOf('  async function confirmLotteryImport(',a);vm.runInContext(src.slice(a,b),c);
 await c.applyPromotionSuggestion(c.getPromotionSuggestions()[0],'原正取取消');assert.equal(writes,0);assert(alerts.some(s=>s.includes('資料已變更')));
});
test('purpose-cancelled winner marked not-selected still opens annotated promotion',()=>{
 const c=setup([r('A'),r('B'),r('C',{lottery_status:'未中籤',usage:'其他球類'}),r('D',{lottery_status:'候補1'})]);assert.equal(c.getPromotionSuggestions()[0].promote[0].id,'D');
});
test('incomplete original draw or repeated standby ranks cannot be promoted',()=>{
 const c=setup([r('A'),r('B',{lottery_status:''}),r('C',{lottery_status:'候補1'})]);assert(c.getPromotionSuggestions()[0].blocked.includes('尚未完整'));
 const d=setup([r('A'),r('B',{lottery_status:'候補1'}),r('C',{lottery_status:'候補1'})]);assert(d.getPromotionSuggestions()[0].blocked.includes('順位重複'));
});
