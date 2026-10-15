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

  -- Always acquire the global lock before any row lock (same order as import).
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('court_v16_form_import_reconcile', 0)
  );

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

-- Public entry points are invoker functions; privileged implementations remain
-- in the non-exposed private schema and independently validate the Auth allowlist.
CREATE OR REPLACE FUNCTION private.court_v16_lottery_eligibility()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
DECLARE
  v_records jsonb;
  v_capacity jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.lottery_import_admins WHERE user_id = auth.uid()
  ) THEN RAISE EXCEPTION 'not authorized'; END IF;
  PERFORM public.court_v16_reconcile_import_anomalies();
  IF EXISTS (SELECT 1 FROM public.lottery_records r
    LEFT JOIN public.lottery_form_submissions s ON s.submission_key = r.import_submission_key
    WHERE NULLIF(r.member_key_hash,'') IS NULL OR NULLIF(r.import_record_key,'') IS NULL
      OR s.submission_key IS NULL OR r.member_key_hash IS DISTINCT FROM s.member_key_hash
      OR s.submitted_at_text IS NULL
      OR NOT pg_input_is_valid(s.submitted_at_text,'timestamp with time zone')
      OR public.court_v16_slots_overlap(r.time_slot,r.time_slot) IS NOT TRUE
      OR COALESCE(r.venue_type,'') NOT IN ('羽球','籃球','B1桌球','B2桌球')
      OR COALESCE(r.day_of_week,'') NOT IN ('周一','周二','周三','周四','周五','周六','周日')) THEN
    RAISE EXCEPTION '登記來源、會員識別或場次資料不完整，不能抽籤';
  END IF;
  IF EXISTS (SELECT 1 FROM public.lottery_import_anomalies
    WHERE COALESCE(resolution_status,'pending') NOT IN ('valid','invalid')) THEN
    RAISE EXCEPTION '尚有異常待人工確認，不能抽籤';
  END IF;

  -- A manual "valid" label cannot waive the actual one-sport/overlap limits.
  WITH eligible AS (
    SELECT r.* FROM public.lottery_records r WHERE NOT EXISTS (
      SELECT 1 FROM public.lottery_import_anomalies a WHERE a.resolution_status = 'invalid'
        AND (a.record_keys @> ARRAY[r.import_record_key] OR
          (cardinality(a.record_keys)=0 AND a.submission_keys @> ARRAY[r.import_submission_key]))
    )
  ) SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',r.id,'record_key',r.import_record_key,'member_key_hash',r.member_key_hash,
      'location_name',r.location_name,'venue_type',r.venue_type,'day_of_week',r.day_of_week,
      'time_slot',r.time_slot,'lottery_status',COALESCE(r.lottery_status,''),
      'lottery_locked',COALESCE(r.lottery_locked,false),'result_published',COALESCE(r.result_published,false),
      'eligible',e.id IS NOT NULL) ORDER BY r.id),'[]'::jsonb)
    INTO v_records FROM public.lottery_records r LEFT JOIN eligible e ON e.id=r.id;
  IF EXISTS (
    WITH eligible AS (
      SELECT r.* FROM public.lottery_records r WHERE NOT EXISTS (
        SELECT 1 FROM public.lottery_import_anomalies a WHERE a.resolution_status='invalid'
          AND (a.record_keys @> ARRAY[r.import_record_key] OR
            (cardinality(a.record_keys)=0 AND a.submission_keys @> ARRAY[r.import_submission_key]))
      )
    )
    SELECT 1 FROM eligible a JOIN eligible b ON a.member_key_hash=b.member_key_hash AND a.id<b.id
    WHERE (a.venue_type=b.venue_type AND a.venue_type IN ('羽球','籃球'))
      OR (a.venue_type=b.venue_type AND a.day_of_week=b.day_of_week AND a.time_slot=b.time_slot)
      OR (a.venue_type<>b.venue_type AND a.day_of_week=b.day_of_week
        AND public.court_v16_slots_overlap(a.time_slot,b.time_slot) IS NOT FALSE)
  ) THEN RAISE EXCEPTION '確認有效的登記仍有會員名額或時段衝突，請將不符合規則者確認無效'; END IF;
  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.venue_type,c.day_of_week,c.time_slot),'[]'::jsonb)
    INTO v_capacity FROM public.lottery_capacity_settings c;
  RETURN jsonb_build_object('records',v_records,'snapshot',md5(v_records::text || v_capacity::text));
END;
$function$;

CREATE OR REPLACE FUNCTION public.court_v16_lottery_eligibility()
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = pg_catalog
AS $function$ SELECT private.court_v16_lottery_eligibility() $function$;

CREATE OR REPLACE FUNCTION private.court_v16_commit_lottery_results(p_rows jsonb,p_snapshot text,p_batch text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
DECLARE
  v_state jsonb;
  v_stage record;
  v_cap integer;
  v_closed boolean;
  v_count integer;
  v_wait_count integer;
  v_wait_distinct integer;
  v_wait_max integer;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.lottery_import_admins WHERE user_id=auth.uid()
  ) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'results must be an array'; END IF;
  IF jsonb_array_length(p_rows) NOT BETWEEN 1 AND 10000 OR COALESCE(length(p_batch),0) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'invalid result count or batch label';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_rows) x
      WHERE jsonb_typeof(x) IS DISTINCT FROM 'object' OR NULLIF(x->>'id','') IS NULL
        OR COALESCE(x->>'status','') !~ '^(中籤|未中籤|候補[1-9][0-9]{0,4})$'
        OR (x - 'id' - 'status') <> '{}'::jsonb)
    OR (SELECT count(DISTINCT x->>'id') FROM jsonb_array_elements(p_rows) x) <> jsonb_array_length(p_rows) THEN
    RAISE EXCEPTION 'duplicate IDs or invalid result fields';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('court_v16_form_import_reconcile',0));
  -- Also serialize with legacy direct writes while the permission migration is pending.
  LOCK TABLE public.lottery_records,public.lottery_form_submissions,
    public.lottery_import_anomalies,public.lottery_capacity_settings IN SHARE ROW EXCLUSIVE MODE;
  v_state := private.court_v16_lottery_eligibility();
  IF p_snapshot IS DISTINCT FROM v_state->>'snapshot' THEN
    RAISE EXCEPTION '名單或名額已變更，請重新載入並確認結果';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_rows) x
    LEFT JOIN jsonb_array_elements(v_state->'records') r ON r->>'id'=x->>'id'
    WHERE r IS NULL OR (r->>'eligible')::boolean IS NOT TRUE
      OR (r->>'lottery_locked')::boolean OR (r->>'result_published')::boolean
      OR r->>'lottery_status'<>'') THEN
    RAISE EXCEPTION '結果含無效、不存在或已有結果的登記';
  END IF;
  -- Every affected stage must be complete; never silently write half a draw.
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_state->'records') r
    WHERE (r->>'eligible')::boolean
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_rows) x WHERE x->>'id'=r->>'id')
      AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_rows) x
        JOIN public.lottery_records t ON t.id=(x->>'id')::uuid
        WHERE t.location_name IS NOT DISTINCT FROM r->>'location_name'
          AND t.venue_type=r->>'venue_type' AND t.day_of_week=r->>'day_of_week' AND t.time_slot=r->>'time_slot')
  ) THEN RAISE EXCEPTION '抽籤結果未涵蓋該場次全部有效登記'; END IF;

  FOR v_stage IN SELECT DISTINCT r.location_name,r.venue_type,r.day_of_week,r.time_slot
    FROM public.lottery_records r JOIN jsonb_array_elements(p_rows) x ON r.id=(x->>'id')::uuid
  LOOP
    v_cap := NULL; v_closed := false;
    SELECT c.winner_count,c.is_closed INTO v_cap,v_closed FROM public.lottery_capacity_settings c
      WHERE c.venue_type=v_stage.venue_type AND c.day_of_week=v_stage.day_of_week
        AND c.time_slot IN (v_stage.time_slot,btrim(split_part(v_stage.time_slot,'-',1)))
      ORDER BY (c.time_slot=v_stage.time_slot) DESC LIMIT 1;
    v_cap := COALESCE(v_cap,CASE v_stage.venue_type WHEN '羽球' THEN 3 WHEN '籃球' THEN 1 WHEN 'B1桌球' THEN 5 WHEN 'B2桌球' THEN 4 END);
    SELECT count(*) FILTER (WHERE x->>'status'='中籤'),
      count(*) FILTER (WHERE x->>'status' LIKE '候補%'),
      count(DISTINCT x->>'status') FILTER (WHERE x->>'status' LIKE '候補%'),
      COALESCE(max(CASE WHEN x->>'status' LIKE '候補%' THEN substring(x->>'status' FROM 3)::integer END),0)
      INTO v_count,v_wait_count,v_wait_distinct,v_wait_max
      FROM jsonb_array_elements(p_rows) x JOIN public.lottery_records r ON r.id=(x->>'id')::uuid
      WHERE r.location_name IS NOT DISTINCT FROM v_stage.location_name AND r.venue_type=v_stage.venue_type
        AND r.day_of_week=v_stage.day_of_week AND r.time_slot=v_stage.time_slot;
    IF COALESCE(v_closed,false) OR v_cap<=0 OR v_count>v_cap THEN RAISE EXCEPTION '場次未開放或中籤人數超過名額'; END IF;
    IF v_wait_count<>v_wait_distinct OR v_wait_count<>v_wait_max THEN RAISE EXCEPTION '候補順位重複或不連續'; END IF;
  END LOOP;
  UPDATE public.lottery_records r SET lottery_status=x.status,lottery_locked=true,
    lottery_batch=p_batch,result_published=false,published_at=NULL,updated_at=now()
    FROM jsonb_to_recordset(p_rows) x(id uuid,status text) WHERE r.id=x.id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  INSERT INTO public.lottery_import_audit(batch_id,actor_id,action,detail)
    SELECT s.batch_id,auth.uid(),'commit_lottery_results',jsonb_build_object(
      'lottery_batch',p_batch,'snapshot',p_snapshot,'record_ids',jsonb_agg(r.id ORDER BY r.id))
    FROM public.lottery_records r JOIN public.lottery_form_submissions s ON s.submission_key=r.import_submission_key
    JOIN jsonb_array_elements(p_rows) x ON r.id=(x->>'id')::uuid GROUP BY s.batch_id;
  RETURN jsonb_build_object('updated_count',v_count);
END;
$function$;

CREATE OR REPLACE FUNCTION public.court_v16_commit_lottery_results(p_rows jsonb,p_snapshot text,p_batch text)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = pg_catalog
AS $function$ SELECT private.court_v16_commit_lottery_results(p_rows,p_snapshot,p_batch) $function$;

REVOKE ALL ON FUNCTION private.court_v16_lottery_eligibility(),
  private.court_v16_commit_lottery_results(jsonb,text,text),
  public.court_v16_lottery_eligibility(),public.court_v16_commit_lottery_results(jsonb,text,text) FROM PUBLIC,anon;
GRANT USAGE ON SCHEMA private TO authenticated;
GRANT EXECUTE ON FUNCTION private.court_v16_lottery_eligibility(),
  private.court_v16_commit_lottery_results(jsonb,text,text),
  public.court_v16_lottery_eligibility(),public.court_v16_commit_lottery_results(jsonb,text,text) TO authenticated;

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
