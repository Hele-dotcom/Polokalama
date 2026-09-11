-- ---------------------------------------------------------------------------
-- 02  stg - staging
-- ---------------------------------------------------------------------------
-- Source data as extracted. Every column is text, deliberately: FileMaker
-- permits values PostgreSQL does not - a Time field may hold more than 24
-- hours - and a typed staging column would turn one bad value into a failed
-- load. Typing happens on the way into rep, where a failure costs one field
-- and is logged.
--
-- stg holds history and is append-only in normal running. It is never granted
-- TRUNCATE. Emptying it is an administrative act, done by hand, and the
-- extractor then reloads it in full because no watermark floor exists.
-- ---------------------------------------------------------------------------


-- Everything below is created as pp_owner, so that ownership is consistent and
-- ALTER DEFAULT PRIVILEGES below applies to it. Default privileges attach to a
-- granting role, not to a schema: declared while running as someone else, they
-- silently do not cover tables pp_owner creates - which shows up months later
-- as a new table with no grants on it.
SET ROLE pp_owner;

CREATE SCHEMA IF NOT EXISTS stg;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
-- One per source table in scope. The column list is the populated subset
-- established at discovery, not everything the source exposes.
--
-- To emit the DDL for a table that already exists, so this file can be brought
-- up to date rather than retyped:
--
--   SELECT 'CREATE TABLE stg.' || table_name || ' ('
--          || string_agg('"' || column_name || '" ' || data_type,
--                        ', ' ORDER BY ordinal_position) || ');'
--   FROM   information_schema.columns
--   WHERE  table_schema = 'stg' AND table_name = 'pp'
--   GROUP  BY table_name;

 CREATE TABLE stg.pp (
    "add_dispatch_1_cue" text,
    "add_dispatch_2_cue" text,
    "address" text,
    "alcohol" text,
    "alcohol_specify" text,
    "arrest_calc_clery" text,
    "assigned_flag_officer_count" text,
    "assigned_flag_ssa_count" text,
    "_audit" text,
    "blotter # summ" text,
    "bltr" text,
    "bltr_calc_display" text,
    "bltr_incident_display" text,
    "call_source" text,
    "call_type" text,
    "case_status_detectives" text,
    "ciu" text,
    "closed" text,
    "closed_calc" text,
    "constant" text,
    "created_by" text,
    "creation_date_timestamp" text,
    "creation_ip" text,
    "crime_type" text,
    "crime_type_2" text,
    "crime_type_3" text,
    "crime_type_display" text,
    "current_records" text,
    "date" text,
    "date_closed_detectives" text,
    "date_display" text,
    "date_occurred" text,
    "day" text,
    "day_date_calc" text,
    "day_name_calc_display" text,
    "day_number" text,
    "day_number_2" text,
    "defendant_flag_calc" text,
    "deployment_base" text,
    "det_disposition" text,
    "detective_close_flag" text,
    "dispatch_close" text,
    "dispatch_concat" text,
    "dispatch_text_1" text,
    "dispatch_text_1_display" text,
    "domestic" text,
    "dv_alcohol_involved" text,
    "dv_case_description" text,
    "dv_prosecuted_n_summ" text,
    "dv_prosecuted_y_summ" text,
    "dv_pso_serve" text,
    "evidence_flag_calc_number" text,
    "finalisation_location" text,
    "finalisation_reason" text,
    "finalisation_status" text,
    "___fist_date" text,
    "fkey_location_history" text,
    "_fkeylocation_of_incident_calc" text,
    "_fkeysuspectcalc_id" text,
    "fmmap_incident_mapping" text,
    "fmmap_label" text,
    "format" text,
    "gshow_pref" text,
    "history_summ" text,
    "hl_year_current" text,
    "hl_year_record" text,
    "hotlist_calc" text,
    "info" text,
    "investigation_closed_by" text,
    "investigation_closed_by_display" text,
    "investigation_closed_date" text,
    "investigation_close_rationale" text,
    "investigation_close_rationale_display" text,
    "investigation_disposition" text,
    "investigation_disposition_display" text,
    "investigation_final_review_by" text,
    "investigation_final_review_by_display" text,
    "investigation_final_review_calc" text,
    "investigation_final_review_date" text,
    "ip_address" text,
    "latitude" text,
    "lead_investigator" text,
    "leads_find_calc" text,
    "leads_list" text,
    "list_contacts" text,
    "list_evidence" text,
    "location" text,
    "location_of_incident_concat" text,
    "location_of_incident_number" text,
    "location_of_incident_number_display" text,
    "location_of_incident_num_street_concat" text,
    "location_of_incident_other" text,
    "location_of_incident_other_display" text,
    "location_of_incident_street" text,
    "location_of_incident_street_display" text,
    "lock" text,
    "longitude" text,
    "lotofaga_tag" text,
    "mental_health" text,
    "modification_date_timestamp" text,
    "modified_by" text,
    "month" text,
    "month_name" text,
    "_multi arrests" text,
    "narcotics_flag" text,
    "narcotics_type" text,
    "non_police_vessel" text,
    "offender_arrested" text,
    "officer_count_calc" text,
    "operating_area" text,
    "operation_name" text,
    "person_status_filter_key" text,
    "phone_business" text,
    "phone_business_display" text,
    "__pkeypolicepro_id" text,
    "pkey_summary" text,
    "po" text,
    "_police_status_key" text,
    "police_vessel" text,
    "primary_incident" text,
    "primary_officer" text,
    "property_seizure" text,
    "pso" text,
    "rec_current" text,
    "rec_found_ct" text,
    "record_count_summ" text,
    "rec_tot" text,
    "related_dispatch_flag_calc_yes" text,
    "requesting_agency" text,
    "review_by" text,
    "rhtaudittraillog" text,
    "rhtaudittraillog_calc_display" text,
    "rhtaudittrailprevvalues" text,
    "sar_results" text,
    "section" text,
    "seniorexecutive_tag" text,
    "seniorleadership_tag" text,
    "shift_calc" text,
    "shift_calc_display" text,
    "shift_calc_display_2" text,
    "shift_calc_summary" text,
    "shift_calc_text_display" text,
    "significant" text,
    "significant copy" text,
    "step_1_display" text,
    "step_2_display" text,
    "step_3_display" text,
    "step_4_display" text,
    "step_5_display" text,
    "supervisor" text,
    "time_dispatched" text,
    "time_dispatched_display" text,
    "time_occurred" text,
    "time_received" text,
    "time_received_display" text,
    "time_summary" text,
    "total_recovered" text,
    "total_stolen" text,
    "traffic_related" text,
    "victim_flag" text,
    "village" text,
    "village_display" text,
    "year" text,
    "yesterday" text,
    loaded_at timestamp NOT NULL DEFAULT clock_timestamp()
);
--
-- It must end with the provenance column, which the landing table copies
-- across on append so that it records when a row was extracted rather than
-- when it was appended:
--
--   loaded_at timestamp NOT NULL DEFAULT clock_timestamp()
--
-- clock_timestamp() rather than now(): now() returns the transaction start
-- time, so every row in a batch would share a value and progress through a
-- load would be invisible.

-- ---------------------------------------------------------------------------
-- Guarded casts
-- ---------------------------------------------------------------------------
-- Used by the transformation into rep. Each returns NULL rather than raising,
-- so a value FileMaker allowed but PostgreSQL will not accept degrades a
-- single field instead of failing a statement.
--
-- numeric, not integer: FileMaker's Number type is float-based, so every
-- numeric value arrives as a float - COUNT(*) returns 11136.0, not 11136.

CREATE OR REPLACE FUNCTION stg.try_ts(t text) RETURNS timestamp AS $$
BEGIN RETURN t::timestamp; EXCEPTION WHEN others THEN RETURN NULL; END $$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION stg.try_date(t text) RETURNS date AS $$
BEGIN RETURN t::date; EXCEPTION WHEN others THEN RETURN NULL; END $$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION stg.try_time(t text) RETURNS time AS $$
BEGIN RETURN t::time; EXCEPTION WHEN others THEN RETURN NULL; END $$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION stg.try_numeric(t text) RETURNS numeric AS $$
BEGIN RETURN t::numeric; EXCEPTION WHEN others THEN RETURN NULL; END $$
LANGUAGE plpgsql IMMUTABLE;

-- ---------------------------------------------------------------------------
-- Parse exceptions
-- ---------------------------------------------------------------------------
-- Written by the transformation when a guarded cast returns NULL. run_id is
-- defaulted from a session variable the extractor sets before invoking the
-- transform, so exceptions are attributable to a run without filtering a
-- growing table by timestamp. The 'true' argument makes current_setting
-- return NULL rather than error when it is unset, so ad-hoc calls still work.

CREATE TABLE IF NOT EXISTS stg.parse_errors (
    error_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id        BIGINT DEFAULT NULLIF(current_setting('elt.run_id', true), '')::BIGINT,
    source_table  TEXT NOT NULL,
    source_column TEXT NOT NULL,
    raw_value     TEXT,
    error_type    TEXT NOT NULL,
    logged_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
-- Last in the file so that ALL TABLES covers the tables created above.
--
-- SELECT and INSERT only. No TRUNCATE, DELETE or UPDATE: the extractor reads
-- the watermark, counts rows and appends. Emptying this schema is an
-- administrative act and stays outside what the service account can do.

GRANT USAGE ON SCHEMA stg TO svc_py;
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA stg TO svc_py;
ALTER DEFAULT PRIVILEGES FOR ROLE pp_owner IN SCHEMA stg GRANT SELECT, INSERT ON TABLES TO svc_py;

-- The guarded casts are called by the transformation, which runs as its owner,
-- but granting EXECUTE costs nothing and keeps ad-hoc use working.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA stg TO svc_py;

RESET ROLE;
