-- v16 server-side validation after import. DRAFT: run only after staging verification.
-- This guards imports across workbook batches using member_key_hash.
-- Requires existing tables: lottery_records, lottery_form_submissions, lottery_import_anomalies.
-- Idempotent migration and preserves all records, including those flagged as pending.
BEGIN;
CREATE OR REPLACE FUNCTION public.court_v16_flag_import_conflicts()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_batch_id uuid;
  v_previous public.lottery_records%ROWTYPE;
  v_type text;
  v_detail text;
  v_start int;
  v_end int;
  v_prev_start int;
  v_prev_end int;
BEGIN
  IF NEW.import_record_key IS NULL OR NEW.import_submission_key IS NULL
    OR NEW.member_key_hash IS NULL THEN RETURN NEW; END IF;
  SELECT batch_id INTO v_batch_id FROM public.lottery_form_submissions
  WHERE submission_key=NEW.import_submission_key;
  IF v_batch_id IS NULL THEN RETURN NEW; END IF;
  -- Same member and sport: the first registered record holds the one allowed slot.
  IF NEW.venue_type IN ('羽球','籃球') THEN
    SELECT * INTO v_previous FROM public.lottery_records r
    WHERE r.member_key_hash=NEW.member_key_hash
      AND r.venue_type=NEW.venue_type AND r.id<>NEW.id
      AND (r.registered_at,r.id)<(NEW.registered_at,NEW.id)
    ORDER BY r.registered_at,r.id LIMIT 1;
    IF FOUND THEN
      v_type:=NEW.venue_type||'每位會員超過1場（後筆）';
      v_detail:='較早登記：'||coalesce(v_previous.day_of_week,'')||' '||coalesce(v_previous.time_slot,'');
    END IF;
  END IF;
  IF v_type IS NULL THEN
    -- Weekly recurring rental: compare weekday plus actual overlapping time intervals,
    -- not merely equal time-slot strings.
    v_start:=substring(NEW.time_slot from '^([0-9]{1,2})')::int *60+
             substring(NEW.time_slot from '^[0-9]{1,2}:([0-9]{2})')::int;
    v_end:=substring(NEW.time_slot from '[-–~]([0-9]{1,2}):')::int *60+
           substring(NEW.time_slot from '[-–~][0-9]{1,2}:([0-9]{2})$')::int;
    FOR v_previous IN SELECT * FROM public.lottery_records r
      WHERE r.member_key_hash=NEW.member_key_hash
        AND r.day_of_week=NEW.day_of_week
        AND r.venue_type<>NEW.venue_type
        AND r.id<>NEW.id
        AND (r.registered_at,r.id)<(NEW.registered_at,NEW.id)
      ORDER BY r.registered_at,r.id LOOP
      v_prev_start:=substring(v_previous.time_slot from '^([0-9]{1,2})')::int*60+
                    substring(v_previous.time_slot from '^[0-9]{1,2}:([0-9]{2})')::int;
      v_prev_end:=substring(v_previous.time_slot from '[-–~]([0-9]{1,2}):')::int*60+
                  substring(v_previous.time_slot from '[-–~][0-9]{1,2}:([0-9]{2})$')::int;
      IF v_start IS NOT NULL AND v_end IS NOT NULL
         AND v_prev_start IS NOT NULL AND v_prev_end IS NOT NULL
         AND v_start<v_prev_end AND v_prev_start<v_end THEN
        v_type:='同會員同日期同時段跨球類重複（後筆）';
        v_detail:='較早登記：'||coalesce(v_previous.venue_type,'')||' '||coalesce(v_previous.time_slot,'');
        EXIT;
      END IF;
    END LOOP;
  END IF;
  IF v_type IS NOT NULL THEN
    INSERT INTO public.lottery_import_anomalies
      (batch_id,anomaly_type,detail,submission_keys,record_keys)
    VALUES (v_batch_id,v_type,v_detail,ARRAY[NEW.import_submission_key],ARRAY[NEW.import_record_key]);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS court_v16_import_conflict_check ON public.lottery_records;
CREATE TRIGGER court_v16_import_conflict_check
 AFTER INSERT ON public.lottery_records
 FOR EACH ROW EXECUTE FUNCTION public.court_v16_flag_import_conflicts();
COMMIT;
