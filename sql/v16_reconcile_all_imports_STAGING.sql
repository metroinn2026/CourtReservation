-- v16 per-member reconciliation across ALL imported batches.
-- Install only in staging first; requires lottery_import_admins, lottery_records,
-- lottery_form_submissions and lottery_import_anomalies tables.
-- Keep original import_google_form_batch() and all source rows unchanged.
BEGIN;
CREATE OR REPLACE FUNCTION public.court_v16_slots_overlap(p_a text,p_b text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_temp AS $$
DECLARE a text[]; b text[]; a0 int; a1 int; b0 int; b1 int;
BEGIN
  a:=regexp_match(coalesce(p_a,''),'([0-9]{1,2}):([0-9]{2})[^0-9]+([0-9]{1,2}):([0-9]{2})');
  b:=regexp_match(coalesce(p_b,''),'([0-9]{1,2}):([0-9]{2})[^0-9]+([0-9]{1,2}):([0-9]{2})');
  IF a IS NULL OR b IS NULL THEN RETURN NULL; END IF;
  a0:=a[1]::int*60+a[2]::int; a1:=a[3]::int*60+a[4]::int;
  b0:=b[1]::int*60+b[2]::int; b1:=b[3]::int*60+b[4]::int;
  IF a0>=a1 OR b0>=b1 THEN RETURN NULL; END IF;
  RETURN a0<b1 AND b0<a1;
END $$;
CREATE OR REPLACE FUNCTION public.court_v16_reconcile_import_anomalies()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,private,extensions,pg_temp AS $$
DECLARE
  v_uid uuid:=auth.uid();
  v_member text; v_rec record; v_peer record; v_prev jsonb;
  v_accepted jsonb; v_type text; v_detail text;
  v_added integer:=0; v_checked integer:=0; v_same_submission boolean;
BEGIN
  IF v_uid IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.lottery_import_admins WHERE user_id=v_uid
  ) THEN RAISE EXCEPTION 'not authorized'; END IF;
  FOR v_member IN
    SELECT DISTINCT member_key_hash FROM public.lottery_records
    WHERE member_key_hash IS NOT NULL AND import_submission_key IS NOT NULL
  LOOP
    v_checked:=v_checked+1;
    v_accepted:='[]'::jsonb;
    FOR v_rec IN
      SELECT r.*,s.batch_id FROM public.lottery_records r
      JOIN public.lottery_form_submissions s ON s.submission_key=r.import_submission_key
      WHERE r.member_key_hash=v_member AND r.import_record_key IS NOT NULL
      ORDER BY r.registered_at,r.id
    LOOP
      v_type:=NULL; v_detail:=NULL;
      -- If two sports overlap inside one form submission, neither item has
      -- an earlier submission timestamp. BOTH require manual adjudication.
      FOR v_peer IN
        SELECT p.venue_type,p.day_of_week,p.time_slot,p.import_record_key
        FROM public.lottery_records p
        WHERE p.import_submission_key=v_rec.import_submission_key
          AND p.import_record_key IS DISTINCT FROM v_rec.import_record_key
      LOOP
        IF v_peer.day_of_week=v_rec.day_of_week
           AND v_peer.venue_type<>v_rec.venue_type
           AND public.court_v16_slots_overlap(v_peer.time_slot,v_rec.time_slot) IS NOT FALSE
        THEN
          v_type:='同一回覆跨球類時段衝突（雙方待人工確認）';
          v_detail:='另一筆：'||v_peer.venue_type||' '||v_peer.time_slot;
          EXIT;
        END IF;
      END LOOP;
      -- Only previously accepted entries count against the one-per-sport rule.
      IF v_type IS NULL THEN
        FOR v_prev IN SELECT value FROM jsonb_array_elements(v_accepted)
        LOOP
          IF v_prev->>'venue'=v_rec.venue_type
             AND v_rec.venue_type IN ('羽球','籃球') THEN
            v_type:=v_rec.venue_type||'每位會員超過1場（後筆）';
          ELSIF v_prev->>'venue'=v_rec.venue_type
             AND v_prev->>'day'=v_rec.day_of_week
             AND v_prev->>'slot'=v_rec.time_slot THEN
            v_type:='同一會員重複申請相同場次（後筆）';
          ELSIF v_prev->>'venue'<>v_rec.venue_type
            AND v_prev->>'day'=v_rec.day_of_week
            AND public.court_v16_slots_overlap(v_prev->>'slot',v_rec.time_slot) IS NOT FALSE
          THEN
            v_type:='同會員同日期同時段跨球類重複（後筆）';
          END IF;
          IF v_type IS NOT NULL THEN
            v_detail:='較早登記：'||(v_prev->>'venue')||' '||
              (v_prev->>'day')||' '||(v_prev->>'slot');
            EXIT;
          END IF;
        END LOOP;
      END IF;
      IF v_type IS NOT NULL THEN
        IF NOT EXISTS (
          SELECT 1 FROM public.lottery_import_anomalies a
          WHERE a.anomaly_type=v_type
            AND a.record_keys @> ARRAY[v_rec.import_record_key]::text[]
        ) THEN
          INSERT INTO public.lottery_import_anomalies
            (batch_id,anomaly_type,detail,submission_keys,record_keys)
          VALUES (v_rec.batch_id,v_type,v_detail,
            ARRAY[v_rec.import_submission_key]::text[],
            ARRAY[v_rec.import_record_key]::text[]);
          v_added:=v_added+1;
        END IF;
      ELSE
        -- A record explicitly ruled invalid never occupies a valid slot.
        IF NOT EXISTS (
          SELECT 1 FROM public.lottery_import_anomalies a
          WHERE a.resolution_status='invalid'
            AND a.record_keys @> ARRAY[v_rec.import_record_key]::text[]
        ) THEN
          v_accepted:=v_accepted||jsonb_build_array(jsonb_build_object(
            'venue',v_rec.venue_type,'day',v_rec.day_of_week,
            'slot',v_rec.time_slot,'record',v_rec.import_record_key
          ));
        END IF;
      END IF;
    END LOOP;
  END LOOP;
  RETURN jsonb_build_object('members_checked',v_checked,'anomalies_added',v_added);
END $$;
REVOKE ALL ON FUNCTION public.court_v16_reconcile_import_anomalies() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.court_v16_reconcile_import_anomalies() TO authenticated;
COMMIT;
-- Staging smoke test (requires a signed-in import administrator):
-- select public.court_v16_reconcile_import_anomalies();
