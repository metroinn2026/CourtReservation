# v16 正式上線阻擋項目（實際 Supabase 唯讀驗證）

## 嚴重：正式資料庫直接匿名 CRUD
截至 2026-10-16，正式專案 `wsvsdwuksuzcjisnpyin` 的 `lottery_records` RLS 設定包含：
- `allow public read`：`anon SELECT USING(true)`
- `allow public insert`：`anon INSERT`，無申請資格的伺服器驗證
- `allow public delete`：`anon DELETE USING(true)`
- `Allow update lottery records`：`public UPDATE USING(true)`

`index.html` 使用公開 publishable key + 匿名 `.select('*')`、`.insert()`、`.delete()`；
`admin.html` 也以直接資料表 CRUD 操作抽籤結果。這意味着任何取得公開連線方式的人可能不經過介面資格檢查而變更、刪除、檢視登記與個資。

**不可直接 DROP POLICY**：前後台現有操作依賴這些匿名權限，直接停用將造成網站功能故障。

## 正式上線前必須實作
1. 會員自助登記改經有身分驗證、授權檢核與欄位白名單的安全 RPC / Edge Function；匿名不可直接寫入抽籤結果欄位。
2. 取消前台可直接 SELECT * 讀取其他會員的姓名、手機與證件末四碼；改為個人限定查詢或僅回傳統計資料。
3. 管理員新增/刪除登記、匯入結果、發布結果需使用伺服器授權角色與稽核紀錄。
4. 權限遷移需與網站更新同時部署；先 staging 驗證所有 CRUD，再移除寬鬆的 RLS policies。
5. 跨批次同會員資格比對及異常審核須在資料庫層一致實施；瀏覽器不能是唯一安全控制。

## 其他未通過
- 三份 v16 SQL 尚未在隔離測試資料庫整合驗證。
- 舊 6 份回覆仍在，歷史統計 12 場次，現在 `lottery_records=0`。
- v16 Google 表單真實 XLSX 欄位與所有公告/抽籤途徑尚未通過端到端測試。

**狀態：禁止合併 / 正式部署。這份檔案不包含任何實際會員個資或 API 密鑰。**
