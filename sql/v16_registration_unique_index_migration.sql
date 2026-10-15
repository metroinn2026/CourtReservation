-- CourtReservation v16: 索引遷移（需先備份並在測試環境驗證）
-- 允許匯入重複登記供人工檢核；保留 submission_key 與 import_record_key 的去重機制。
BEGIN;
DO $$
DECLARE v_def text;
BEGIN
 SELECT indexdef INTO v_def FROM pg_indexes
 WHERE schemaname='public' AND tablename='lottery_records'
 AND indexname='lottery_records_unique_limited_sports';
 IF v_def IS NULL OR v_def NOT LIKE '%(phone, id_last4, venue_type)%'
 OR v_def NOT ILIKE '%UNIQUE INDEX%' THEN
  RAISE EXCEPTION '舊唯一索引不符合預期，已停止遷移';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='public'
 AND tablename='lottery_records' AND indexname='lottery_records_import_record_key_uq') THEN
  RAISE EXCEPTION '缺少 import_record_key 去重索引，已停止遷移';
 END IF;
END $$;
CREATE INDEX IF NOT EXISTS lottery_records_member_sport_lookup_idx
 ON public.lottery_records(phone,id_last4,venue_type);
DROP INDEX public.lottery_records_unique_limited_sports;
COMMIT;
-- 以下僅驗證，不修改
SELECT indexname,indexdef FROM pg_indexes WHERE schemaname='public'
 AND tablename='lottery_records'
 AND indexname IN ('lottery_records_unique_limited_sports',
 'lottery_records_member_sport_lookup_idx','lottery_records_import_record_key_uq');
