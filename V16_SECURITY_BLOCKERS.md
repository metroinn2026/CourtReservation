# v16 正式上線安全阻擋（2026-10-16 唯讀查核）

## 狀態

正式 Supabase 專案 `wsvsdwuksuzcjisnpyin` 的資料表政策、權限與函式尚未完成安全遷移。PR #1 仍未合併，正式資料庫未修改。**目前版本禁止合併或正式部署。**

查核沒有讀取會員姓名、聯絡方式、識別資料或 API key 值。

## 已確認的公開存取

### `lottery_records`

- `anon SELECT` 可讀取登記列；前台使用公開 publishable key 執行 `.select('*')`，欄位包含姓名、聯絡手機及識別末四碼。
- `anon INSERT` 可直接新增登記，繞過前端資格檢查。
- `anon DELETE` 可直接刪除登記。
- `public UPDATE` 的 `USING(true)` 與 `WITH CHECK(true)` 過度寬鬆。
- 資料表 grants 查核也顯示匿名及已登入角色對多張資料表仍有 CRUD 權限；RLS policy 與 grants 必須一併收斂。

### 其他資料表

- `admin_users` 有匿名讀取、新增及更新權限；欄位包含 `salt`、`password_hash`。目前主後台在瀏覽器讀取帳密雜湊、以 JavaScript 驗證，並將管理員資訊存於 `sessionStorage`。
- `lottery_capacity_settings` 允許匿名 `ALL`。
- `system_settings` 允許匿名讀取、新增及更新。
- `admin_operation_logs` 允許匿名讀取及新增。
- 匯入表部分已登入讀取政策使用 `lottery_import_admins` 限制，但仍須逐表核對 grants、政策及 RPC ACL。

前台已停用 `replaceAll()`，但那不會撤銷 Data API 的直接刪除權限。只改 UI 無法關閉上述通道。

## Supabase Security Advisor 查核

- `public.admin_login`、`public.admin_users_exist`：可由 `anon` 執行的 `SECURITY DEFINER` 函式。
- `public.bootstrap_first_super_admin`、`public.import_google_form_batch`、`public.resolve_google_form_anomaly`：可由 `authenticated` 執行的 `SECURITY DEFINER` 函式；須逐一驗證函式本文、owner、`search_path`、身分驗證及 EXECUTE ACL。候選 v16 匯入 SQL 已收緊其中兩個函式的 ACL，但尚未安裝。
- Supabase Auth 的 leaked password protection 目前關閉。
- `private.lottery_member_hash_secret` 有啟用 RLS、但沒有 policy 的資訊提示；需確認只允許受信任函式/角色讀取，不得為方便而開放匿名存取。

## 正式環境資料現況

- 3 個匯入批次、6 份保留的原始表單回覆、0 筆 `lottery_records`、0 筆異常紀錄；批次歷史統計曾記錄 12 筆場次。
- 唯讀查核確認仍有舊的 `lottery_records_unique_limited_sports` 唯一索引，且 `lottery_records_import_record_key_uq` 去重索引存在。
- 沒有建立 Supabase development branch，也沒有執行正式資料庫變更。

## 解除阻擋前必須完成

1. 將管理員登入及角色改為伺服器驗證，移除以瀏覽器讀取 `admin_users` 密碼雜湊及以 `sessionStorage` 作為授權依據的流程。
2. 將管理員 CRUD、抽籤結果匯入/更新、設定修改及公告發布改經有角色檢查、欄位白名單與稽核的伺服器 API/RPC/Edge Function。
3. 將民眾登記改經伺服器端資格驗證；公開查詢僅回傳完成業務所需的最少欄位，禁止全表 `SELECT *` 讀取其他會員資料。
4. 在隔離環境同步測試 API、RLS policies 及 table grants。確認功能均改走新 API 後，再以單一遷移撤除寬鬆權限；不可先 DROP 現有 policy。
5. 以匿名、一般已登入帳號、匯入管理員及管理員角色逐一測試讀取/新增/更新/刪除、匯入、異常確認、名單匯出、抽籤、結果匯入及公告查詢。
6. 重新執行 Supabase Security Advisor，處理匿名可執行的 `SECURITY DEFINER`、密碼保護設定及敏感 secret 存取。

## 未完成的功能驗收

- 三份候選 v16 SQL 尚未在隔離資料庫執行；不得視為 PostgreSQL 整合測試通過。
- 目前只有 11 項 parser 合成測試及前後台 JavaScript 語法檢查；真正的 v16 Google Forms XLSX、資料庫交易/重試、Excel 抽籤名單、結果匯入及公告流程尚未端到端驗證。
- 6 份原始回覆仍保留。須先在隔離環境證明可安全補回缺少的場次；不得刪除原始回覆來解除重複判定。

## 參考

- [Supabase：Securing your API](https://supabase.com/docs/guides/api/securing-your-api)
- [Supabase：Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)
