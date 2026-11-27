const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(process.env.COURT_ADMIN_SOURCE||path.join(__dirname,'../admin.html'),'utf8');
test('all result-check view buttons navigate directly to matching review filter without opening a modal',()=>{
 const calls=[],buttons=['usage','cross','suspected'].map(kind=>({dataset:{lotteryCheck:kind}}));
 const c=vm.createContext({recordState:{q:'old',location:'北投會館',usage:'羽球'},reviewWorkMode:'qualification',recordsActionTab:'filter',resultAdjustmentFocusId:'old',resultAdjustmentPage:9,resultAdjustmentFilter:'all',resultAdjustmentScrollPending:false,
 clearRecordFilters(){c.recordState={q:'',location:'北投會館',usage:''};},renderPage:page=>calls.push(page),showLotteryResultChecks:()=>{throw Error('intermediate modal must not open');}});
 const start=source.indexOf('function openLotteryResultAdjustmentFilter('),end=source.indexOf('function openLotteryResultStage(',start);vm.runInContext(source.slice(start,end),c);
 c.bindLotteryResultCheckActions({querySelectorAll:()=>buttons});
 for(const button of buttons){button.onclick();assert.equal(c.resultAdjustmentFilter,button.dataset.lotteryCheck);assert.equal(c.reviewWorkMode,'results');assert.equal(c.recordsActionTab,'review');assert.equal(c.resultAdjustmentFocusId,'');assert.equal(c.resultAdjustmentPage,1);assert.equal(c.recordState.q,'');assert.equal(c.recordState.usage,'');assert.equal(c.recordState.location,'');assert.equal(c.resultAdjustmentScrollPending,true);}
 assert.deepEqual(calls,['records','records','records']);
});
test('category filter includes complete matching stages and excludes unrelated conflicts',()=>{
 const row=(id,venue,day='周一')=>({id,venue_type:venue,day_of_week:day,time_slot:'10:00-12:00',lottery_status:'中籤'});
 const a=row('A','羽球'),b=row('B','羽球'),c=row('C','籃球'),d=row('D','B1桌球'),e=row('E','羽球','周二');
 b.lottery_status='候補1';const records=[a,b,c,d,e];
 const key=r=>[r.venue_type,r.day_of_week,r.time_slot].join('|');
 const ctx=vm.createContext({allRecords:records,resultAdjustmentHistory:new Map(),sp88RecordStageKey:key,
 buildLotteryResultChecks:()=>({usage:[{records:[a]}],cross:[{records:[c,d]}],suspected:[{records:[e]}]}),getStageCapacity:()=>3,
 lotteryResultStageGroups:rows=>[...new Set(rows.map(key))].map(k=>({key:k,records:rows.filter(r=>key(r)===k),venue:rows.find(r=>key(r)===k).venue_type,day:'周一',time:'10:00-12:00',location:'北投會館'})),venueSortValue:()=>0,daySortValue:()=>0,timeSortValue:()=>0});
 const start=source.indexOf('function buildResultAdjustmentStages('),end=source.indexOf('let resultAdjustmentRequest=',start);vm.runInContext(source.slice(start,end),ctx);
 const usage=ctx.buildResultAdjustmentStages(records,'usage');assert.equal(usage.length,1);assert.equal(usage[0].records.length,2);
 assert.equal(ctx.buildResultAdjustmentStages(records,'cross').length,2);
 assert.equal(ctx.buildResultAdjustmentStages(records,'suspected').length,1);
});
