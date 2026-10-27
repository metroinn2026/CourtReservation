# 北投會館運動場域系統｜資料安全改造進度

## 已完成（2026-10-27）
- 完成現行登入與權限初步盤點：目前 admin.html 的一般後台登入是讀取 public.admin_users 並在瀏覽器驗證，不能當作 Supabase RLS 的身分依據。
- 確認現有 68 筆 lottery_records；正式紀錄未改寫。
- Supabase 建立 private.lottery_secure_contacts_v1 加密欄位預備表：name_ciphertext、phone_ciphertext、email_ciphertext、member_id_ciphertext、phone_lookup_digest、encryption_key_version。
- 啟用 RLS、撤銷 anon/authenticated/PUBLIC 的直接資料表權限，驗證兩角色均不能讀取，現有 0 筆待遷移資料。
- 未寫入金鑰、未放置明文、未執行既有個資轉換，避免改壞現有系統。

## 下一階段必要工作（未完成）
1. **後台帳號遷移：** 先盤點 admin_users 的帳號並建立 Supabase Auth 身分關聯，由已驗證且獲授權的管理員操作；不可在瀏覽器自行查密碼雜湊。
2. **API/RLS 轉換：** 目前 lottery_records、admin_users 存在匿名存取政策；切換前盤點前台公告、查詢、後台增刪改、抽籤匯入等所有依賴，使用後端受驗證權限代替，測試後撤銷匿名權限。
3. **加密服務：** 將加解密限定到後端，金鑰配置於安全的環境／金鑰管理服務，不寫入 GitHub、HTML 或一般資料表。設計受保護的手機比對索引、金鑰版本及輪替程序。
4. **遷移與驗證：** 先產生可回復備份並在測試環境驗證匯入、重複申請判斷、資格審查、抽籤及 Excel 匯出；將舊資料遷移至加密儲存並逐筆核對後，再移除可匿名查閱的個資明文。
5. **角色權限：** 一般承辦人經認證後可見完整手機及 Email；完整身分證字號維持額外授權；匯入及刪除另依角色控管。

## 重要限制
本次僅安全建置「空的加密儲存結構」，**尚未代表所有資料已加密或正式系統已符合資安要求**。不要在現有匿名依賴仍在時直接撤銷資料表權限，否則會中斷業務。
