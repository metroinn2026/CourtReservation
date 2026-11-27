const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const source=fs.readFileSync(process.env.COURT_ADMIN_SOURCE||path.join(__dirname,'../admin.html'),'utf8');
function parse(rows,change=()=>{}){
 const records=[{id:'one',serial_number:'AAAA01',name:'T',phone:'0900000001'},{id:'two',serial_number:'AAAA02',name:'陳小明',phone:'0900000002'}].map(r=>({...r,qualified:true,venue_type:'羽球',sport_usage:'羽球',day_of_week:'周六',time_slot:'10:00-12:00',location_name:'北投會館'}));change(records);
 const ctx={allRecords:records,isQualifiedForLottery:r=>r.qualified,locationLabel:x=>x,courtUsage:r=>r.sport_usage,sp88RecordStageKey:r=>JSON.stringify([r.location_name,r.venue_type,r.day_of_week,r.time_slot])};vm.createContext(ctx);
 const start=source.indexOf('  function parseSP88Results(');vm.runInContext(source.slice(start,source.indexOf('  async function parseLotteryResultFiles',start)),ctx);
 return ctx.parseSP88Results([['抽獎主題：','fixture'],[],[],['名單總數：','2 筆'],[],['抽出結果：','2 名中獎者'],['正取 …… 1 個名額'],[rows[0]],['備取 …… 99 個名額'],[rows[1]],['(尚缺 98 個)']],'fixture.xlsx',new Map(records.map(r=>[r.serial_number,r])),new Set(),new Set());
}
test('legacy fully masked single-character name preserves winner and waitlist',()=>{
 const r=parse(['○,001,AAAA01','陳○明,002,AAAA02']);assert.equal(r.errors.length,0);assert.equal(r.valid.length,2);assert.equal(r.canSetMissing,true);assert.equal(r.valid[1].status,'候補1');
});
test('current single-character export with visible initial stays supported',()=>assert.equal(parse(['T○,001,AAAA01','陳○明,002,AAAA02']).errors.length,0));
test('legacy exception still rejects mismatched phone suffix',()=>assert.ok(parse(['○,999,AAAA01','陳○明,002,AAAA02']).errors.some(e=>e.reason.includes('手機末三碼'))));
test('fully masked multi-character name cannot use legacy exception',()=>assert.ok(parse(['○,001,AAAA01','陳○明,002,AAAA02'],r=>r[0].name='Tom').errors.some(e=>e.reason.includes('姓名第一字'))));
test('normal surname mismatch is still rejected',()=>assert.ok(parse(['○,001,AAAA01','王○明,002,AAAA02']).errors.some(e=>e.reason.includes('姓名第一字'))));
test('duplicate serial remains rejected',()=>assert.ok(parse(['○,001,AAAA01','○,001,AAAA01']).errors.some(e=>e.reason.includes('重複'))));
test('unqualified record remains rejected',()=>assert.ok(parse(['○,001,AAAA01','陳○明,002,AAAA02'],r=>r[0].qualified=false).errors.some(e=>e.reason.includes('資格合格'))));
