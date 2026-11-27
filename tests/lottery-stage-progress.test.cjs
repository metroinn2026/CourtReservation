const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const source=fs.readFileSync(process.env.COURT_ADMIN_HTML||path.join(__dirname,'..','admin.html'),'utf8');
const helper=source.slice(source.indexOf('function summarizeLotteryStageProgress('),source.indexOf('function getStageGroups('));
const ctx=vm.createContext({});vm.runInContext(helper,ctx);
const row=(status='',published=false)=>({lottery_status:status,result_published:published});
const progress=(rows,opts={})=>ctx.summarizeLotteryStageProgress({qualified:rows,pendingCount:0,people:rows.length,capacity:2,closed:false,loaded:true,...opts});
assert.equal(progress([row(),row(),row()]).progress,'draw_pending');
assert.equal(progress([row('中籤'),row(),row()]).withResult,1);
assert.match(progress([row('中籤'),row(),row()]).reason,/尚缺 2 筆/);
assert.equal(progress([row('未抽籤')]).progress,'exempt_pending');
assert.equal(progress([row(),row()]).progress,'exempt_pending');
assert.equal(progress([row('中籤'),row('中籤'),row('候補1')]).progress,'ready');
assert.equal(progress([row('中籤',true),row('中籤')]).progress,'ready');
assert.equal(progress([row('中籤',true),row('中籤',true)]).progress,'published');
assert.equal(progress([]).progress,'empty');
assert.equal(progress([],{loaded:false}).progress,'review');
assert.equal(progress([row()],{pendingCount:1}).progress,'review');
assert.equal(progress([row()],{closed:true}).progress,'review');
assert.equal(progress([row()],{capacity:0}).progress,'review');
assert.equal(progress([row('unknown')]).withResult,0);
// Exercise the actual renderer: stage filters, qualified-only result counts, pagination and clear.
const nodes=new Map();
const node=id=>{if(!nodes.has(id))nodes.set(id,{value:'',innerHTML:'',querySelectorAll:()=>[]});return nodes.get(id);};
const context=vm.createContext({window:{},document:{getElementById:node},Map,Set,console,
exemptApprovalBusy:false,buildExemptApprovalPlan:()=>({reason:'fixture'}),sp88StageKey:s=>s.venue,
DEFAULT_LOCATION:'北投會館',qualificationReviewsLoaded:true,
allRecords:[
{id:'a',location:'北投會館',venue_type:'羽球',day_of_week:'周六',time_slot:'10:00-11:59',state:'qualified',lottery_status:'中籤',result_published:false},
{id:'b',location:'北投會館',venue_type:'羽球',day_of_week:'周六',time_slot:'10:00-12:00',state:'invalid',lottery_status:''},
{id:'c',location:'北投會館',venue_type:'籃球',day_of_week:'周日',time_slot:'10:00-12:00',state:'qualified',lottery_status:''},
{id:'d',location:'北投會館',venue_type:'籃球',day_of_week:'周日',time_slot:'10:00-12:00',state:'qualified',lottery_status:''}],
recordLocation:r=>r.location,slotRangeKey:s=>s.replace('11:59','12:00'),qualificationState:r=>r.state,
countRegistrationPeople:rs=>rs.length,getStageCapacity:()=>1,isStageClosed:()=>false,
venueSortValue:s=>s==='羽球'?0:1,daySortValue:s=>s==='周六'?6:7,timeSortValue:()=>0,statusSortValue:()=>0,
escapeHtml:x=>String(x??''),locationLabel:x=>x,publishStatusTag:()=>'',getRecordAnomalyTypes:()=>{throw Error('must stay lazy');}});
const start=source.indexOf('  function getDayCheckRecords(){',source.indexOf('function renderLotteryPage('));
const end=source.indexOf('  function getSelectedRecords(){',start);
assert(start>0&&end>start);
vm.runInContext(helper+source.slice(start,end)+'\nrenderDayCheck();',context);
let html=node('dayCheckTable').innerHTML;
assert.match(html,/已完成、待公布/);
assert.match(html,/需抽籤、尚未完成/);
assert.match(html,/共 4 筆/);
// The ineligible blank record does not keep its stage pending; canonical time variants are one stage.
assert.match(html,/顯示 <strong>2<\/strong> \/ 2 個場次/);
node('stageListProgressFilter').value='ready';node('stageListProgressFilter').onchange();
html=node('dayCheckTable').innerHTML;
assert.match(html,/顯示 <strong>1<\/strong> \/ 2 個場次/);
assert.match(html,/共 2 筆/);
assert(!html.includes('<strong>籃球</strong>'));
node('clearStageListFilters').onclick();
assert.equal(context.window.stageListProgressFilter,'');
assert.match(node('dayCheckTable').innerHTML,/共 4 筆/);
console.log('Stage progress classification and renderer checks passed');
