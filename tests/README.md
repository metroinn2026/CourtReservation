# v16 免費本機測試

在專案根目錄執行：

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm test
```

目前 42 項測試：11 parser、8 後台、23 PostgreSQL 資料庫測試。PGlite 固定版本 0.5.10；只在記憶體執行合成資料，無雲端連線、付費服務或 GitHub Actions。

資料庫測試實際安裝 `sql/` 的三份候選 SQL，測試重試與補建、跨批次時序、同回覆衝突、共用手機、人工確認、交易回滾、超過 1000 筆異常、授權拒絕、快照失效、容量與候補順位、結果原子寫入及稽核。

## 限制

- `fixtures/schema.sql` 僅供本機；禁止部署。Auth.uid 與會員 HMAC 使用測試替身，md5 不可用作正式會員識別保護。
- fixture 並非完整正式 schema；未驗證全部 production constraints、RLS/table grants 或真實 HMAC。
- PGlite 單連線，無法證明多連線鎖定及併發安全；需另外驗證 Supabase Auth、PostgREST、併發交易與瀏覽器完整流程。
- 後台測試抽取實際函式並使用 client stub，未執行真正 Excel 檔案或瀏覽器操作；需要去識別化 v16 Google Forms XLSX 另作驗收。
- 通過本機測試不代表可上線；仍須完成 `V16_SECURITY_BLOCKERS.md`。

候選安裝順序：唯一索引遷移 → 匯入函式 → 異常檢核與抽籤 RPC。三份全部安裝後才可測試匯入。正式資料庫操作必須另經核准。
