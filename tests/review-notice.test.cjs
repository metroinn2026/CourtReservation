const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');

test('review notice XML keeps print settings before ignored errors and removes invalid whitespace attributes',async()=>{
  const admin=fs.readFileSync(path.join(__dirname,'..','admin.html'),'utf8');
  const start=admin.indexOf('async function createReviewNoticeWorkbook(');
  const end=admin.indexOf('async function exportReviewNotice(',start);
  const files=new Map([
    ['xl/worksheets/sheet1.xml','<worksheet xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheetData><row r="2" xml:space="preserve"><c r="A2" xml:space="preserve"><v xml:space="preserve">標題\n合格名單</v></c></row></sheetData><ignoredErrors><ignoredError sqref="A1:E6" numberStoredAsText="1"/></ignoredErrors></worksheet>'],
    ['xl/workbook.xml','<workbook><sheets/></workbook>'],
    ['[Content_Types].xml','<Types><Default Extension="png" ContentType="image/png"/></Types>']
  ]);
  const archive={
    file(name,value){
      if(arguments.length===2){files.set(name,value);return this;}
      return files.has(name)?{async:async()=>files.get(name)}:null;
    },
    generateAsync:async()=>new Uint8Array([1])
  };
  const sandbox={
    REVIEW_NOTICE_TITLE:'登記合格名單',reviewNoticeStageLabel:()=> '週一 08:00–10:00',
    escapeHtml:s=>s,
    XLSX:{utils:{
      book_new:()=>({}),aoa_to_sheet:()=>({A2:{}}),decode_range:()=>({}),
      book_append_sheet:()=>{}
    },write:()=>[]},
    JSZip:{loadAsync:async()=>archive}
  };
  vm.createContext(sandbox);
  vm.runInContext(admin.slice(start,end),sandbox);
  await sandbox.createReviewNoticeWorkbook({rows:[[1,'123ABC','王○明','007','合格']]},new Uint8Array([1]));
  const sheet=files.get('xl/worksheets/sheet1.xml');
  assert.doesNotMatch(sheet,/<(?:row|c|v)\b[^>]*xml:space=/);
  assert.ok(sheet.indexOf('<pageSetup')<sheet.indexOf('<ignoredErrors>'));
  assert.ok(sheet.indexOf('<headerFooter>')<sheet.indexOf('<ignoredErrors>'));
  assert.ok(sheet.indexOf('<ignoredErrors>')<sheet.indexOf('<drawing '));
  assert.match(sheet,/&amp;P 頁／共 &amp;N 頁/);
  assert.ok(files.has('xl/media/trtc-logo.png'));
  assert.equal((files.get('[Content_Types].xml').match(/Extension="png"/g)||[]).length,1);
});
