const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const src=fs.readFileSync(process.env.COURT_ADMIN_SOURCE||path.join(__dirname,'../admin.html'),'utf8');
const helpers=src.slice(src.indexOf('const resultAdjustmentHistory=new Map();'),src.indexOf('let resultAdjustmentRequest=0;'));
const r=(id,status,extra={})=>({id,serial_number:id,name:id,phone:'0900000'+id,identity:id,lottery_status:status,venue_type:'羽球',sport_usage:'羽球',day_of_week:'周一',time_slot:'10:00-12:00',updated_at:'2026-11-27T10:00:00Z',...extra});
function ctx(records){
 const c=vm.createContext({Map,Set,console,allRecords:records,qualificationReviewsLoaded:true,capacitySettingsLoaded:true,
 isQualifiedForLottery:r=>r.state!=='invalid',sp88RecordStageKey:r=>[r.location_name||'北投會館',r.venue_type,r.day_of_week,r.time_slot].join('|'),getStageCapacity:()=>3,isStageClosed:()=>false,courtUsage:r=>r.sport_usage,
 compactRecordCode:r=>r.id,recordLocation:r=>r.location_name||'北投會館',lotteryTimesOverlap:(a,b)=>a.day_of_week===b.day_of_week&&a.time_slot===b.time_slot,lotteryWinnerRelation:(a,b)=>a.identity===b.identity?'same':'',escapeHtml:s=>String(s)});
 vm.runInContext(helpers+'\nresultAdjustmentHistoryLoaded=true;globalThis.hist=resultAdjustmentHistory;',c);return c;
}
test('paired exclusion and promotion form one request with prior status, timestamp and version',()=>{
 const a=r('A','中籤',{sport_usage:'其他球類'}),b=r('B','候補2'),c=ctx([a,b]);
 const p=c.planResultAdjustment(a,'usage_excluded','B','依同時段同球類規定，採羽球用途');assert.equal(p.changes.length,2);assert.equal(p.changes[0].after,'未中籤');assert.equal(p.changes[1].after,'中籤');assert.equal(p.payload[0].expected_updated_at,a.updated_at);assert.equal(p.payload[1].expected_status,'候補2');assert.equal(p.payload[1].action,'promoted');
});
test('unallocated labels leave qualification and original lottery data distinct',()=>{
 const a=r('A','未中籤'),c=ctx([a]);c.hist.set('A',[{version:1,original_status:'中籤',before_status:'中籤',after_status:'未中籤',action:'time_excluded'}]);assert.equal(c.resultStatusLabel(a),'未獲分配（時段衝突）');assert.equal(c.resultOriginalStatus(a),'中籤');
});
test('promoted label retains original standby rank and version',()=>{
 const a=r('A','中籤'),c=ctx([a]);c.hist.set('A',[{version:2,original_status:'候補7',after_status:'中籤',action:'promoted'}]);assert.equal(c.resultStatusLabel(a),'正取（遞補）');assert.equal(c.resultOriginalStatus(a),'候補7');
});
test('mandatory reason and published guards',()=>{
 const a=r('A','中籤'),c=ctx([a]);assert.throws(()=>c.planResultAdjustment(a,'withdrawn','',''),/填寫/);a.result_published=true;assert.throws(()=>c.planResultAdjustment(a,'withdrawn','','原因'),/取消公布/);
});
test('cannot promote out of order or into overquota stage',()=>{
 const a=r('A','候補1'),b=r('B','候補2'),c=ctx([a,b]);assert.throws(()=>c.planResultAdjustment(b,'promoted','','原因'),/較前順位/);
 c.allRecords=[a,r('W1','中籤'),r('W2','中籤'),r('W3','中籤')];assert.throws(()=>c.planResultAdjustment(a,'promoted','','原因'),/超過名額/);
});
test('usage, cross-stage and membership restrictions are validated on simulated final result',()=>{
 const a=r('A','候補1'),b=r('B','中籤',{sport_usage:'其他球類'}),c=ctx([a,b]);assert.throws(()=>c.planResultAdjustment(a,'promoted','','原因'),/不同用途/);
 c.allRecords=[a,r('C','中籤',{identity:'A',venue_type:'籃球'})];assert.throws(()=>c.planResultAdjustment(a,'promoted','','原因'),/同時段/);
 a.state='invalid';assert.throws(()=>c.planResultAdjustment(a,'promoted','','原因'),/資格/);
});
test('replacement must belong to same stage and does not mutate live data during preview',()=>{
 const a=r('A','中籤'),b=r('B','候補1',{day_of_week:'周二'}),c=ctx([a,b]);assert.throws(()=>c.planResultAdjustment(a,'withdrawn','B','原因'),/場次/);b.day_of_week='周一';const p=c.planResultAdjustment(a,'withdrawn','B','原因');assert.equal(a.lottery_status,'中籤');assert.equal(b.lottery_status,'候補1');assert.equal(p.changes.length,2);
});
test('restore uses immutable original status and requires existing correction history',()=>{
 const a=r('A','未中籤'),c=ctx([a]);assert.throws(()=>c.planResultAdjustment(a,'original','','復原'),/沒有結果調整/);c.hist.set('A',[{version:1,original_status:'候補5',after_status:'未中籤',action:'usage_excluded'}]);assert.equal(c.planResultAdjustment(a,'original','','復原').changes[0].after,'候補5');
});
test('history is cleared on sign-out and feature is present in review workspace',()=>{
 assert(src.includes("data-review-mode=\"results\""));assert(src.includes("rpc('court_adjust_stage_results_v1'"));assert(src.includes('resultAdjustmentHistory.clear();resultAdjustmentHistoryLoaded=false;'));assert(src.includes('結果調整／紀錄'));
});
