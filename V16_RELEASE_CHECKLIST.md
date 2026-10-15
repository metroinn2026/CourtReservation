# v16 抽籤系統變更與驗收（草稿）

## 不可跳過的部署順序
1. 備份 Supabase 資料庫（包含 lottery_records、lottery_form_submissions、lottery_import_anomalies）。
2. 使用獨立 Supabase 測試專案及測試 Vercel 環境進行測試。
3. 在測試資料庫查驗 SQL 索引與 RLS、執行 v16_registration_unique_index_migration.sql。
4. 在測試環境安裝 `sql/v16_reconcile_all_imports_STAGING.sql`。此 SQL 尚未連線驗證，請先測試跨批次、逆序匯入及併發寫入；不能直接套用正式環境。
5. 匯入人工合成的 v16 Google 表單回覆檔；確認回覆和紀錄分開儲存、異常可人工確認。
6. 驗證異常 pending 時所有抽籤/匯出入口都拒絕作業、invalid 已排除、valid 可納入。
7. 驗證抽籤結果 Excel 匯入、候補順位、公告及前台查詢。
8. 再核對 staging DB 與 production DB 的 schema、auth 權限和 Vercel 環境變數。
9. 主管或管理者核可後才可正式資料庫遷移與合併 PR，部署後再做只讀驗收。

## 驗收情境
- 會員 A 羽球一場+籃球一場，不同時段：皆有效
- A 羽球兩場：後筆待人工確認
- A 同週同時段羽球與籃球，先後兩次回覆：後筆待人工確認
- A 同份回覆選到羽球與籃球相撞：兩筆待人工確認
- A 羽球 18:00–20:00，桌球 19:00–20:00：後筆待人工確認
- A 桌球不同場次：允許
- A 同桌球場同星期同時段再送一份：後筆異常
- A 與 B 同時段：都可以登記、等待正常抽籤
- 會館會員 A/B 共用聯絡手機，但識別不同：不應當作同一會員
- A 的第二次提交先匯入，第一次提交後匯入：應以原表單時間先後決定，不能依匯入先後
- 重複匯入同一 Excel：應跳過重複資料
- 多個管理員同時匯入：應維持一致性與批次交易原子性
- 異常尚未完成複核：不得下載正式抽籤名單、不得內建抽籤
- 無效異常結案：對應的登記不可進入抽籤名單
- 正常資料的抽籤結果可以批次匯入、查詢和公布

## 尚未解決的風險
- Google 表單 v16 的實際回覆試算表欄位，需要與這版 parser 實際比對。
- `sql/v16_reconcile_all_imports_STAGING.sql` 是跨批次檢核候選版本，尚未在 Supabase staging 實際驗證，不可直接部署。
- 既有抽籤結果匯入入口未完成資格檢核全覆蓋。
- 正式 Supabase 沒有連線權限，無法宣稱已通過資料庫驗收。
- 網站 HTML 中有歷史功能，須在測試環境做完整操作驗證。

> 請勿將草稿 PR 合併或將 SQL 草稿直接套用正式資料庫。

## 2026-10-15 Supabase 唯讀實際查核
- 目前連線專案 `metroinn2026's Project` 有 3 批歷史匯入、共 6 份原始回覆；批次統計曾記錄 12 筆場次，但 `lottery_records` 目前為 0 筆。
- 沒有 Supabase development branches；正式專案未修改。
- 舊唯一索引 `lottery_records_unique_limited_sports` 仍存在。
- `import_record_key` 去重唯一索引存在。
- **重新匯入同一份回覆時，現有 `import_google_form_batch` 會因為 submission_key 已存在而略過整份回覆；即使對應 `lottery_records` 已清空，也不會補回。** 這是 release blocker，必須在伺服器函式中修正或制定明確修復流程，不可刪除原始回覆來規避。
- `resolve_google_form_anomaly` 目前只更新異常狀態，不會清除不合格申請。
- 此次唯讀查詢未接觸會員姓名、完整身分識別或手機。
