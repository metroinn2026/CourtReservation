const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');
const { TextEncoder } = require('node:util');
const { test } = require('node:test');

const adminHtml = fs.readFileSync(path.join(__dirname, '..', 'admin.html'), 'utf8');

function createRow({
  timestamp = '2026-10-01 08:00:00',
  email = 'member@example.com',
  name = '王小明',
  id = 'A123456789',
  phone = '0912345678',
  badminton = [],
  basketball = [],
  tableTennis = []
} = {}) {
  const row = {
    '時間戳記': timestamp,
    '電子郵件地址': email,
    '申請人姓名': name,
    '申請會員身分（請擇一）': '北投會館會員',
    '北投會館會員身分證字號（10碼）': id,
    '聯絡手機號碼（會館會員，10碼）': phone
  };
  if (badminton.length) {
    row['是否申請羽球？'] = '是';
    row['羽球：選擇星期（限選一日）'] = '週一';
    badminton.forEach((slot, i) => { row[`羽球：請選擇1個時段（${i + 1}）`] = slot; });
  }
  if (basketball.length) {
    row['是否申請籃球？'] = '是';
    row['籃球：選擇星期（限選一日）'] = '週一';
    basketball.forEach((slot, i) => { row[`籃球：請選擇1個時段（${i + 1}）`] = slot; });
  }
  tableTennis.forEach(({ venue = 'B1', day = '一', slot }, i) => {
    row[`${venue}桌球場｜週${day}｜時段${i + 1}`] = slot;
  });
  return row;
}

async function parseRows(rows) {
  let worksheetRows = rows;
  const xlsx = {
    read: () => ({ SheetNames: ['表單回覆 1'], Sheets: { '表單回覆 1': {} } }),
    utils: { sheet_to_json: () => worksheetRows }
  };
  const sandbox = {
    DEFAULT_LOCATION: '北投會館',
    TextEncoder,
    crypto: webcrypto,
    window: { XLSX: xlsx },
    XLSX: xlsx
  };
  const hashStart = adminHtml.indexOf('async function sha256(');
  const hashEnd = adminHtml.indexOf('\n', hashStart);
  const parserStart = adminHtml.indexOf('function normalizeFormDay(');
  const parserEnd = adminHtml.indexOf('\nlet pendingFormImport=null', parserStart);
  assert.ok(hashStart >= 0 && hashEnd > hashStart, 'SHA-256 helper must exist in admin.html');
  assert.ok(parserStart >= 0 && parserEnd > parserStart, 'form parser helpers must exist in admin.html');
  vm.createContext(sandbox);
  vm.runInContext(
    adminHtml.slice(hashStart, hashEnd) + '\n' +
    adminHtml.slice(parserStart, parserEnd) + '\n' +
    'globalThis.parseGoogleFormWorkbook = parseGoogleFormWorkbook;',
    sandbox,
    { filename: 'admin.html parser' }
  );
  return sandbox.parseGoogleFormWorkbook({ arrayBuffer: async () => new ArrayBuffer(0) });
}

function ruleAnomalies(parsed) {
  return parsed.anomalies.filter(a => /超過1場|重複申請相同場次|跨球類時段衝突|同時間提交衝突|同一回覆登記衝突/.test(a.type));
}

test('one badminton plus one non-overlapping basketball application is allowed', async () => {
  const parsed = await parseRows([createRow({ badminton: ['06:00-06:59'], basketball: ['08:00-09:59'] })]);
  assert.equal(parsed.records.length, 2);
  assert.equal(ruleAnomalies(parsed).length, 0);
});

test('same-response conflicting badminton and basketball are separately pending', async () => {
  const parsed = await parseRows([createRow({ badminton: ['06:00-06:59'], basketball: ['06:00-07:59'] })]);
  const conflicts = parsed.anomalies.filter(a => a.type === '同一回覆跨球類時段衝突（雙方待人工確認）');
  assert.equal(conflicts.length, 2);
  assert.equal(Array.from(conflicts, a => a.recordKeys.length).join(','), '1,1');
  assert.deepEqual(new Set(conflicts.flatMap(a => a.recordKeys)).size, 2);
});

test('multiple badminton choices in one response require review on both rows', async () => {
  const parsed = await parseRows([createRow({ badminton: ['06:00-06:59', '08:00-08:59'] })]);
  const conflicts = parsed.anomalies.filter(a => a.type === '同一回覆登記衝突（雙方待人工確認）');
  assert.equal(conflicts.length, 2);
  assert.equal(new Set(conflicts.flatMap(a => a.recordKeys)).size, 2);
});

test('same member submitted later row first still gives the earlier timestamp priority', async () => {
  const parsed = await parseRows([
    createRow({ timestamp: '2026-10-02 08:00:00', email: 'second@example.com', badminton: ['08:00-08:59'] }),
    createRow({ timestamp: '2026-10-01 08:00:00', email: 'first@example.com', badminton: ['06:00-06:59'] })
  ]);
  const later = parsed.records.find(r => r.time_slot === '08:00-08:59');
  const earlier = parsed.records.find(r => r.time_slot === '06:00-06:59');
  assert.ok(parsed.anomalies.some(a => a.type === '羽球每位會員超過1場（後筆）' && a.recordKeys.includes(later.record_key)));
  assert.ok(!parsed.anomalies.some(a => a.recordKeys.includes(earlier.record_key) && /超過1場/.test(a.type)));
});

test('same timestamp conflicts across separate submissions require review on both rows', async () => {
  const parsed = await parseRows([
    createRow({ timestamp: '2026-10-01 08:00:00', email: 'member-one@example.com', badminton: ['06:00-06:59'] }),
    createRow({ timestamp: '2026-10-01 08:00:00', email: 'member-two@example.com', basketball: ['06:00-07:59'] })
  ]);
  const ties = parsed.anomalies.filter(a => a.type === '同時間提交衝突（雙方待人工確認）');
  assert.equal(ties.length, 2);
  assert.equal(new Set(ties.flatMap(a => a.recordKeys)).size, 2);
});

test('table tennis allows different slots but duplicate same-stage submissions flag the later row', async () => {
  const allowed = await parseRows([createRow({ tableTennis: [{ slot: '08:00-08:59' }, { slot: '10:00-10:59' }] })]);
  assert.equal(ruleAnomalies(allowed).length, 0);
  const duplicate = await parseRows([
    createRow({ timestamp: '2026-10-01 08:00:00', email: 'first@example.com', tableTennis: [{ slot: '08:00-08:59' }] }),
    createRow({ timestamp: '2026-10-02 08:00:00', email: 'second@example.com', tableTennis: [{ slot: '08:00-08:59' }] })
  ]);
  assert.ok(duplicate.anomalies.some(a => a.type === '同一會員重複申請相同場次（後筆）'));
});

test('different members may request the same slot, including a shared contact phone', async () => {
  const parsed = await parseRows([
    createRow({ id: 'A123456789', phone: '0911111111', badminton: ['06:00-06:59'] }),
    createRow({ id: 'B234567890', phone: '0911111111', email: 'other@example.com', badminton: ['06:00-06:59'] })
  ]);
  assert.equal(parsed.records.length, 2);
  assert.equal(ruleAnomalies(parsed).length, 0);
});

test('malformed selected times become a review anomaly instead of a record', async () => {
  const parsed = await parseRows([createRow({ badminton: ['早上第一場'] })]);
  assert.equal(parsed.records.length, 0);
  assert.ok(parsed.anomalies.some(a => a.type === '場次時間格式異常' && a.recordKeys.length === 0));
});

test('fullwidth time punctuation and 星期 day labels normalize consistently', async () => {
  const row = createRow({ badminton: ['09：00 ～ 10：00'] });
  row['羽球：選擇星期（限選一日）'] = '星期一';
  const parsed = await parseRows([row]);
  assert.equal(parsed.records.length, 1);
  assert.equal(parsed.records[0].day_of_week, '周一');
  assert.equal(parsed.records[0].time_slot, '09:00-10:00');
});

test('same-response overlap between a table tennis court and basketball needs manual review', async () => {
  const parsed = await parseRows([createRow({
    basketball: ['06:00-08:00'],
    tableTennis: [{ venue: 'B1', day: '一', slot: '07:00-08:00' }]
  })]);
  const conflicts = parsed.anomalies.filter(a => a.type === '同一回覆跨球類時段衝突（雙方待人工確認）');
  assert.equal(conflicts.length, 2);
  assert.equal(new Set(conflicts.flatMap(a => a.recordKeys)).size, 2);
});

test('out-of-range hours and minutes become anomalies instead of database failures', async () => {
  const parsed = await parseRows([createRow({ badminton: ['25:00-26:00'] })]);
  assert.equal(parsed.records.length, 0);
  assert.ok(parsed.anomalies.some(a => a.type === '場次時間格式異常'));
});
