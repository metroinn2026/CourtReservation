const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const source=fs.readFileSync(process.env.COURT_ADMIN_SOURCE||path.join(__dirname,'../admin.html'),'utf8');
const impl=source.slice(source.indexOf('const REVIEW_NOTICE_TITLE='),source.indexOf('let reviewNoticeExportBusy='));
function context(extra={}){
 const ctx=vm.createContext({console,setTimeout,Map,Set,
 qualificationState:r=>r.state||'qualified',recordLocation:r=>r.location||'北投會館',courtUsage:r=>r.usage||'羽球',
 compactRecordCode:r=>r.serial_number,maskPublicName:n=>Array.from(n).map((c,i)=>i===1?'○':c).join(''),
 getLotteryPhoneLast3:r=>r.phone.slice(-3),slotRangeKey:t=>t.replace('11:59','12:00'),days:['周一','周二'],
 venueSortValue:v=>v==='羽球'?0:1,daySortValue:d=>d==='周一'?1:2,locationLabel:x=>x,courtVenueLabel:r=>r.venue_type,
 escapeHtml:s=>String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;'),...extra});
 const display=source.slice(source.indexOf('const resultAdjustmentHistory=new Map();'),source.indexOf('async function loadResultAdjustmentHistory('));
 vm.runInContext(display+impl,ctx);return ctx;
}
const r=(serial,status,extra={})=>({serial_number:serial,lottery_status:status,name:'王小明',phone:'0912345007',venue_type:'羽球',day_of_week:'周一',time_slot:'10:00-12:00',...extra});
test('result announcement includes only qualified winners/waitlist with masked public fields',()=>{
 const ctx=context();const groups=ctx.buildReviewNoticeGroups([r('ABC010','候補10'),r('ABC002','候補2'),r('ABC001','中籤'),r('ABC003','未中籤'),r('ABC004',''),r('ABC005','放棄'),r('ABC006','中籤',{state:'invalid'})],false,true);
 assert.equal(groups.length,1);assert.deepEqual(JSON.parse(JSON.stringify(groups[0].rows)),[[1,'ABC001','王○明','007','正取','羽球'],[2,'ABC002','王○明','007','備取2','羽球'],[3,'ABC010','王○明','007','備取10','羽球']]);
 assert(!JSON.stringify(groups).includes('0912345007'));assert(!JSON.stringify(groups).includes('王小明'));
});
test('qualified announcement and SP88 grouping retain prior behavior',()=>{
 const ctx=context();const rows=[r('ABC001',''),r('ABC002','候補1',{usage:'匹克球'})];
 assert.equal(ctx.buildReviewNoticeGroups(rows).length,2);assert.equal(ctx.buildReviewNoticeGroups(rows,true).length,1);
 assert(ctx.buildReviewNoticeGroups(rows,true)[0].rows.every(row=>row[4]==='合格'));
});
test('single-character name is fully masked; incomplete public fields block group',()=>{
 const ctx=context();const group=ctx.buildReviewNoticeGroups([r('ABC001','中籤',{name:'T'}),r('ABC002','候補1',{phone:''})],false,true)[0];
 assert.equal(group.rows[0][2],'○');assert.equal(group.incomplete,1);
});
test('PDF uses result title, column, repeated headers, page numbers and small logo',async()=>{
 const text=[],images=[];let pages=0;
 const canvasContext={scale(){},fillRect(){},strokeRect(){},drawImage(...args){images.push(args);},fillText(value){text.push(value);}};
 const ctx=context({document:{createElement:()=>({getContext:()=>canvasContext,toDataURL:()=>''})},PDFLib:{PDFDocument:{create:async()=>({setTitle:t=>text.push(t),setAuthor(){},embedPng:async()=>({}),addPage:()=>{pages++;return{drawImage(){}};},save:async()=>new Uint8Array([1])})}}});
 const stage=ctx.buildReviewNoticeGroups([r('ABC001','中籤')],false,true)[0];stage.rows=Array.from({length:28},(_,i)=>[i+1,'ABC001','王○明','007',i?'備取'+i:'正取','羽球']);
 await ctx.createReviewNoticePdf(stage,{});
 assert.equal(pages,2);assert.equal(text.filter(t=>t==='抽籤結果').length,2);assert.equal(text.filter(t=>t==='使用用途').length,2);assert(text.includes('第 2 頁／共 2 頁'));
 assert(text.includes('正取及備取名單'));assert(!text.includes('審查結果'));assert.equal(images[0][3],77.5);
});
test('export control and download filenames distinguish result notices',()=>{
 assert(source.includes('id="exportLotteryResultsBtn"'));assert(source.includes("exportReviewNotice(exportLotteryResultsButton,'results')"));
 assert(source.includes('公告正取備取名單_全部場次.pdf'));assert(source.includes('正取備取名單_公告_${date}.zip'));
});
test('real XLSX output preserves result headers, text suffixes, print titles and logo',{skip:!process.env.COURT_XLSX_MODULE},async()=>{
 const XLSX=require(process.env.COURT_XLSX_MODULE),JSZip=require(process.env.COURT_JSZIP_MODULE||'jszip');
 const ctx=context({XLSX,JSZip});
 const logo=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=','base64');
 for(const results of [false,true]){
 const stage=ctx.buildReviewNoticeGroups([r('ABC001','中籤'),r('ABC002','候補1')],false,results)[0];
 const bytes=await ctx.createReviewNoticeWorkbook(stage,logo);
 const wb=XLSX.read(bytes,{type:'array'}),name=results?'正取備取名單':'登記合格名單';
 assert.equal(wb.SheetNames[0],name);const ws=wb.Sheets[name];
 assert.equal(ws.E5.v,results?'抽籤結果':'審查結果');assert.equal(ws.D6.v,'007');assert.equal(ws.D6.t,'s');
 assert.equal(ws.E6.v,results?'正取':'合格');
 if(results){assert.equal(ws.F5.v,'使用用途');assert.equal(ws.F6.v,'羽球');}
 const zip=await JSZip.loadAsync(bytes),xml=await zip.file('xl/worksheets/sheet1.xml').async('string');
 assert(!/<(?:row|c|v)\b[^>]*xml:space=/.test(xml));assert(xml.indexOf('<pageSetup')<xml.indexOf('<ignoredErrors'));
 assert((await zip.file('xl/workbook.xml').async('string')).includes("'"+name+"'!$1:$5"));assert(zip.file('xl/media/trtc-logo.png'));
 assert((await zip.file('xl/workbook.xml').async('string')).includes(results?'$A$1:$F$7':'$A$1:$E$7'));
 assert.equal(XLSX.utils.encode_range(ws['!merges'][0]),results?'A2:F2':'A2:E2');
 if(process.env.COURT_RESULT_FIXTURE_DIR)fs.writeFileSync(path.join(process.env.COURT_RESULT_FIXTURE_DIR,results?'results-fixture.xlsx':'qualified-fixture.xlsx'),bytes);
 }
});

test('badminton and basketball combine all usages in result order within each stage',()=>{
 const ctx=context();
 for(const venue of ['羽球','籃球']){
 const groups=ctx.buildReviewNoticeGroups([r('ABC003','候補10',{venue_type:venue,usage:'其他球類'}),r('ABC001','中籤',{venue_type:venue,usage:venue}),r('ABC002','候補2',{venue_type:venue,usage:'其他球類'})],false,true);
 assert.equal(groups.length,1);assert.equal(groups[0].combinedUsage,true);
 assert.deepEqual(Array.from(groups[0].rows,row=>row[4]),['正取','備取2','備取10']);
 assert.deepEqual(Array.from(groups[0].rows,row=>row[5]),[venue,'其他球類','其他球類']);
 assert(!ctx.reviewNoticeStageLabel(groups[0]).includes('用途'));
 assert.equal(ctx.reviewNoticeHeaders(groups[0]).length,6);
 }
});
test('different days and times remain separate despite combining usages',()=>{
 const ctx=context();const records=[r('ABC001','中籤'),r('ABC002','候補1',{usage:'其他球類'}),r('ABC003','中籤',{day_of_week:'周二'}),r('ABC004','中籤',{time_slot:'12:00-14:00'})];
 assert.equal(ctx.buildReviewNoticeGroups(records,false,true).length,3);
 assert.equal(ctx.buildReviewNoticeGroups(records).length,4);
});
test('result announcement discloses promoted winner while retaining standby numeric order',()=>{
 const c=context();vm.runInContext("resultAdjustmentHistory.set('record1',[{version:1,original_status:'候補2',after_status:'中籤',action:'promoted'}]);",c);
 const groups=c.buildReviewNoticeGroups([r('ABC010','候補10'),r('ABC002','中籤',{id:'record1'}),r('ABC003','候補3')],false,true);
 assert.equal(groups[0].rows[0][4],'正取（遞補）');assert.equal(groups[0].rows[1][4],'備取3');assert.equal(groups[0].rows[2][4],'備取10');
});
