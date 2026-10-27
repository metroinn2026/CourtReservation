# Supabase Auth 正式切換前檢核（2026-10-27）

## 本次核對
- 已經在新版 Auth 測試入口使用權限檢查的 RPC：登記清單、Email、資格審查、刪除、抽籤狀態、名額、結果公布、文字設定、操作紀錄、管理員清單與停用。
- 新版登記資料的 CSV / 文字匯出已修正 Email 欄位條件，不再要求匯入權限才能輸出完整 Email；仍須登入已核准管理員。
- 管理員頁面移除危險的全表 DELETE SQL 提示。

## 尚待移除的匿名政策（只讀盤點，尚未變更）
- public.admin_users：anon SELECT/INSERT/UPDATE；舊登入仍依賴。
- public.lottery_records：anon SELECT/INSERT/DELETE + PUBLIC UPDATE；可能影響前台查詢與舊後台。
- public.lottery_capacity_settings：anon ALL；前台場次資料可能依賴 SELECT。
- public.system_settings：anon SELECT/INSERT/UPDATE；前台文案仍需 SELECT。
- public.admin_operation_logs：anon SELECT/INSERT。
- 以上設定代表新版 RPC 具備授權 **不等於** 舊路徑已被關閉；目前仍是正式環境主要風險。

## 切換前必要驗收
1. 明確區分前台匿名可見資料（僅非敏感場次、公告資訊）與後台個資，前台改用無個資的公開檢視層或 RPC。
2. 將所有後台資料寫入與操作紀錄都經過已核准管理員身分；確認可停用離職帳號並撤銷 session。
3. 準備至少一個 staff Supabase Auth 帳號，在不授權匯入／完整證號前提下驗證可看 Email、可處理異常、不可管理帳號。
4. 測試資料庫完整模擬：單筆與批次刪除、修改狀態、匯入抽籤結果、公布與取消公布、資格審查、名額設定，以及使用者恢復登入。
5. 備份並建立切換與回復計畫，再撤銷 anon 的敏感讀寫和過寬 PUBLIC UPDATE。
6. 確認安全授權切換完成後，再實施個資欄位加密及既有資料遷移。

**注意：本文件是現況紀錄，未宣稱已完成正式切換。請勿在前台相依檢查前，直接撤銷所有 anon SELECT。**
