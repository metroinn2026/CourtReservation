-- v16 member-rule reconciliation across every imported batch.
-- STAGING ONLY. Requires the v16 index migration and importer repair first.
-- Each manual anomaly is tied to one record so an administrator can adjudicate
-- each side of an ambiguous same-response conflict independently.
BEGIN;

CREATE OR REPLACE FUNCTION public.court_v16_slots_overlap(p_a text, p_b text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog
AS $function$
DECLARE
  a text[];
  b text[];
  a0 integer;
  a1 integer;
  b0 integer;
  b1 integer;
BEGIN
  a := pg_catalog.regexp_match(COALESCE(p_a, ''), '([0-9]{1,2}):([0-9]{2})[^0-9]+([0-9]{1,2}):([0-9]{2})');
  b := pg_catalog.regexp_match(COALESCE(p_b, ''), '([0-9]{1,2}):([0-9]{2})[^0-9]+([0-9]{1,2}):([0-9]{2})');
  IF a IS NULL OR b IS NULL THEN RETURN NULL; END IF;
  IF a[1]::integer NOT BETWEEN 0 AND 23 OR b[1]::integer NOT BETWEEN 0 AND 23
     OR a[3]::integer NOT BETWEEN 0 AND 23 OR b[3]::integer NOT BETWEEN 0 AND 23
     OR a[2]::integer NOT BETWEEN 0 AND 59 OR b[2]::integer NOT BETWEEN 0 AND 59
     OR a[4]::integer NOT BETWEEN 0 AND 59 OR b[4]::integer NOT BETWEEN 0 AND 59 THEN
    RETURN NULL;
  END IF;
  a0 := a[1]::integer * 60 + a[2]::integer;
  a1 := a[3]::integer * 60 + a[4]::integer;
  b0 := b[1]::integer * 60 + b[2]::integer;
  b1 := b[3]::integer * 60 + b[4]::integer;
  IF a0 >= a1 OR b0 >= b1 THEN RETURN NULL; END IF;
  RETURN a0 < b1 AND b0 < a1;
END;
$function$;

CREATE OR REPLACE FUNCTION public.court_v16_reconcile_import_anomalies()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_member text;
  v_rec record;
  v_peer record;
  v_prev jsonb;
  v_accepted jsonb;
  v_type text;
  v_detail text;
  v_internal_conflict boolean;
  v_pending boolean;
  v_invalid boolean;
  v_has_valid boolean;
  v_added integer := 0;
  v_checked integer := 0;
  v_orphan_count integer := 0;
  v_time_anomalies integer := 0;
BEGIN
  IF v_uid IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.lottery_import_admins a WHERE a.user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('court_v16_form_import_reconcile', 0)
  );

  SELECT pg_catalog.count(*) INTO v_orphan_count
  FROM public.lottery_records r
  LEFT JOIN public.lottery_form_submissions s ON s.submission_key = r.import_submission_key
  WHERE r.import_record_key IS NOT NULL AND r.member_key_hash IS NOT NULL
    AND s.submission_key IS NULL;
  IF v_orphan_count > 0 THEN
    RAISE EXCEPTION '% imported records have no retained form submission; reconciliation stopped', v_orphan_count;
  END IF;

  INSERT INTO public.lottery_import_anomalies(
    batch_id, anomaly_type, detail, submission_keys, record_keys
  )
  SELECT s.batch_id, '表單時間戳記無法辨識',
         '原始回覆時間缺漏或格式無法辨識，不能判定登記先後。',
         ARRAY[s.submission_key]::text[], ARRAY[r.import_record_key]::text[]
  FROM public.lottery_records r
  JOIN public.lottery_form_submissions s ON s.submission_key = r.import_submission_key
  WHERE r.import_record_key IS NOT NULL
    AND (s.submitted_at_text IS NULL
         OR NOT pg_catalog.pg_input_is_valid(s.submitted_at_text, 'timestamp with time zone'))
    AND NOT EXISTS (
      SELECT 1 FROM public.lottery_import_anomalies a
      WHERE a.anomaly_type = '表單時間戳記無法辨識'
        AND a.record_keys @> ARRAY[r.import_record_key]::text[]
    );
  GET DIAGNOSTICS v_time_anomalies = ROW_COUNT;
  v_added := v_added + v_time_anomalies;

  FOR v_member IN
    SELECT DISTINCT r.member_key_hash
    FROM public.lottery_records r
    WHERE r.member_key_hash IS NOT NULL
      AND r.import_record_key IS NOT NULL
      AND r.import_submission_key IS NOT NULL
    ORDER BY r.member_key_hash
  LOOP
    v_checked := v_checked + 1;
    v_accepted := '[]'::jsonb;

    FOR v_rec IN
      SELECT r.*, s.batch_id, s.submitted_at_text,
             CASE WHEN pg_catalog.pg_input_is_valid(s.submitted_at_text, 'timestamp with time zone')
                  THEN s.submitted_at_text::timestamptz ELSE NULL END AS source_submitted_at
      FROM public.lottery_records r
      JOIN public.lottery_form_submissions s ON s.submission_key = r.import_submission_key
      WHERE r.member_key_hash = v_member
        AND r.import_record_key IS NOT NULL
      ORDER BY source_submitted_at NULLS LAST, r.import_submission_key, r.import_record_key
    LOOP
      v_type := NULL;
      v_detail := NULL;
      v_internal_conflict := false;
      v_pending := false;
      v_invalid := false;
      v_has_valid := false;

      -- A same-response conflict has no reliable within-form order. Create a
      -- separate one-record anomaly for each side so staff can choose one valid.
      FOR v_peer IN
        SELECT p.venue_type, p.day_of_week, p.time_slot, p.import_record_key
        FROM public.lottery_records p
        WHERE p.import_submission_key = v_rec.import_submission_key
          AND p.member_key_hash = v_rec.member_key_hash
          AND p.import_record_key IS NOT NULL
          AND p.import_record_key IS DISTINCT FROM v_rec.import_record_key
      LOOP
        IF (v_rec.venue_type = v_peer.venue_type AND v_rec.venue_type IN ('羽球', '籃球'))
           OR (v_rec.venue_type = v_peer.venue_type
               AND v_rec.day_of_week = v_peer.day_of_week
               AND v_rec.time_slot = v_peer.time_slot)
           OR (v_rec.day_of_week = v_peer.day_of_week
               AND v_rec.venue_type <> v_peer.venue_type
               AND public.court_v16_slots_overlap(v_rec.time_slot, v_peer.time_slot) IS NOT FALSE) THEN
          v_internal_conflict := true;
          IF v_rec.venue_type <> v_peer.venue_type THEN
            v_type := '同一回覆跨球類時段衝突（雙方待人工確認）';
          ELSE
            v_type := '同一回覆登記衝突（雙方待人工確認）';
          END IF;
          v_detail := '同一表單回覆內無法判定先後；衝突場次：'
            || v_peer.venue_type || ' ' || v_peer.day_of_week || ' ' || v_peer.time_slot;
          EXIT;
        END IF;
      END LOOP;

      -- Separate form submissions with the same timestamp also have no
      -- provable order. Do not pick one by UUID or import order.
      IF NOT v_internal_conflict AND v_rec.source_submitted_at IS NOT NULL AND EXISTS (
        SELECT 1
        FROM public.lottery_records p
        JOIN public.lottery_form_submissions ps ON ps.submission_key = p.import_submission_key
        WHERE p.member_key_hash = v_member
          AND p.import_record_key IS NOT NULL
          AND p.import_submission_key IS DISTINCT FROM v_rec.import_submission_key
          AND CASE WHEN pg_catalog.pg_input_is_valid(ps.submitted_at_text, 'timestamp with time zone')
                   THEN ps.submitted_at_text::timestamptz ELSE NULL END = v_rec.source_submitted_at
          AND (
            (p.venue_type = v_rec.venue_type AND v_rec.venue_type IN ('羽球', '籃球'))
            OR (p.venue_type = v_rec.venue_type
                AND p.day_of_week = v_rec.day_of_week
                AND p.time_slot = v_rec.time_slot)
            OR (p.day_of_week = v_rec.day_of_week
                AND p.venue_type <> v_rec.venue_type
                AND public.court_v16_slots_overlap(p.time_slot, v_rec.time_slot) IS NOT FALSE)
          )
      ) THEN
        v_type := '同時間提交衝突（雙方待人工確認）';
        v_detail := '不同回覆的時間戳記相同，無法判定有效登記先後。';
      END IF;

      -- Compare against earlier records that have already been confirmed or
      -- have no unresolved anomaly. Invalid or pending records never consume a slot.
      IF v_type IS NULL THEN
        FOR v_prev IN SELECT e.value FROM pg_catalog.jsonb_array_elements(v_accepted) e(value)
        LOOP
          IF v_prev->>'venue' = v_rec.venue_type
             AND v_rec.venue_type IN ('羽球', '籃球') THEN
            v_type := v_rec.venue_type || '每位會員超過1場（後筆）';
          ELSIF v_prev->>'venue' = v_rec.venue_type
             AND v_prev->>'day' = v_rec.day_of_week
             AND v_prev->>'slot' = v_rec.time_slot THEN
            v_type := '同一會員重複申請相同場次（後筆）';
          ELSIF v_prev->>'venue' <> v_rec.venue_type
             AND v_prev->>'day' = v_rec.day_of_week
             AND public.court_v16_slots_overlap(v_prev->>'slot', v_rec.time_slot) IS NOT FALSE THEN
            v_type := '同會員同日期同時段跨球類重複（後筆）';
          END IF;
          IF v_type IS NOT NULL THEN
            v_detail := '較早登記：' || (v_prev->>'venue') || ' '
              || (v_prev->>'day') || ' ' || (v_prev->>'slot');
            EXIT;
          END IF;
        END LOOP;
      END IF;

      SELECT
        COALESCE(pg_catalog.bool_or(a.resolution_status = 'pending'), false),
        COALESCE(pg_catalog.bool_or(a.resolution_status = 'invalid'), false),
        COALESCE(pg_catalog.bool_or(a.resolution_status = 'valid' AND a.anomaly_type = v_type), false)
      INTO v_pending, v_invalid, v_has_valid
      FROM public.lottery_import_anomalies a
      WHERE a.record_keys @> ARRAY[v_rec.import_record_key]::text[]
         OR (pg_catalog.cardinality(a.record_keys) = 0
             AND a.submission_keys @> ARRAY[v_rec.import_submission_key]::text[]);

      IF v_type IS NOT NULL AND NOT v_pending AND NOT v_invalid AND NOT v_has_valid THEN
        IF NOT EXISTS (
          SELECT 1 FROM public.lottery_import_anomalies a
          WHERE a.anomaly_type = v_type
            AND a.record_keys @> ARRAY[v_rec.import_record_key]::text[]
        ) THEN
          INSERT INTO public.lottery_import_anomalies(
            batch_id, anomaly_type, detail, submission_keys, record_keys
          ) VALUES (
            v_rec.batch_id, v_type, v_detail,
            ARRAY[v_rec.import_submission_key]::text[],
            ARRAY[v_rec.import_record_key]::text[]
          );
          v_added := v_added + 1;
        END IF;
        v_pending := true;
      ELSIF v_type IS NOT NULL AND v_has_valid AND NOT v_pending AND NOT v_invalid THEN
        -- Explicit human confirmation wins over the automatic rule result.
        v_type := NULL;
      END IF;

      IF NOT v_pending AND NOT v_invalid AND v_type IS NULL THEN
        v_accepted := v_accepted || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
          'venue', v_rec.venue_type,
          'day', v_rec.day_of_week,
          'slot', v_rec.time_slot,
          'record', v_rec.import_record_key
        ));
      END IF;
    END LOOP;
  END LOOP;

  UPDATE public.lottery_form_import_batches b
  SET anomaly_count = (
    SELECT pg_catalog.count(*)
    FROM public.lottery_import_anomalies a
    WHERE a.batch_id = b.id
  )
  WHERE EXISTS (
    SELECT 1 FROM public.lottery_import_anomalies a
    WHERE a.batch_id = b.id
      AND a.created_at >= pg_catalog.transaction_timestamp()
  );

  RETURN pg_catalog.jsonb_build_object(
    'members_checked', v_checked,
    'anomalies_added', v_added
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_google_form_anomaly(p_anomaly_id uuid, p_status text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_batch uuid;
BEGIN
  IF v_uid IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.lottery_import_admins a WHERE a.user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('pending', 'valid', 'invalid') THEN
    RAISE EXCEPTION 'invalid status';
  END IF;

  SELECT a.batch_id INTO v_batch
  FROM public.lottery_import_anomalies a
  WHERE a.id = p_anomaly_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'anomaly not found'; END IF;

  UPDATE public.lottery_import_anomalies a
  SET resolution_status = p_status,
      resolved_by = CASE WHEN p_status = 'pending' THEN NULL ELSE v_uid END,
      resolved_at = CASE WHEN p_status = 'pending' THEN NULL ELSE pg_catalog.now() END
  WHERE a.id = p_anomaly_id;

  INSERT INTO public.lottery_import_audit(batch_id, anomaly_id, actor_id, action, detail)
  VALUES (v_batch, p_anomaly_id, v_uid, 'resolve', pg_catalog.jsonb_build_object('status', p_status));

  -- Re-evaluate downstream member rules after a human excludes or confirms a row.
  PERFORM public.court_v16_reconcile_import_anomalies();
  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.court_v16_slots_overlap(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.court_v16_slots_overlap(text, text) TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.court_v16_reconcile_import_anomalies() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.court_v16_reconcile_import_anomalies() TO authenticated;
GRANT EXECUTE ON FUNCTION public.court_v16_reconcile_import_anomalies() TO service_role;
REVOKE ALL ON FUNCTION public.resolve_google_form_anomaly(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_google_form_anomaly(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_google_form_anomaly(uuid, text) TO service_role;
COMMIT;

-- Staging smoke test, using a signed-in account present in lottery_import_admins:
-- select public.court_v16_reconcile_import_anomalies();
