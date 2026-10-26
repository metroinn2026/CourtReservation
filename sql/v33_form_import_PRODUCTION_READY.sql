-- v33 three-form importer repair for the current production schema.
--
-- Safe properties:
--   * keeps all existing submissions, records, anomalies and audit history;
--   * replays are idempotent by submission_key / import_record_key;
--   * a replay can restore records missing from an older retained submission;
--   * sport_usage is validated independently from venue_type;
--   * full member identifiers are hashed server-side and removed from raw_payload;
--   * the optional legacy cross-batch reconciler runs only when installed.
--
-- Reviewed against production project wsvsdwuksuzcjisnpyin on 2026-10-26.
-- Apply as one transaction. Do not deploy tests/fixtures/schema.sql.

BEGIN;

DO $preflight$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'lottery_import_admins',
    'lottery_form_import_batches',
    'lottery_form_submissions',
    'lottery_records',
    'lottery_import_anomalies',
    'lottery_import_audit'
  ]
  LOOP
    IF pg_catalog.to_regclass('public.' || v_table) IS NULL THEN
      RAISE EXCEPTION 'required table public.% is missing', v_table;
    END IF;
  END LOOP;

  IF pg_catalog.to_regprocedure('private.secure_member_key_hash(text,text)') IS NULL THEN
    RAISE EXCEPTION 'private.secure_member_key_hash(text,text) is required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'lottery_records'
      AND indexname = 'lottery_records_import_record_key_uq'
  ) THEN
    RAISE EXCEPTION 'lottery_records_import_record_key_uq is required';
  END IF;
END
$preflight$;

ALTER TABLE public.lottery_records
  ADD COLUMN IF NOT EXISTS sport_usage text;

DO $sport_usage_constraint$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_constraint
    WHERE conname = 'lottery_records_sport_usage_ck'
      AND conrelid = 'public.lottery_records'::pg_catalog.regclass
  ) THEN
    ALTER TABLE public.lottery_records
      ADD CONSTRAINT lottery_records_sport_usage_ck
      CHECK (
        sport_usage IS NULL
        OR sport_usage IN ('羽球', '籃球', '匹克球', '桌球')
      ) NOT VALID;
  END IF;
END
$sport_usage_constraint$;

CREATE OR REPLACE FUNCTION public.import_google_form_batch(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_batch uuid;
  v_batch_key uuid;
  v_batch_was_existing boolean := false;
  v_source_name text;
  v_sub jsonb;
  v_rec jsonb;
  v_an jsonb;
  v_raw_payload jsonb;
  v_safe_payload jsonb;
  v_member_type text;
  v_identifier text;
  v_member_hash text;
  v_sport_usage text;
  v_sub_key text;
  v_rec_key text;
  v_submitted_at_text text;
  v_registered_at timestamptz;
  v_source record;
  v_existing_record record;
  v_time_parts text[];
  v_start_min integer;
  v_end_min integer;
  v_submission_count integer := 0;
  v_inserted integer := 0;
  v_duplicate_submissions integer := 0;
  v_duplicate_records integer := 0;
  v_anomalies_added integer := 0;
  v_submission_keys text[];
  v_record_keys text[];
  v_already_processed boolean;
  v_reconciled boolean := false;
BEGIN
  IF v_uid IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.lottery_import_admins a
    WHERE a.user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_payload IS NULL OR pg_catalog.jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'payload must be an object';
  END IF;
  IF pg_catalog.jsonb_typeof(COALESCE(p_payload->'submissions', '[]'::jsonb)) <> 'array'
     OR pg_catalog.jsonb_typeof(COALESCE(p_payload->'records', '[]'::jsonb)) <> 'array'
     OR pg_catalog.jsonb_typeof(COALESCE(p_payload->'anomalies', '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'submissions, records and anomalies must be arrays';
  END IF;

  v_batch_key := NULLIF(p_payload->>'batch_key', '')::uuid;
  IF v_batch_key IS NULL THEN
    RAISE EXCEPTION 'batch_key required';
  END IF;
  v_source_name := CASE p_payload->>'source_form_type'
    WHEN 'badminton' THEN 'Google Forms v33 - 羽球場'
    WHEN 'basketball' THEN 'Google Forms v33 - 籃球場'
    WHEN 'table_tennis' THEN 'Google Forms v33 - 桌球場'
    WHEN 'legacy' THEN 'Google Forms - 歷史表單'
    ELSE 'Google Forms XLSX'
  END;

  -- Serialize imports using the same lock key as the optional reconciliation flow.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('court_v16_form_import_reconcile', 0)
  );

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements(
      COALESCE(p_payload->'submissions', '[]'::jsonb)
    ) e(value)
    GROUP BY e.value->>'submission_key'
    HAVING NULLIF(e.value->>'submission_key', '') IS NULL
       OR pg_catalog.count(*) > 1
  ) THEN
    RAISE EXCEPTION 'submission_key missing or duplicated within payload';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements(
      COALESCE(p_payload->'records', '[]'::jsonb)
    ) e(value)
    GROUP BY e.value->>'record_key'
    HAVING NULLIF(e.value->>'record_key', '') IS NULL
       OR pg_catalog.count(*) > 1
  ) THEN
    RAISE EXCEPTION 'record_key missing or duplicated within payload';
  END IF;

  SELECT b.id
  INTO v_batch
  FROM public.lottery_form_import_batches b
  WHERE b.batch_key = v_batch_key
  FOR UPDATE;

  v_batch_was_existing := v_batch IS NOT NULL;
  IF v_batch IS NULL THEN
    INSERT INTO public.lottery_form_import_batches(
      batch_key, submitted_by, source_name
    )
    VALUES (v_batch_key, v_uid, v_source_name)
    RETURNING id INTO v_batch;
  END IF;

  FOR v_sub IN
    SELECT e.value
    FROM pg_catalog.jsonb_array_elements(
      COALESCE(p_payload->'submissions', '[]'::jsonb)
    ) e(value)
  LOOP
    v_sub_key := NULLIF(v_sub->>'submission_key', '');
    IF v_sub_key IS NULL THEN
      RAISE EXCEPTION 'missing submission_key';
    END IF;

    v_member_type := v_sub->>'member_type';
    v_identifier := pg_catalog.upper(
      pg_catalog.regexp_replace(
        COALESCE(v_sub->>'member_identifier', ''),
        '[[:space:]]', '', 'g'
      )
    );
    v_submitted_at_text := NULLIF(v_sub->>'submitted_at', '');

    IF (v_member_type = '北投會館會員' AND v_identifier !~ '^[A-Z][0-9]{9}$')
       OR (v_member_type = '台北捷運Go會員' AND v_identifier !~ '^09[0-9]{8}$')
       OR v_member_type NOT IN ('北投會館會員', '台北捷運Go會員')
       OR v_member_type IS NULL THEN
      RAISE EXCEPTION '會員識別格式錯誤，第 % 列', v_sub->>'excel_row';
    END IF;

    IF NULLIF(pg_catalog.btrim(COALESCE(v_sub->>'name', '')), '') IS NULL
       OR NULLIF(pg_catalog.btrim(COALESCE(v_sub->>'phone', '')), '') IS NULL
       OR NULLIF(pg_catalog.btrim(COALESCE(v_sub->>'email', '')), '') IS NULL THEN
      RAISE EXCEPTION '姓名、聯絡手機或電子郵件缺漏，第 % 列', v_sub->>'excel_row';
    END IF;
    IF v_sub->>'phone' !~ '^09[0-9]{8}$' THEN
      RAISE EXCEPTION '聯絡手機格式錯誤，第 % 列', v_sub->>'excel_row';
    END IF;
    IF v_member_type = '台北捷運Go會員'
       AND v_sub->>'phone' IS DISTINCT FROM v_identifier THEN
      RAISE EXCEPTION 'Go會員綁定手機與聯絡手機不一致，第 % 列', v_sub->>'excel_row';
    END IF;

    v_member_hash := private.secure_member_key_hash(v_member_type, v_identifier);
    v_raw_payload := COALESCE(v_sub->'raw_payload', '{}'::jsonb);
    IF pg_catalog.jsonb_typeof(v_raw_payload) <> 'object' THEN
      RAISE EXCEPTION 'raw_payload must be an object, row %', v_sub->>'excel_row';
    END IF;

    -- Defense in depth: never persist a full member identifier from the raw row.
    v_safe_payload := v_raw_payload
      - '北投會館會員身分證字號（10碼）'
      - '台北捷運Go會員綁定手機（10碼）'
      - '台北捷運Go App會員綁定手機（10碼）'
      - 'member_identifier'
      - 'id_number'
      - 'identity';

    INSERT INTO public.lottery_form_submissions(
      submission_key, batch_id, submitted_at_text, member_type,
      member_key_hash, member_identifier, applicant_name,
      contact_phone, contact_email, raw_payload, excel_row,
      identifier_hash_version
    )
    VALUES (
      v_sub_key, v_batch, v_submitted_at_text, v_member_type,
      v_member_hash, pg_catalog.right(v_identifier, 4), v_sub->>'name',
      v_sub->>'phone', v_sub->>'email', v_safe_payload,
      NULLIF(v_sub->>'excel_row', '')::integer, 'hmac-v1'
    )
    ON CONFLICT (submission_key) DO NOTHING;

    IF FOUND THEN
      v_submission_count := v_submission_count + 1;
    ELSE
      v_duplicate_submissions := v_duplicate_submissions + 1;
      IF NOT EXISTS (
        SELECT 1
        FROM public.lottery_form_submissions s
        WHERE s.submission_key = v_sub_key
          AND s.member_key_hash = v_member_hash
          AND s.member_type = v_member_type
          AND s.member_identifier = pg_catalog.right(v_identifier, 4)
          AND s.applicant_name IS NOT DISTINCT FROM v_sub->>'name'
          AND s.contact_phone IS NOT DISTINCT FROM v_sub->>'phone'
          AND s.contact_email IS NOT DISTINCT FROM v_sub->>'email'
          AND s.submitted_at_text IS NOT DISTINCT FROM v_submitted_at_text
      ) THEN
        RAISE EXCEPTION 'submission_key 與會員識別不一致，第 % 列', v_sub->>'excel_row';
      END IF;
    END IF;
  END LOOP;

  FOR v_rec IN
    SELECT e.value
    FROM pg_catalog.jsonb_array_elements(
      COALESCE(p_payload->'records', '[]'::jsonb)
    ) e(value)
  LOOP
    v_sub_key := NULLIF(v_rec->>'submission_key', '');
    v_rec_key := NULLIF(v_rec->>'record_key', '');
    IF v_rec_key IS NULL OR v_sub_key IS NULL THEN
      RAISE EXCEPTION 'record_key/submission_key required';
    END IF;

    -- Deliberately does not require s.batch_id = v_batch. Older failed imports
    -- retained the submission row but lost every corresponding lottery record.
    SELECT s.batch_id, s.member_type, s.member_key_hash, s.member_identifier,
           s.applicant_name, s.contact_phone, s.contact_email,
           s.submitted_at_text
    INTO v_source
    FROM public.lottery_form_submissions s
    WHERE s.submission_key = v_sub_key;
    IF NOT FOUND THEN
      RAISE EXCEPTION '找不到對應表單回覆：%', v_sub_key;
    END IF;

    IF v_source.member_type IS DISTINCT FROM v_rec->>'member_type'
       OR v_source.applicant_name IS DISTINCT FROM v_rec->>'name'
       OR v_source.contact_phone IS DISTINCT FROM v_rec->>'phone'
       OR v_source.member_identifier IS DISTINCT FROM v_rec->>'member_identifier_last4' THEN
      RAISE EXCEPTION '場次資料與原始回覆不一致：%', v_rec_key;
    END IF;

    IF v_source.submitted_at_text IS NULL
       OR NOT pg_catalog.pg_input_is_valid(
         v_source.submitted_at_text, 'timestamp with time zone'
       ) THEN
      RAISE EXCEPTION '原始回覆時間戳記無法辨識，不能安全排序：%', v_sub_key;
    END IF;
    v_registered_at := v_source.submitted_at_text::timestamptz;

    IF COALESCE(v_rec->>'venue_type', '') NOT IN (
         '羽球', '籃球', 'B1桌球', 'B2桌球'
       )
       OR COALESCE(v_rec->>'day_of_week', '') NOT IN (
         '周一', '周二', '周三', '周四', '周五', '周六', '周日'
       ) THEN
      RAISE EXCEPTION '運動類型或星期格式錯誤：%', v_rec_key;
    END IF;

    v_sport_usage := COALESCE(
      NULLIF(v_rec->>'sport_usage', ''),
      CASE v_rec->>'venue_type'
        WHEN '羽球' THEN '羽球'
        WHEN '籃球' THEN '籃球'
        ELSE '桌球'
      END
    );
    IF (v_rec->>'venue_type' = '羽球'
        AND v_sport_usage NOT IN ('羽球', '匹克球'))
       OR (v_rec->>'venue_type' = '籃球'
           AND v_sport_usage NOT IN ('籃球', '匹克球'))
       OR (v_rec->>'venue_type' IN ('B1桌球', 'B2桌球')
           AND v_sport_usage <> '桌球') THEN
      RAISE EXCEPTION '場地與運動用途不一致：%', v_rec_key;
    END IF;

    v_time_parts := pg_catalog.regexp_match(
      COALESCE(v_rec->>'time_slot', ''),
      '^\s*([0-9]{1,2}):([0-9]{2})\s*[-–~至]\s*([0-9]{1,2}):([0-9]{2})\s*$'
    );
    IF v_time_parts IS NULL THEN
      RAISE EXCEPTION '時段格式無法辨識：%', v_rec_key;
    END IF;
    IF v_time_parts[1]::integer NOT BETWEEN 0 AND 23
       OR v_time_parts[3]::integer NOT BETWEEN 0 AND 23
       OR v_time_parts[2]::integer NOT BETWEEN 0 AND 59
       OR v_time_parts[4]::integer NOT BETWEEN 0 AND 59 THEN
      RAISE EXCEPTION '時段時間超出範圍：%', v_rec_key;
    END IF;
    v_start_min := v_time_parts[1]::integer * 60
      + v_time_parts[2]::integer;
    v_end_min := v_time_parts[3]::integer * 60
      + v_time_parts[4]::integer;
    IF v_start_min >= v_end_min THEN
      RAISE EXCEPTION '時段結束時間需晚於開始時間：%', v_rec_key;
    END IF;

    SELECT r.id, r.import_submission_key, r.venue_type, r.sport_usage,
           r.day_of_week, r.time_slot, r.member_key_hash, r.member_type,
           r.member_identifier_last4, r.id_last4, r.location_name,
           r.serial_number, r.name, r.phone, r.registered_at
    INTO v_existing_record
    FROM public.lottery_records r
    WHERE r.import_record_key = v_rec_key;

    IF FOUND THEN
      IF v_existing_record.import_submission_key IS DISTINCT FROM v_sub_key
         OR v_existing_record.venue_type IS DISTINCT FROM v_rec->>'venue_type'
         OR v_existing_record.sport_usage IS DISTINCT FROM v_sport_usage
         OR v_existing_record.day_of_week IS DISTINCT FROM v_rec->>'day_of_week'
         OR v_existing_record.time_slot IS DISTINCT FROM v_rec->>'time_slot'
         OR v_existing_record.member_key_hash IS DISTINCT FROM v_source.member_key_hash
         OR v_existing_record.member_type IS DISTINCT FROM v_source.member_type
         OR v_existing_record.member_identifier_last4 IS DISTINCT FROM v_source.member_identifier
         OR v_existing_record.id_last4 IS DISTINCT FROM (
           CASE WHEN v_source.member_type = '北投會館會員'
             THEN v_source.member_identifier ELSE '' END
         )
         OR v_existing_record.location_name IS DISTINCT FROM COALESCE(
           NULLIF(v_rec->>'location_name', ''), '北投會館'
         )
         OR v_existing_record.serial_number IS DISTINCT FROM v_rec->>'serial_number'
         OR v_existing_record.name IS DISTINCT FROM v_rec->>'name'
         OR v_existing_record.phone IS DISTINCT FROM v_rec->>'phone'
         OR v_existing_record.registered_at IS DISTINCT FROM v_registered_at THEN
        RAISE EXCEPTION 'record_key 已存在但資料內容不一致：%', v_rec_key;
      END IF;
      v_duplicate_records := v_duplicate_records + 1;
      CONTINUE;
    END IF;

    INSERT INTO public.lottery_records(
      name, phone, id_last4, location_name, venue_type, sport_usage,
      day_of_week, time_slot, serial_number, registered_at,
      import_submission_key, import_record_key, member_type,
      member_key_hash, member_identifier_last4
    )
    VALUES (
      v_rec->>'name', v_rec->>'phone',
      CASE WHEN v_source.member_type = '北投會館會員'
        THEN v_source.member_identifier ELSE '' END,
      COALESCE(NULLIF(v_rec->>'location_name', ''), '北投會館'),
      v_rec->>'venue_type', v_sport_usage,
      v_rec->>'day_of_week', v_rec->>'time_slot',
      v_rec->>'serial_number', v_registered_at,
      v_sub_key, v_rec_key, v_source.member_type,
      v_source.member_key_hash, v_source.member_identifier
    )
    ON CONFLICT (import_record_key)
      WHERE import_record_key IS NOT NULL
      DO NOTHING;

    IF FOUND THEN
      v_inserted := v_inserted + 1;
    ELSE
      SELECT r.id, r.import_submission_key, r.venue_type, r.sport_usage,
             r.day_of_week, r.time_slot, r.member_key_hash, r.member_type,
             r.member_identifier_last4, r.id_last4, r.location_name,
             r.serial_number, r.name, r.phone, r.registered_at
      INTO v_existing_record
      FROM public.lottery_records r
      WHERE r.import_record_key = v_rec_key;

      IF NOT FOUND
         OR v_existing_record.import_submission_key IS DISTINCT FROM v_sub_key
         OR v_existing_record.venue_type IS DISTINCT FROM v_rec->>'venue_type'
         OR v_existing_record.sport_usage IS DISTINCT FROM v_sport_usage
         OR v_existing_record.day_of_week IS DISTINCT FROM v_rec->>'day_of_week'
         OR v_existing_record.time_slot IS DISTINCT FROM v_rec->>'time_slot'
         OR v_existing_record.member_key_hash IS DISTINCT FROM v_source.member_key_hash
         OR v_existing_record.member_type IS DISTINCT FROM v_source.member_type
         OR v_existing_record.member_identifier_last4 IS DISTINCT FROM v_source.member_identifier
         OR v_existing_record.id_last4 IS DISTINCT FROM (
           CASE WHEN v_source.member_type = '北投會館會員'
             THEN v_source.member_identifier ELSE '' END
         )
         OR v_existing_record.location_name IS DISTINCT FROM COALESCE(
           NULLIF(v_rec->>'location_name', ''), '北投會館'
         )
         OR v_existing_record.serial_number IS DISTINCT FROM v_rec->>'serial_number'
         OR v_existing_record.name IS DISTINCT FROM v_rec->>'name'
         OR v_existing_record.phone IS DISTINCT FROM v_rec->>'phone'
         OR v_existing_record.registered_at IS DISTINCT FROM v_registered_at THEN
        RAISE EXCEPTION 'record_key 衝突：%', v_rec_key;
      END IF;
      v_duplicate_records := v_duplicate_records + 1;
    END IF;
  END LOOP;

  FOR v_an IN
    SELECT e.value
    FROM pg_catalog.jsonb_array_elements(
      COALESCE(p_payload->'anomalies', '[]'::jsonb)
    ) e(value)
  LOOP
    SELECT COALESCE(
      pg_catalog.array_agg(x.value ORDER BY x.value),
      ARRAY[]::text[]
    )
    INTO v_submission_keys
    FROM pg_catalog.jsonb_array_elements_text(
      COALESCE(v_an->'submissionKeys', '[]'::jsonb)
    ) x(value);

    SELECT COALESCE(
      pg_catalog.array_agg(x.value ORDER BY x.value),
      ARRAY[]::text[]
    )
    INTO v_record_keys
    FROM pg_catalog.jsonb_array_elements_text(
      COALESCE(v_an->'recordKeys', '[]'::jsonb)
    ) x(value);

    IF pg_catalog.cardinality(v_submission_keys) = 0 THEN
      RAISE EXCEPTION 'anomaly must reference at least one saved submission';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM pg_catalog.unnest(v_submission_keys) k(value)
      WHERE NOT EXISTS (
        SELECT 1
        FROM public.lottery_form_submissions s
        WHERE s.submission_key = k.value
      )
    ) THEN
      RAISE EXCEPTION 'anomaly references an unknown submission';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM pg_catalog.unnest(v_record_keys) k(value)
      WHERE NOT EXISTS (
        SELECT 1
        FROM public.lottery_records r
        WHERE r.import_record_key = k.value
          AND r.import_submission_key = ANY(v_submission_keys)
      )
    ) THEN
      RAISE EXCEPTION 'anomaly references an unknown or unrelated record';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.lottery_import_anomalies a
      WHERE a.anomaly_type = COALESCE(
          NULLIF(v_an->>'type', ''), '未分類匯入異常'
        )
        AND a.submission_keys @> v_submission_keys
        AND v_submission_keys @> a.submission_keys
        AND a.record_keys @> v_record_keys
        AND v_record_keys @> a.record_keys
    ) THEN
      INSERT INTO public.lottery_import_anomalies(
        batch_id, anomaly_type, detail, submission_keys, record_keys
      )
      VALUES (
        v_batch,
        COALESCE(NULLIF(v_an->>'type', ''), '未分類匯入異常'),
        NULLIF(v_an->>'detail', ''),
        v_submission_keys,
        v_record_keys
      );
      v_anomalies_added := v_anomalies_added + 1;
    END IF;
  END LOOP;

  -- Some deployments do not yet contain the legacy reconciler. The importer is
  -- complete without it; when present, execute it in the same transaction.
  IF pg_catalog.to_regprocedure(
       'public.court_v16_reconcile_import_anomalies()'
     ) IS NOT NULL THEN
    EXECUTE 'SELECT public.court_v16_reconcile_import_anomalies()';
    v_reconciled := true;
  END IF;

  -- Recompute counts for the upload attempt and for older retained submissions
  -- whose missing records have just been restored.
  UPDATE public.lottery_form_import_batches b
  SET submission_count = (
        SELECT pg_catalog.count(*)
        FROM public.lottery_form_submissions s
        WHERE s.batch_id = b.id
      ),
      record_count = (
        SELECT pg_catalog.count(*)
        FROM public.lottery_records r
        JOIN public.lottery_form_submissions s
          ON s.submission_key = r.import_submission_key
        WHERE s.batch_id = b.id
      ),
      anomaly_count = (
        SELECT pg_catalog.count(*)
        FROM public.lottery_import_anomalies a
        WHERE a.batch_id = b.id
      )
  WHERE b.id = v_batch
     OR b.id IN (
       SELECT s.batch_id
       FROM public.lottery_form_submissions s
       WHERE s.submission_key IN (
         SELECT e.value->>'submission_key'
         FROM pg_catalog.jsonb_array_elements(
           COALESCE(p_payload->'submissions', '[]'::jsonb)
         ) e(value)
       )
     );

  v_already_processed := v_batch_was_existing
    AND v_submission_count = 0
    AND v_inserted = 0
    AND v_anomalies_added = 0;

  INSERT INTO public.lottery_import_audit(
    batch_id, actor_id, action, detail
  )
  VALUES (
    v_batch,
    v_uid,
    CASE WHEN v_batch_was_existing THEN 'import_replay' ELSE 'import' END,
    pg_catalog.jsonb_build_object(
      'source_name', v_source_name,
      'new_submissions', v_submission_count,
      'repeated_submissions', v_duplicate_submissions,
      'new_records', v_inserted,
      'repeated_records', v_duplicate_records,
      'new_anomalies', v_anomalies_added,
      'already_processed', v_already_processed,
      'reconciliation_performed', v_reconciled
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'batch_id', v_batch,
    'inserted_records', v_inserted,
    'duplicate_submissions', v_duplicate_submissions,
    'duplicate_records', v_duplicate_records,
    'anomalies_added', v_anomalies_added,
    'already_processed', v_already_processed,
    'reconciliation_performed', v_reconciled
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.import_google_form_batch(jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.import_google_form_batch(jsonb)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.import_google_form_batch(jsonb)
  TO service_role;

COMMIT;

-- Read-only postflight summary. Expected: function_security_definer = true,
-- search_path = {search_path=pg_catalog}, sport_usage column/index/constraint = true.
SELECT pg_catalog.jsonb_build_object(
  'function_security_definer', p.prosecdef,
  'function_settings', p.proconfig,
  'sport_usage_column', EXISTS (
    SELECT 1
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.table_name = 'lottery_records'
      AND c.column_name = 'sport_usage'
  ),
  'sport_usage_constraint', EXISTS (
    SELECT 1
    FROM pg_catalog.pg_constraint con
    WHERE con.conname = 'lottery_records_sport_usage_ck'
      AND con.conrelid = 'public.lottery_records'::pg_catalog.regclass
  ),
  'record_key_unique_index', EXISTS (
    SELECT 1
    FROM pg_catalog.pg_indexes i
    WHERE i.schemaname = 'public'
      AND i.tablename = 'lottery_records'
      AND i.indexname = 'lottery_records_import_record_key_uq'
  )
) AS v33_import_patch_status
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'import_google_form_batch'
  AND pg_catalog.pg_get_function_identity_arguments(p.oid) = 'p_payload jsonb';
