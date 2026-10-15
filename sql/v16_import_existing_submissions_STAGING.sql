-- v16 Google Form importer: preserve submissions and allow reconstitution
-- of missing records without deleting original submissions.
-- STAGING FIRST. Must run AFTER v16_registration_unique_index_migration.sql.
BEGIN;
CREATE OR REPLACE FUNCTION public.import_google_form_batch(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','private','extensions','pg_temp'
AS $function$
DECLARE
 v_uid uuid:=auth.uid();
 v_batch uuid; v_batch_key uuid:=(p_payload->>'batch_key')::uuid;
 v_sub jsonb; v_rec jsonb; v_an jsonb;
 v_member_type text; v_identifier text; v_member_hash text;
 v_sub_key text; v_rec_key text; v_existing_batch uuid;
 v_inserted integer:=0; v_duplicate integer:=0;
 v_submission_count integer:=0; v_anomaly_count integer:=0;
BEGIN
 IF v_uid IS NULL OR NOT EXISTS
   (SELECT 1 FROM public.lottery_import_admins WHERE user_id=v_uid)
 THEN RAISE EXCEPTION 'not authorized'; END IF;
 IF v_batch_key IS NULL THEN RAISE EXCEPTION 'batch_key required'; END IF;
 -- Serialize import operations, avoiding races between batches.
 PERFORM pg_advisory_xact_lock(hashtext('court_v16_form_import'));
 SELECT id INTO v_batch FROM public.lottery_form_import_batches
 WHERE batch_key=v_batch_key;
 IF v_batch IS NOT NULL THEN
  RETURN jsonb_build_object('batch_id',v_batch,'inserted_records',0,
    'duplicate_submissions',0,'already_processed',true);
 END IF;
 INSERT INTO public.lottery_form_import_batches(batch_key,submitted_by,source_name)
 VALUES (v_batch_key,v_uid,'Google Forms XLSX') RETURNING id INTO v_batch;
 FOR v_sub IN SELECT value FROM jsonb_array_elements(coalesce(p_payload->'submissions','[]'::jsonb))
 LOOP
  v_sub_key:=v_sub->>'submission_key';
  IF v_sub_key IS NULL OR btrim(v_sub_key)='' THEN RAISE EXCEPTION 'missing submission_key'; END IF;
  v_member_type:=v_sub->>'member_type';
  v_identifier:=upper(regexp_replace(coalesce(v_sub->>'member_identifier',''),'[[:space:]]','','g'));
  IF (v_member_type='北投會館會員' AND v_identifier !~ '^[A-Z][0-9]{9}$')
   OR (v_member_type='台北捷運Go會員' AND v_identifier !~ '^09[0-9]{8}$')
   OR v_member_type NOT IN ('北投會館會員','台北捷運Go會員')
   OR v_member_type IS NULL
  THEN RAISE EXCEPTION '會員識別格式錯誤，第 % 列',v_sub->>'excel_row'; END IF;
  v_member_hash:=private.secure_member_key_hash(v_member_type,v_identifier);
  INSERT INTO public.lottery_form_submissions(
    submission_key,batch_id,submitted_at_text,member_type,
    member_key_hash,member_identifier,applicant_name,
    contact_phone,contact_email,raw_payload,excel_row,identifier_hash_version)
  VALUES (
    v_sub_key,v_batch,v_sub->>'submitted_at',v_member_type,
    v_member_hash,right(v_identifier,4),v_sub->>'name',
    v_sub->>'phone',v_sub->>'email',
    coalesce(v_sub->'raw_payload','{}'::jsonb)
     -'北投會館會員身分證字號（10碼）'
     -'台北捷運Go會員綁定手機（10碼）',
    (v_sub->>'excel_row')::integer,'hmac-v1')
  ON CONFLICT(submission_key) DO NOTHING;
  IF FOUND THEN
   v_submission_count:=v_submission_count+1;
  ELSE
   v_duplicate:=v_duplicate+1;
   -- A reused submission key MUST have the same server-side member hash.
   -- Never allow unrelated applicants to claim an existing submission key.
   IF NOT EXISTS (
    SELECT 1 FROM public.lottery_form_submissions
    WHERE submission_key=v_sub_key AND member_key_hash=v_member_hash
       AND member_type=v_member_type
   ) THEN
    RAISE EXCEPTION '提交識別與會員身分不一致，第 % 列',v_sub->>'excel_row';
   END IF;
  END IF;
 END LOOP;
 FOR v_rec IN SELECT value FROM jsonb_array_elements(coalesce(p_payload->'records','[]'::jsonb))
 LOOP
  v_sub_key:=v_rec->>'submission_key';
  v_rec_key:=v_rec->>'record_key';
  IF nullif(v_rec_key,'') IS NULL OR nullif(v_sub_key,'') IS NULL THEN
   RAISE EXCEPTION 'record_key/submission_key required';
  END IF;
  SELECT s.batch_id INTO v_existing_batch FROM public.lottery_form_submissions s
  WHERE s.submission_key=v_sub_key;
  IF v_existing_batch IS NULL THEN RAISE EXCEPTION '找不到對應表單回覆：%',v_sub_key; END IF;
  -- A record can be recreated even when its submission remains from a prior batch.
  -- The import_record_key partial unique index remains the idempotency guard.
  INSERT INTO public.lottery_records(
    name,phone,id_last4,location_name,venue_type,day_of_week,time_slot,
    serial_number,registered_at,import_submission_key,import_record_key,
    member_type,member_key_hash,member_identifier_last4)
  SELECT
    v_rec->>'name',v_rec->>'phone',coalesce(v_rec->>'id_last4',''),
    coalesce(v_rec->>'location_name','北投會館'),v_rec->>'venue_type',
    v_rec->>'day_of_week',v_rec->>'time_slot',v_rec->>'serial_number',
    coalesce((v_rec->>'registered_at')::timestamptz,now()),
    v_sub_key,v_rec_key,s.member_type,s.member_key_hash,s.member_identifier
  FROM public.lottery_form_submissions s WHERE s.submission_key=v_sub_key
  ON CONFLICT(import_record_key) WHERE import_record_key IS NOT NULL DO NOTHING;
  IF FOUND THEN v_inserted:=v_inserted+1; END IF;
 END LOOP;
 FOR v_an IN SELECT value FROM jsonb_array_elements(coalesce(p_payload->'anomalies','[]'::jsonb))
 LOOP
  -- Associate new anomaly only with the newly imported batch. The record
  -- may belong to a submission whose original batch was imported earlier.
  IF EXISTS(
   SELECT 1 FROM jsonb_array_elements_text(coalesce(v_an->'submissionKeys','[]'::jsonb)) k
   JOIN public.lottery_form_submissions s ON s.submission_key=k
  ) AND NOT EXISTS(
   SELECT 1 FROM public.lottery_import_anomalies a
   WHERE a.anomaly_type=v_an->>'type'
    AND a.record_keys=ARRAY(
      SELECT jsonb_array_elements_text(coalesce(v_an->'recordKeys','[]'::jsonb))
    )
  ) THEN
   INSERT INTO public.lottery_import_anomalies(
    batch_id,anomaly_type,detail,submission_keys,record_keys)
   VALUES(
    v_batch,v_an->>'type',v_an->>'detail',
    ARRAY(SELECT jsonb_array_elements_text(coalesce(v_an->'submissionKeys','[]'::jsonb))),
    ARRAY(SELECT jsonb_array_elements_text(coalesce(v_an->'recordKeys','[]'::jsonb)))
   );
   v_anomaly_count:=v_anomaly_count+1;
  END IF;
 END LOOP;
 UPDATE public.lottery_form_import_batches
 SET submission_count=v_submission_count,
     record_count=v_inserted,anomaly_count=v_anomaly_count
 WHERE id=v_batch;
 INSERT INTO public.lottery_import_audit(batch_id,actor_id,action,detail)
 VALUES(v_batch,v_uid,'import',jsonb_build_object(
  'submissions',v_submission_count,'records',v_inserted,
  'duplicates',v_duplicate,'anomalies',v_anomaly_count));
 RETURN jsonb_build_object(
  'batch_id',v_batch,'inserted_records',v_inserted,
  'duplicate_submissions',v_duplicate,'already_processed',false);
END;
$function$;
COMMIT;
