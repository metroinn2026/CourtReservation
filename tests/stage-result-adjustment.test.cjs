const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const src=fs.readFileSync(process.env.COURT_ADMIN_SOURCE||path.join(__dirname,'../admin.html'),'utf8');
const implementation=src.slice(src.indexOf('const resultAdjustmentHistory=new Map();'),src.indexOf('const phoneCorrectionHistory=new Map();'));
const r=(id,status,usage='羽球',extra={})=>({id,name:'測試'+id,phone:'0900000000',serial_number:id,identity:id,lottery_status:status,venue_type:'羽球',sport_usage:usage,day_of_week:'周一',time_slot:'10:00-12:00',updated_at:'2026-11-27T10:00:00Z',...extra});
function fixture(){return[r('A','中籤'),r('B','中籤','其他球類'),r('C','中籤','其他球類'),r('D','候補1','其他球類'),r('E','候補2'),r('F','候補3')];}
function context(records){
 const c=vm.createContext({Map,Set,console,allRecords:records,qualificationReviewsLoaded:true,capacitySettingsLoaded:true,
 isQualifiedForLottery:r=>r.state!=='invalid',sp88RecordStageKey:r=>[r.location_name||'北投會館',r.venue_type,r.day_of_week,r.time_slot].join('|'),getStageCapacity:()=>3,isStageClosed:()=>false,courtUsage:r=>r.sport_usage,
 compactRecordCode:r=>r.id,recordLocation:r=>r.location_name||'北投會館',lotteryTimesOverlap:(a,b)=>a.day_of_week===b.day_of_week&&a.time_slot===b.time_slot,lotteryWinnerRelation:(a,b)=>a.identity===b.identity?'same':'',escapeHtml:s=>String(s),
 statusSortValue:s=>s==='中籤'?0:/^候補\d+$/.test(s)?Number(s.slice(2))+1:999,memberIdentityType:()=> 'Go會員',locationLabel:s=>s,courtVenueLabel:r=>r.venue_type,correctionNoticeDate:s=>s,
 buildLotteryResultChecks:()=>({cross:[],suspected:[],usage:[{records:records.slice(0,3)}]}),lotteryResultStageGroups:rs=>{const map=new Map();for(const row of rs){const key=[row.location_name||'北投會館',row.venue_type,row.day_of_week,row.time_slot].join('|');if(!map.has(key))map.set(key,{key,location:row.location_name||'北投會館',venue:row.venue_type,day:row.day_of_week,time:row.time_slot,records:[]});map.get(key).records.push(row);}return[...map.values()];},
 bindRecordsBottomScrollbar:()=>{},confirm:()=>true,courtAuthLoginActive:true,adminSigningOut:false,adminSessionEpoch:1});
 vm.runInContext(implementation+'\nresultAdjustmentHistoryLoaded=true;globalThis.hist=resultAdjustmentHistory;',c);return c;
}
test('2 excluded winners and 2 promoted standbys are validated only as final stage state',()=>{
 const rows=fixture(),c=context(rows),p=c.planStageResultAdjustment(rows,{B:'usage_excluded',C:'usage_excluded',E:'promoted',F:'promoted'},'本場保留羽球，依原順位遞補');
 assert.equal(p.payload.length,4);assert.equal(p.winnerCount,3);assert.equal(p.stageExpected.records.length,6);assert.equal(p.stageExpected.capacity,3);assert.equal(rows[1].lottery_status,'中籤');assert.equal(rows[4].lottery_status,'候補2');
});
test('usage suggestion produces all four drafts and does not change records',()=>{
 const rows=fixture(),c=context(rows),p=c.proposeStageUsageAdjustment(rows,'羽球');assert.deepEqual([...p.actions.keys()],['B','C','E','F']);assert.equal(p.actions.get('B'),'usage_excluded');assert.equal(p.actions.get('E'),'promoted');assert.equal(p.warnings.length,0);assert.equal(rows[1].lottery_status,'中籤');
});
test('two badminton and one other winner only requires one replacement',()=>{
 const rows=[r('A','中籤'),r('B','中籤'),r('C','中籤','其他球類'),r('D','候補1')],c=context(rows),p=c.proposeStageUsageAdjustment(rows,'羽球');assert.equal(p.actions.size,2);assert.equal(c.planStageResultAdjustment(rows,p.actions,p.reason).winnerCount,3);
});
test('published stage, cross-stage inputs, missing reason and out-of-order standby are blocked',()=>{
 const rows=fixture(),c=context(rows);assert.throws(()=>c.planStageResultAdjustment(rows,{B:'usage_excluded'},''),/填寫/);
 assert.throws(()=>c.planStageResultAdjustment(rows,{B:'usage_excluded',C:'usage_excluded',F:'promoted'},'原因'),/較前順位/);
 rows[0].result_published=true;assert.throws(()=>c.planStageResultAdjustment(rows,{B:'usage_excluded'},'原因'),/取消公布/);
 rows[0].result_published=false;assert.throws(()=>c.planStageResultAdjustment([...rows,r('X','候補4','羽球',{day_of_week:'周二'})],{B:'usage_excluded'},'原因'),/同一場次/);
});
test('final mixed usage is rejected even if no promotion selected',()=>{
 const rows=fixture(),c=context(rows);assert.throws(()=>c.planStageResultAdjustment(rows,{B:'usage_excluded'},'原因'),/用途仍不一致/);
});
test('automatic suggestions stop at unresolved earlier standby and disclose vacancies',()=>{
 const rows=fixture();rows[4].state='invalid';const c=context(rows),p=c.proposeStageUsageAdjustment(rows,'羽球');assert.equal(p.actions.has('F'),false);assert(p.warnings.join(' ').includes('停止'));assert(p.warnings.join(' ').includes('2 個'));
});
test('record focus or partial name/usage scope opens entire stage instead of one person',()=>{
 const rows=fixture(),c=context(rows);const groups=c.buildResultAdjustmentStages([rows[1]],'all');assert.equal(groups.length,1);assert.equal(groups[0].records.length,6);
 assert.equal(c.buildResultAdjustmentStages([],'issues','E')[0].records.length,6);
});
function editor(c,records,error=null){
 const nodes=new Map(),node=key=>{if(!nodes.has(key))nodes.set(key,{textContent:'',value:'',disabled:false,dataset:{},style:{}});return nodes.get(key);};
 const selects=records.map(row=>({value:'',disabled:false,dataset:{stageResultId:row.id}}));
 const form={elements:{reason:{value:'本場保留羽球，依原順位遞補',disabled:false}},querySelector:node,querySelectorAll:selector=>selector==='[data-stage-result-id]'?selects:[...selects,form.elements.reason,node('submit')]};
 const host={innerHTML:'',querySelector:selector=>selector==='[data-stage-result-form]'?form:node(selector)};
 const calls=[];let saved='';
 c.reviewDbClient=()=>({rpc:async(name,args)=>{calls.push({name,args});return error?{error}:{data:{updated_count:args.p_changes.length}};}});
 c.loadAllData=async()=>true;c.confirmModal=async()=>true;c.renderResultAdjustmentList=async(container,message)=>saved=message;
 c.renderStageResultAdjustmentEditor(host,records,{});
 return{host,form,selects,calls,nodes,get saved(){return saved;}};
}
test('stage editor renders every result and submits one transaction for four selected rows',async()=>{
 const rows=fixture(),c=context(rows),e=editor(c,rows);
 const actions={B:'usage_excluded',C:'usage_excluded',E:'promoted',F:'promoted'};for(const select of e.selects)select.value=actions[select.dataset.stageResultId]||'';
 e.selects[1].onchange();await e.form.onsubmit({preventDefault(){}});
 assert.equal(e.calls.length,1);assert.equal(e.calls[0].name,'court_adjust_stage_results_v1');assert.equal(e.calls[0].args.p_changes.length,4);assert.equal(e.calls[0].args.p_stage_expected.records.length,6);assert(e.saved.includes('4 筆'));
 assert(e.host.innerHTML.includes('本次調整'));assert(e.host.innerHTML.includes('data-stage-result-id="F"'));assert(e.host.innerHTML.includes('本場歷次調整紀錄'));
});
test('server failure keeps all drafts in same stage editor for correction',async()=>{
 const rows=fixture(),c=context(rows),e=editor(c,rows,{message:'同場次結果已更新'}),actions={B:'usage_excluded',C:'usage_excluded',E:'promoted',F:'promoted'};
 for(const select of e.selects)select.value=actions[select.dataset.stageResultId]||'';
 await e.form.onsubmit({preventDefault(){}});assert.equal(e.selects[4].value,'promoted');assert(e.nodes.get('[data-stage-message]').textContent.includes('草稿仍保留'));assert.equal(e.saved,'');
});
