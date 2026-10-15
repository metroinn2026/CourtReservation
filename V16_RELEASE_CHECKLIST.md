# v16 抽籤系統變更與驗收（草稿）

## 2026-10-16 狀態

- GitHub PR #1 仍在測試分支 `fix/form-v16-member-rules-20261015`，尚未合併。
- 正式 Supabase `wsvsdwuksuzcjisnpyin` 未修改；唯讀查核仍為 3 批匯入、6 份原始回覆、0 筆 `lottery_records`、0 筆異常紀錄。批次歷史統計曾記錄 12 筆場次。
- Supabase 專案目前沒有 development branches；未建立分支或執行資料庫變更。
- 三份候選 SQL 已在免費本機 PGlite PostgreSQL 引擎以合成 schema 安裝並執行測試；尚未完成真正 Supabase 整合驗收。
- 前後台仍有公開匿名資料表 CRUD 與後台用戶端登入問題，屬正式上線阻擋項目。不可合併或部署目前候選版本。

## 不可跳過的部署順序

1. 先使用免費本機隔離環境；不得建立付費服務或雲端測試分支，也不得把正式會員回覆複製到測試資料庫。後續 Supabase 完整驗收環境須確認不產生費用。
2. 在隔離環境核對 schema、index、function owner/ACL、RLS policies 及 table grants。
3. 執行並驗證 `sql/v16_registration_unique_index_migration.sql`。
4. 執行並驗證 `sql/v16_import_existing_submissions_STAGING.sql`。
5. 執行並驗證 `sql/v16_reconcile_all_imports_STAGING.sql`，包含異常人工確認後的再次檢核。
6. 使用合成回覆及真正的 v16 Google 表單匯出 XLSX 做匯入測試。真正 XLSX 尚未提供，因此欄位對應仍未驗證。
7. 完成公開前台與管理後台的伺服器授權改造，再於 staging 同步驗證 RLS、table grants、RPC/Edge Function 權限。不得先刪除現有 policies。
8. 驗證所有抽籤名單匯出、單場/批次抽籤、結果 Excel 匯入、候補順位、公告及前台查詢入口。
9. 驗證匯入重試、逆序批次、同一 batch key 重試、併發匯入及 transaction rollback；不得刪除原始回覆來恢復紀錄。
10. 備份正式資料庫並核對正式環境 schema、權限與網站部署設定。取得正式遷移及合併核准後，才可部署；部署後做唯讀驗收。

## 必測登記規則

- 會員 A 羽球一場、籃球一場且時段不重疊：兩筆有效。
- A 同一份回覆選羽球兩場：兩筆各自待人工確認。
- A 同一份回覆選羽球與籃球重疊：兩筆各自待人工確認，可分別確認有效/無效。
- A 同一週同時段跨運動類型：較早提交有效，後提交待人工確認。
- 兩個不同回覆的提交時間相同且互相衝突：雙方各自待人工確認。
- A 羽球與桌球同日重疊：依提交先後檢核，後筆待人工確認。
- A 桌球不同場次：允許；同場次重複：後筆待人工確認。
- 會員 A 與 B 同時段：均可登記並依名額抽籤。
- 會館會員共用聯絡手機但會員識別不同：不得視為同一會員。
- 第二次提交先匯入、第一次提交後匯入：依表單提交時間判斷，不依匯入順序。
- 同一檔案、同一 batch key 重試：不重複新增；已保留回覆但缺少場次時要補回。
- 異常待確認：不得匯出正式名單或執行任何抽籤入口。
- 確認無效：該登記排除，且不得再占用該會員的有效名額。
- 確認有效：不豁免登記硬性限制；若兩筆確認有效仍互相衝突，伺服器拒絕抽籤，需將不合資格的登記確認無效。
- 任何缺少伺服器 `member_key_hash` 或表單來源鍵的登記：不得進入 v16 抽籤名單。

## 本分支離線驗證

- `node --test tests/v16_parser.test.cjs`：11 項合成資料測試通過，執行實際 `admin.html` parser，包含全形時間、星期標籤、桌球跨球類撞時段及超出時鐘範圍的時段。
- 抽取前後台 inline JavaScript 後執行 `node --check`：通過。
- `npm test`：42 項通過（23 項本機資料庫、8 項後台、11 項 parser）。本機執行捕捉並修正 PL/pgSQL CASE 比較語法錯誤。
- 匯入與跨批次異常檢核現於同一交易執行；測試確認檢核失敗時整批回滾、重試不重複、可補回缺少場次而不刪原始回覆。
- 初次結果匯入、單場及批次內建抽籤改走管理員 Auth RPC，核對名單快照、完整場次、名額、候補順位並原子寫入。人工修改、遞補及公告尚未遷移。
- 本機 Auth 與會員 HMAC 使用測試替身；不代表 Supabase 真實 Auth、PostgREST、RLS、併發或瀏覽器端到端通過。詳見 `tests/README.md`。

## 未解除的正式上線阻擋

- 正式 `lottery_records`、`admin_users`、`lottery_capacity_settings`、`system_settings`、`admin_operation_logs` 仍有匿名或 public 存取政策/權限；完整情形見 `V16_SECURITY_BLOCKERS.md`。
- 主後台仍以瀏覽器讀取帳密雜湊並用 `sessionStorage` 保存登入狀態，且操作透過公開 client 直接寫表。
- 前台仍以匿名 `.select('*')`、直接新增及刪除 `lottery_records`；停用後台 `replaceAll()` 不會停用 Data API 權限。
- 需要設計並驗證前台安全登記/個人查詢與管理員授權 API，再配對調整資料庫 grants/RLS；目前尚未準備完成。
- 三份 SQL 已通過本機合成資料測試，但尚未於完整 Supabase schema/API 驗收。未建立任何雲端 development branch 或付費服務。
- 真正的 v16 Google 表單匯出 XLSX 尚未完成端到端驗證。

> PR #1 已有本機測試，仍未完成上線驗收。不得合併、正式部署或把任何候選 SQL 直接套用正式專案。

## 唯讀資料恢復備註

正式資料庫保留 6 份原始回覆，但 `lottery_records` 為 0 筆。應在隔離 staging 用合成資料先證明既有 submission 可安全補建缺少的 record；正式資料不得刪除或重置。正式重匯/修復須先核准、備份並依單一執行方案辦理。
