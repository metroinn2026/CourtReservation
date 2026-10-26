-- Local synthetic schema only. Never deploy this fixture to Supabase.
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
CREATE SCHEMA auth;
CREATE SCHEMA private;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
-- Deliberately a test double: tests identity grouping, NOT production HMAC security.
CREATE FUNCTION private.secure_member_key_hash(text,text) RETURNS text LANGUAGE sql AS $$
 SELECT md5($1 || ':' || $2)
$$;
CREATE TABLE public.lottery_import_admins(user_id uuid PRIMARY KEY);
INSERT INTO public.lottery_import_admins VALUES ('00000000-0000-0000-0000-000000000001');
CREATE TABLE public.lottery_form_import_batches(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), batch_key uuid UNIQUE NOT NULL,
 source_name text, submitted_by uuid, submitted_at timestamptz DEFAULT now(),
 submission_count integer DEFAULT 0, record_count integer DEFAULT 0, anomaly_count integer DEFAULT 0
);
CREATE TABLE public.lottery_form_submissions(
 submission_key text PRIMARY KEY, batch_id uuid REFERENCES public.lottery_form_import_batches,
 submitted_at_text text, member_type text, member_key_hash text, member_identifier text,
 applicant_name text, contact_phone text, contact_email text, raw_payload jsonb,
 excel_row integer, created_at timestamptz DEFAULT now(), identifier_hash_version text
);
CREATE TABLE public.lottery_records(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text, phone text, id_last4 text,
 location_name text, venue_type text, sport_usage text, day_of_week text, time_slot text, serial_number text,
 registered_at timestamptz, import_submission_key text, import_record_key text,
 member_type text, member_key_hash text, member_identifier_last4 text,
 lottery_status text, lottery_batch text, lottery_locked boolean DEFAULT false,
 result_published boolean DEFAULT false, updated_at timestamptz, published_at timestamptz
);
CREATE TABLE public.lottery_capacity_settings(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),venue_type text,day_of_week text,time_slot text,
 winner_count integer,is_closed boolean DEFAULT false,updated_at timestamptz DEFAULT now(),
 UNIQUE(venue_type,day_of_week,time_slot)
);
CREATE UNIQUE INDEX lottery_records_unique_limited_sports ON public.lottery_records
 USING btree (phone,id_last4,venue_type) WHERE (venue_type = ANY(ARRAY['羽球'::text,'籃球'::text]));
CREATE UNIQUE INDEX lottery_records_import_record_key_uq ON public.lottery_records
 USING btree (import_record_key) WHERE import_record_key IS NOT NULL;
CREATE TABLE public.lottery_import_anomalies(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), batch_id uuid REFERENCES public.lottery_form_import_batches,
 anomaly_type text NOT NULL, detail text, submission_keys text[] NOT NULL DEFAULT '{}',
 record_keys text[] NOT NULL DEFAULT '{}', resolution_status text NOT NULL DEFAULT 'pending'
 CHECK(resolution_status IN ('pending','valid','invalid')),
 resolved_by uuid, resolved_at timestamptz, created_at timestamptz DEFAULT now()
);
CREATE TABLE public.lottery_import_audit(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), batch_id uuid REFERENCES public.lottery_form_import_batches,
 anomaly_id uuid REFERENCES public.lottery_import_anomalies, actor_id uuid,
 action text, detail jsonb, created_at timestamptz DEFAULT now()
);
