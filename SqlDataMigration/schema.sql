


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."check_cleanup_needed"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  last_log_date date;
begin
  select max(log_date) into last_log_date from daily_logs;

  -- If no logs yet or last log was yesterday or earlier → cleanup needed
  if last_log_date is null or last_log_date < current_date then
    return true;
  end if;

  return false;
end;
$$;


ALTER FUNCTION "public"."check_cleanup_needed"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_old_readings"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  deleted_count int;
begin
  delete from sensor_readings
  where created_at < now() - interval '24 hours';

  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;


ALTER FUNCTION "public"."delete_old_readings"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, avatar_url, role)
  VALUES (
    new.id,
    COALESCE(new.raw_user_meta_data->>'full_name', ''),
    COALESCE(new.raw_user_meta_data->>'avatar_url', ''),
    'admin'
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN new;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."run_daily_cleanup"() RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  deleted_count int;
  result        json;
begin
  -- Step 1: Summarize yesterday into daily_logs
  perform summarize_yesterday();

  -- Step 2: Delete old raw sensor readings
  select delete_old_readings() into deleted_count;

  -- Return summary of what was done
  result := json_build_object(
    'status',          'success',
    'deleted_readings', deleted_count,
    'summarized_date',  (now() - interval '1 day')::date,
    'ran_at',           now()
  );

  return result;
end;
$$;


ALTER FUNCTION "public"."run_daily_cleanup"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."summarize_yesterday"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  target_date date := (now() - interval '1 day')::date;
begin
  insert into daily_logs (
    zone_id,
    log_date,
    avg_rms,
    peak_rms,
    avg_temperature,
    max_temperature,
    min_temperature,
    total_readings,
    noisy_events,
    critical_events,
    am_noisy_count,
    pm_noisy_count
  )
  select
    sr.zone_id,
    target_date,
    round(avg(sr.rms)::numeric, 2),
    round(max(sr.rms)::numeric, 2),
    round(avg(sr.temperature_c)::numeric, 2),
    round(max(sr.temperature_c)::numeric, 2),
    round(min(sr.temperature_c)::numeric, 2),
    count(*),
    coalesce((
      select count(*) from noise_events ne
      where ne.zone_id = sr.zone_id
        and ne.created_at::date = target_date
    ), 0),
    coalesce((
      select count(*) from noise_events ne
      where ne.zone_id = sr.zone_id
        and ne.severity = 'critical'
        and ne.created_at::date = target_date
    ), 0),
    coalesce((
      select count(*) from noise_events ne
      where ne.zone_id = sr.zone_id
        and extract(hour from ne.created_at) < 12
        and ne.created_at::date = target_date
    ), 0),
    coalesce((
      select count(*) from noise_events ne
      where ne.zone_id = sr.zone_id
        and extract(hour from ne.created_at) >= 12
        and ne.created_at::date = target_date
    ), 0)
  from sensor_readings sr
  where sr.created_at::date = target_date
  group by sr.zone_id
  on conflict (zone_id, log_date) do update set
    avg_rms         = excluded.avg_rms,
    peak_rms        = excluded.peak_rms,
    avg_temperature = excluded.avg_temperature,
    max_temperature = excluded.max_temperature,
    min_temperature = excluded.min_temperature,
    total_readings  = excluded.total_readings,
    noisy_events    = excluded.noisy_events,
    critical_events = excluded.critical_events,
    am_noisy_count  = excluded.am_noisy_count,
    pm_noisy_count  = excluded.pm_noisy_count;
end;
$$;


ALTER FUNCTION "public"."summarize_yesterday"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."audit_logs" (
    "id" bigint NOT NULL,
    "zone_id" integer,
    "department" "text" DEFAULT ''::"text" NOT NULL,
    "event" "text" NOT NULL,
    "severity" "text" DEFAULT 'info'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "event_type" "text" DEFAULT 'system'::"text" NOT NULL
);


ALTER TABLE "public"."audit_logs" OWNER TO "postgres";


ALTER TABLE "public"."audit_logs" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."audit_logs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."buzzer_control" (
    "zone_id" integer NOT NULL,
    "mode" "text" DEFAULT 'auto'::"text",
    "manual_state" boolean DEFAULT false,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."buzzer_control" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."daily_logs" (
    "id" bigint NOT NULL,
    "zone_id" integer NOT NULL,
    "log_date" "date" NOT NULL,
    "avg_rms" double precision DEFAULT 0,
    "peak_rms" double precision DEFAULT 0,
    "avg_temperature" double precision DEFAULT 0,
    "max_temperature" double precision DEFAULT 0,
    "min_temperature" double precision DEFAULT 0,
    "total_readings" integer DEFAULT 0,
    "noisy_events" integer DEFAULT 0,
    "critical_events" integer DEFAULT 0,
    "am_noisy_count" integer DEFAULT 0,
    "pm_noisy_count" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."daily_logs" OWNER TO "postgres";


ALTER TABLE "public"."daily_logs" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."daily_logs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."zones" (
    "id" integer NOT NULL,
    "zone_name" "text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text",
    "last_seen_at" timestamp with time zone
);


ALTER TABLE "public"."zones" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."inactive_zones" AS
 SELECT "id" AS "zone_id",
    "zone_name",
    "status",
    "last_seen_at",
    (EXTRACT(epoch FROM ("now"() - "last_seen_at")) / (60)::numeric) AS "minutes_since_last_data"
   FROM "public"."zones" "z"
  WHERE (("last_seen_at" IS NULL) OR ("last_seen_at" < ("now"() - '00:10:00'::interval)));


ALTER VIEW "public"."inactive_zones" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ml_model_versions" (
    "model_type" "text" NOT NULL,
    "storage_path" "text" NOT NULL,
    "labels_path" "text" NOT NULL,
    "scaler_path" "text" NOT NULL,
    "version_tag" "text" NOT NULL,
    "uploaded_by" "text",
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."ml_model_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."noise_events" (
    "id" bigint NOT NULL,
    "zone_id" integer NOT NULL,
    "noise_label" "text" NOT NULL,
    "noise_level" "text" NOT NULL,
    "rms" double precision,
    "temperature_c" double precision,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "event_description" "text" DEFAULT ''::"text",
    "severity" "text" DEFAULT 'info'::"text"
);


ALTER TABLE "public"."noise_events" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."noise_event_stats" AS
 SELECT ( SELECT "z"."zone_name"
           FROM ("public"."noise_events" "ne"
             JOIN "public"."zones" "z" ON (("z"."id" = "ne"."zone_id")))
          WHERE (("ne"."severity" = 'critical'::"text") AND ("ne"."created_at" >= ("now"() - '03:00:00'::interval)))
          GROUP BY "z"."zone_name"
          ORDER BY ("count"(*)) DESC
         LIMIT 1) AS "most_noisy_department",
    ( SELECT "noise_events"."noise_label"
           FROM "public"."noise_events"
          WHERE ("noise_events"."created_at" >= ("now"() - '03:00:00'::interval))
          GROUP BY "noise_events"."noise_label"
          ORDER BY ("count"(*)) DESC
         LIMIT 1) AS "most_common_noise",
    ( SELECT "count"(*) AS "count"
           FROM "public"."noise_events"
          WHERE (("noise_events"."severity" = 'critical'::"text") AND ("noise_events"."created_at" >= ("now"() - '03:00:00'::interval)))) AS "red_trigger_count",
    ( SELECT
                CASE
                    WHEN ("sum"(
                    CASE
                        WHEN (EXTRACT(hour FROM "noise_events"."created_at") < (12)::numeric) THEN 1
                        ELSE 0
                    END) > "sum"(
                    CASE
                        WHEN (EXTRACT(hour FROM "noise_events"."created_at") >= (12)::numeric) THEN 1
                        ELSE 0
                    END)) THEN 'AM'::"text"
                    ELSE 'PM'::"text"
                END AS "case"
           FROM "public"."noise_events"
          WHERE (("noise_events"."severity" = ANY (ARRAY['warning'::"text", 'critical'::"text"])) AND ("noise_events"."created_at" >= ("now"() - '03:00:00'::interval)))) AS "most_noisy_period";


ALTER VIEW "public"."noise_event_stats" OWNER TO "postgres";


ALTER TABLE "public"."noise_events" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."noise_events_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."noise_source_predictions" (
    "id" bigint NOT NULL,
    "noise_detected" boolean NOT NULL,
    "likely_source" "text",
    "confidence" double precision NOT NULL,
    "cs_rms" double precision,
    "eng_rms" double precision,
    "it_rms" double precision,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."noise_source_predictions" OWNER TO "postgres";


ALTER TABLE "public"."noise_source_predictions" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."noise_source_predictions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "full_name" "text" DEFAULT ''::"text" NOT NULL,
    "avatar_url" "text" DEFAULT ''::"text",
    "role" "text" DEFAULT 'admin'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."recent_threshold_breaches" AS
 SELECT "al"."id",
    "al"."created_at",
    "al"."department",
    "al"."event_type",
    "al"."event",
    "al"."severity",
    "z"."zone_name"
   FROM ("public"."audit_logs" "al"
     LEFT JOIN "public"."zones" "z" ON (("z"."id" = "al"."zone_id")))
  WHERE (("al"."event_type" = ANY (ARRAY['threshold'::"text", 'inactive'::"text", 'noise'::"text"])) AND ("al"."created_at" >= ("now"() - '24:00:00'::interval)))
  ORDER BY "al"."created_at" DESC;


ALTER VIEW "public"."recent_threshold_breaches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sensor_readings" (
    "id" bigint NOT NULL,
    "zone_id" integer NOT NULL,
    "avg" double precision NOT NULL,
    "peak" double precision NOT NULL,
    "min" double precision NOT NULL,
    "rms" double precision NOT NULL,
    "temperature_c" double precision DEFAULT 25.0,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."sensor_readings" OWNER TO "postgres";


ALTER TABLE "public"."sensor_readings" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."sensor_readings_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."settings" (
    "id" integer DEFAULT 1 NOT NULL,
    "noise_warning_threshold" double precision DEFAULT 60.0,
    "noise_critical_threshold" double precision DEFAULT 72.0,
    "temp_threshold" double precision DEFAULT 26.0,
    "alarm_pattern" "text" DEFAULT 'short_burst'::"text",
    "alarm_duration_sec" double precision DEFAULT 5.0,
    "alarm_cooldown_sec" double precision DEFAULT 30.0,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."settings" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."summary_stats" AS
 SELECT "round"(("avg"("rms"))::numeric, 1) AS "avg_sound_rms",
    "round"(("max"("rms"))::numeric, 1) AS "highest_sound_rms",
    "round"(("avg"("temperature_c"))::numeric, 1) AS "avg_temperature",
    "round"(("max"("temperature_c"))::numeric, 1) AS "highest_temperature",
    "count"(*) AS "total_records",
    "min"("created_at") AS "from_time",
    "max"("created_at") AS "to_time"
   FROM "public"."sensor_readings"
  WHERE ("created_at" >= ("now"() - '03:00:00'::interval));


ALTER VIEW "public"."summary_stats" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."zone_am_pm_counts" AS
 SELECT "ne"."zone_id",
    "z"."zone_name",
    "count"(
        CASE
            WHEN ((EXTRACT(hour FROM "ne"."created_at") < (12)::numeric) AND ("ne"."severity" = ANY (ARRAY['warning'::"text", 'critical'::"text"]))) THEN 1
            ELSE NULL::integer
        END) AS "am_count",
    "count"(
        CASE
            WHEN ((EXTRACT(hour FROM "ne"."created_at") >= (12)::numeric) AND ("ne"."severity" = ANY (ARRAY['warning'::"text", 'critical'::"text"]))) THEN 1
            ELSE NULL::integer
        END) AS "pm_count"
   FROM ("public"."noise_events" "ne"
     JOIN "public"."zones" "z" ON (("z"."id" = "ne"."zone_id")))
  WHERE ("ne"."created_at" >= ("now"() - '24:00:00'::interval))
  GROUP BY "ne"."zone_id", "z"."zone_name";


ALTER VIEW "public"."zone_am_pm_counts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."zone_status" (
    "zone_id" integer NOT NULL,
    "noise_label" "text" DEFAULT 'quiet'::"text",
    "noise_level" "text" DEFAULT 'quiet'::"text",
    "led_color" "text" DEFAULT 'green'::"text",
    "buzzer_active" boolean DEFAULT false,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."zone_status" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."zones_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."zones_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."zones_id_seq" OWNED BY "public"."zones"."id";



ALTER TABLE ONLY "public"."zones" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."zones_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."buzzer_control"
    ADD CONSTRAINT "buzzer_control_pkey" PRIMARY KEY ("zone_id");



ALTER TABLE ONLY "public"."daily_logs"
    ADD CONSTRAINT "daily_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ml_model_versions"
    ADD CONSTRAINT "ml_model_versions_pkey" PRIMARY KEY ("model_type");



ALTER TABLE ONLY "public"."noise_events"
    ADD CONSTRAINT "noise_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."noise_source_predictions"
    ADD CONSTRAINT "noise_source_predictions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sensor_readings"
    ADD CONSTRAINT "sensor_readings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."settings"
    ADD CONSTRAINT "settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."zone_status"
    ADD CONSTRAINT "zone_status_pkey" PRIMARY KEY ("zone_id");



ALTER TABLE ONLY "public"."zones"
    ADD CONSTRAINT "zones_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_audit_logs_event_type" ON "public"."audit_logs" USING "btree" ("event_type", "created_at" DESC);



CREATE INDEX "idx_audit_logs_severity" ON "public"."audit_logs" USING "btree" ("severity", "created_at" DESC);



CREATE INDEX "idx_audit_logs_time" ON "public"."audit_logs" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_audit_logs_zone" ON "public"."audit_logs" USING "btree" ("zone_id", "created_at" DESC);



CREATE INDEX "idx_daily_logs_date" ON "public"."daily_logs" USING "btree" ("log_date" DESC);



CREATE UNIQUE INDEX "idx_daily_logs_zone_date" ON "public"."daily_logs" USING "btree" ("zone_id", "log_date");



CREATE INDEX "idx_noise_events_zone_time" ON "public"."noise_events" USING "btree" ("zone_id", "created_at" DESC);



CREATE INDEX "idx_noise_source_predictions_time" ON "public"."noise_source_predictions" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_sensor_readings_zone_time" ON "public"."sensor_readings" USING "btree" ("zone_id", "created_at" DESC);



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_zone_id_fkey" FOREIGN KEY ("zone_id") REFERENCES "public"."zones"("id");



ALTER TABLE ONLY "public"."buzzer_control"
    ADD CONSTRAINT "buzzer_control_zone_id_fkey" FOREIGN KEY ("zone_id") REFERENCES "public"."zones"("id");



ALTER TABLE ONLY "public"."daily_logs"
    ADD CONSTRAINT "daily_logs_zone_id_fkey" FOREIGN KEY ("zone_id") REFERENCES "public"."zones"("id");



ALTER TABLE ONLY "public"."noise_events"
    ADD CONSTRAINT "noise_events_zone_id_fkey" FOREIGN KEY ("zone_id") REFERENCES "public"."zones"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sensor_readings"
    ADD CONSTRAINT "sensor_readings_zone_id_fkey" FOREIGN KEY ("zone_id") REFERENCES "public"."zones"("id");



ALTER TABLE ONLY "public"."zone_status"
    ADD CONSTRAINT "zone_status_zone_id_fkey" FOREIGN KEY ("zone_id") REFERENCES "public"."zones"("id");



CREATE POLICY "allow insert on signup" ON "public"."profiles" FOR INSERT TO "authenticated", "anon" WITH CHECK (true);



CREATE POLICY "allow_all_audit_logs" ON "public"."audit_logs" TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_buzzer_control" ON "public"."buzzer_control" TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_daily_logs" ON "public"."daily_logs" TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_ml_model_versions" ON "public"."ml_model_versions" TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_noise_events" ON "public"."noise_events" TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_noise_source_predictions" ON "public"."noise_source_predictions" TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_sensor_readings" ON "public"."sensor_readings" TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_settings" ON "public"."settings" TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_zone_status" ON "public"."zone_status" TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_read_zones" ON "public"."zones" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."buzzer_control" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."daily_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ml_model_versions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."noise_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."noise_source_predictions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sensor_readings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "service role can insert profiles" ON "public"."profiles" FOR INSERT TO "service_role" WITH CHECK (true);



ALTER TABLE "public"."settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "users can update own profile" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "id")) WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "users can view own profile" ON "public"."profiles" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "id"));



CREATE POLICY "users_read_own_profile" ON "public"."profiles" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "id"));



CREATE POLICY "users_update_own_profile" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "id")) WITH CHECK (("auth"."uid"() = "id"));



ALTER TABLE "public"."zone_status" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."zones" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."audit_logs";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."buzzer_control";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."ml_model_versions";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."noise_source_predictions";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."sensor_readings";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."settings";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."zone_status";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































GRANT ALL ON FUNCTION "public"."check_cleanup_needed"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_cleanup_needed"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_cleanup_needed"() TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_old_readings"() TO "anon";
GRANT ALL ON FUNCTION "public"."delete_old_readings"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_old_readings"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."run_daily_cleanup"() TO "anon";
GRANT ALL ON FUNCTION "public"."run_daily_cleanup"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."run_daily_cleanup"() TO "service_role";



GRANT ALL ON FUNCTION "public"."summarize_yesterday"() TO "anon";
GRANT ALL ON FUNCTION "public"."summarize_yesterday"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."summarize_yesterday"() TO "service_role";


















GRANT ALL ON TABLE "public"."audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_logs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."audit_logs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."audit_logs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."audit_logs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."buzzer_control" TO "anon";
GRANT ALL ON TABLE "public"."buzzer_control" TO "authenticated";
GRANT ALL ON TABLE "public"."buzzer_control" TO "service_role";



GRANT ALL ON TABLE "public"."daily_logs" TO "anon";
GRANT ALL ON TABLE "public"."daily_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_logs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."daily_logs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."daily_logs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."daily_logs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."zones" TO "anon";
GRANT ALL ON TABLE "public"."zones" TO "authenticated";
GRANT ALL ON TABLE "public"."zones" TO "service_role";



GRANT ALL ON TABLE "public"."inactive_zones" TO "anon";
GRANT ALL ON TABLE "public"."inactive_zones" TO "authenticated";
GRANT ALL ON TABLE "public"."inactive_zones" TO "service_role";



GRANT ALL ON TABLE "public"."ml_model_versions" TO "anon";
GRANT ALL ON TABLE "public"."ml_model_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."ml_model_versions" TO "service_role";



GRANT ALL ON TABLE "public"."noise_events" TO "anon";
GRANT ALL ON TABLE "public"."noise_events" TO "authenticated";
GRANT ALL ON TABLE "public"."noise_events" TO "service_role";



GRANT ALL ON TABLE "public"."noise_event_stats" TO "anon";
GRANT ALL ON TABLE "public"."noise_event_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."noise_event_stats" TO "service_role";



GRANT ALL ON SEQUENCE "public"."noise_events_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."noise_events_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."noise_events_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."noise_source_predictions" TO "anon";
GRANT ALL ON TABLE "public"."noise_source_predictions" TO "authenticated";
GRANT ALL ON TABLE "public"."noise_source_predictions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."noise_source_predictions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."noise_source_predictions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."noise_source_predictions_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."recent_threshold_breaches" TO "anon";
GRANT ALL ON TABLE "public"."recent_threshold_breaches" TO "authenticated";
GRANT ALL ON TABLE "public"."recent_threshold_breaches" TO "service_role";



GRANT ALL ON TABLE "public"."sensor_readings" TO "anon";
GRANT ALL ON TABLE "public"."sensor_readings" TO "authenticated";
GRANT ALL ON TABLE "public"."sensor_readings" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sensor_readings_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sensor_readings_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sensor_readings_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."settings" TO "anon";
GRANT ALL ON TABLE "public"."settings" TO "authenticated";
GRANT ALL ON TABLE "public"."settings" TO "service_role";



GRANT ALL ON TABLE "public"."summary_stats" TO "anon";
GRANT ALL ON TABLE "public"."summary_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."summary_stats" TO "service_role";



GRANT ALL ON TABLE "public"."zone_am_pm_counts" TO "anon";
GRANT ALL ON TABLE "public"."zone_am_pm_counts" TO "authenticated";
GRANT ALL ON TABLE "public"."zone_am_pm_counts" TO "service_role";



GRANT ALL ON TABLE "public"."zone_status" TO "anon";
GRANT ALL ON TABLE "public"."zone_status" TO "authenticated";
GRANT ALL ON TABLE "public"."zone_status" TO "service_role";



GRANT ALL ON SEQUENCE "public"."zones_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."zones_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."zones_id_seq" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































