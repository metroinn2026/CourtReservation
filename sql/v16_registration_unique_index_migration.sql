-- CourtReservation v16: remove the legacy phone/ID-tail/sport uniqueness rule.
-- STAGING ONLY until the paired application and access-control changes pass.
-- Keep lottery_records_import_record_key_uq: it is the import idempotency guard.
BEGIN;

DO $preflight$
DECLARE
  v_limited_index text;
  v_import_index text;
  v_expected_limited text := 'createuniqueindexlottery_records_unique_limited_sportsonpublic.lottery_recordsusingbtree(phone,id_last4,venue_type)where(venue_type=any(array[''羽球''::text,''籃球''::text]))';
  v_expected_import text := 'createuniqueindexlottery_records_import_record_key_uqonpublic.lottery_recordsusingbtree(import_record_key)where(import_record_keyisnotnull)';
BEGIN
  SELECT pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.pg_get_indexdef(i.indexrelid), '\s+', '', 'g'))
    INTO v_limited_index
  FROM pg_catalog.pg_index i
  JOIN pg_catalog.pg_class idx ON idx.oid = i.indexrelid
  JOIN pg_catalog.pg_class tbl ON tbl.oid = i.indrelid
  JOIN pg_catalog.pg_namespace ns ON ns.oid = tbl.relnamespace
  WHERE ns.nspname = 'public'
    AND tbl.relname = 'lottery_records'
    AND idx.relname = 'lottery_records_unique_limited_sports'
    AND i.indisunique AND i.indisvalid;

  IF v_limited_index IS DISTINCT FROM v_expected_limited THEN
    RAISE EXCEPTION 'Expected legacy unique index definition not found; no index was changed.';
  END IF;

  SELECT pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.pg_get_indexdef(i.indexrelid), '\s+', '', 'g'))
    INTO v_import_index
  FROM pg_catalog.pg_index i
  JOIN pg_catalog.pg_class idx ON idx.oid = i.indexrelid
  JOIN pg_catalog.pg_class tbl ON tbl.oid = i.indrelid
  JOIN pg_catalog.pg_namespace ns ON ns.oid = tbl.relnamespace
  WHERE ns.nspname = 'public'
    AND tbl.relname = 'lottery_records'
    AND idx.relname = 'lottery_records_import_record_key_uq'
    AND i.indisunique AND i.indisvalid;

  IF v_import_index IS DISTINCT FROM v_expected_import THEN
    RAISE EXCEPTION 'Expected import_record_key unique index is missing or differs; no index was changed.';
  END IF;
END
$preflight$;

-- Member-rule checks use the server-derived HMAC. This index supports those
-- checks without relying on the shared contact phone or the ID last four digits.
CREATE INDEX IF NOT EXISTS lottery_records_v16_member_time_idx
  ON public.lottery_records (member_key_hash, registered_at, import_record_key)
  WHERE member_key_hash IS NOT NULL AND import_record_key IS NOT NULL;

DROP INDEX public.lottery_records_unique_limited_sports;
COMMIT;

-- Read-only verification; the import_record_key unique index must remain.
SELECT indexname, indexdef
FROM pg_catalog.pg_indexes
WHERE schemaname = 'public'
  AND tablename = 'lottery_records'
  AND indexname IN (
    'lottery_records_unique_limited_sports',
    'lottery_records_v16_member_time_idx',
    'lottery_records_import_record_key_uq'
  )
ORDER BY indexname;
