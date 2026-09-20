-- ---------------------------------------------------------------------------
-- 05  rep - reporting
-- ---------------------------------------------------------------------------
-- The typed dimensional model Power BI consumes. Not yet built.
--
-- Two rules established during discovery that apply when it is:
--
--   Numbers from FileMaker are float-based, so numeric is the target type,
--   not integer. Rounding a float into an integer column is how quiet
--   arithmetic errors start.
--
--   Time values may exceed 24 hours. Where those prove to be durations the
--   target type is interval, not time. Where they prove to be mis-keyed clock
--   times they are data quality exceptions. The two are indistinguishable by
--   type and must be told apart by looking at the values.
--
-- Which columns warrant which type is settled by counting how many values in
-- each column survive each guarded cast, rather than inferred from the field
-- names: a column where every value casts cleanly is that type; one where a
-- handful fail identifies the records to investigate.
--
--   SELECT count(*) FILTER (WHERE stg.try_ts(col) IS NOT NULL) AS as_timestamp,
--          count(*) FILTER (WHERE stg.try_numeric(col) IS NOT NULL) AS as_numeric,
--          count(*) AS total
--   FROM   stg.pp;
--
-- Access model when this is populated: reporting consumers are granted SELECT
-- on rep and nothing at all on stg, which holds person-level policing data in
-- its raw form.
-- ---------------------------------------------------------------------------


-- Everything below is created as pp_owner, so that ownership is consistent and
-- ALTER DEFAULT PRIVILEGES below applies to it. Default privileges attach to a
-- granting role, not to a schema: declared while running as someone else, they
-- silently do not cover tables pp_owner creates - which shows up months later
-- as a new table with no grants on it.
SET ROLE pp_owner;

CREATE SCHEMA IF NOT EXISTS rep;

-- svc_py is deliberately granted nothing here. When the transformation exists,
-- make it SECURITY DEFINER owned by pp_owner with an explicit search_path, and
-- grant EXECUTE to svc_py - so the loader can invoke one controlled operation
-- without holding any privilege on rep itself. An unpinned search_path on a
-- SECURITY DEFINER function is a known escalation route.
--
--   CREATE PROCEDURE elt.run_transforms() ... SECURITY DEFINER SET search_path = rep, stg, pg_temp;
--   GRANT EXECUTE ON PROCEDURE elt.run_transforms() TO svc_py;

-- ---------------------------------------------------------------------------
-- Data currency, for reporting
-- ---------------------------------------------------------------------------
-- What a report should print in its footer. Reporting consumers are granted
-- SELECT on rep and nothing at all on elt, so the figure has to be surfaced
-- here. A view runs with its owner's privileges, so this reaches elt on the
-- reader's behalf without granting them access to it.
--
-- as_at is the source-side cut-off: the point in time PolicePro was read up
-- to for the data now in this table. That is the honest answer to "how
-- current is this report", and it is deliberately not the time the report was
-- run, which tells a reader nothing about the data.
CREATE OR REPLACE VIEW rep.v_data_currency AS
SELECT w.target_table,
       w.source_as_at                        AS as_at,
       w.last_loaded_at                      AS transformed_to,
       now() - w.last_loaded_at              AS transform_lag,
       now() - w.last_loaded_at > interval '26 hours' AS stale
FROM   elt.transform_watermark w;

-- ---------------------------------------------------------------------------
-- Incremental transform - the pattern
-- ---------------------------------------------------------------------------
-- Not yet built. This is the shape it should take, and the reasons for each
-- part, so that it is not re-derived from scratch later.
--
-- CREATE OR REPLACE PROCEDURE elt.run_transforms()
-- LANGUAGE plpgsql SECURITY DEFINER SET search_path = rep, stg, elt, pg_temp
-- AS $$
-- DECLARE
--     wm        timestamp;
--     batch_to  timestamp;
--     src_as_at timestamp;
-- BEGIN
--     -- Floor: how far this target has already consumed its source.
--     SELECT last_loaded_at INTO wm FROM elt.transform_watermark
--     WHERE target_table = 'rep.fact_incident';
--     wm := coalesce(wm, '-infinity'::timestamp);
--
--     -- Ceiling, taken once. Same reasoning as the extractor: an unbounded
--     -- range over a table still being written to cannot be reconciled or
--     -- reproduced.
--     SELECT max(loaded_at) INTO batch_to FROM stg.pp WHERE loaded_at > wm;
--     IF batch_to IS NULL THEN RETURN; END IF;   -- nothing new
--
--     -- What the data is current to, recorded rather than inferred.
--     -- This is correct BECAUSE the transform runs immediately after the load
--     -- in the same process, so the newest successful run is the one whose
--     -- rows were just consumed. If the transform is ever decoupled and run
--     -- on its own schedule, this would overstate currency - claiming data is
--     -- current to a run whose rows are not in rep yet. The exact fix then is
--     -- to carry run_id on the staging rows, populated at append time, and
--     -- take max(watermark_to) over the runs present in the batch. That also
--     -- makes any row traceable to the run that loaded it.
--     SELECT max(watermark_to) INTO src_as_at FROM elt.load_run
--     WHERE status = 'succeeded';
--
--     WITH batch AS (
--         -- DISTINCT ON collapses duplicates WITHIN the batch. stg is
--         -- append-only, so a record modified twice between transforms
--         -- appears twice - and ON CONFLICT cannot affect the same row twice
--         -- in one statement, so without this the whole statement errors.
--         SELECT DISTINCT ON (__pkeypolicepro_id) *
--         FROM   stg.pp
--         WHERE  loaded_at > wm AND loaded_at <= batch_to
--         ORDER  BY __pkeypolicepro_id, modification_date_timestamp DESC
--     )
--     INSERT INTO rep.fact_incident (pk_policepro, creation_date_time, village, ...)
--     SELECT __pkeypolicepro_id,
--            stg.try_ts(creation_date_timestamp),
--            regexp_replace(initcap(village), '[\x00-\x1F\x7F]', '', 'g'),
--            ...
--     FROM   batch
--     -- The upsert is what makes incremental transform correct: the second
--     -- version of a record must replace the first, not sit beside it.
--     ON CONFLICT (pk_policepro) DO UPDATE
--     SET creation_date_time = EXCLUDED.creation_date_time,
--         village            = EXCLUDED.village;
--
--     INSERT INTO elt.transform_watermark (target_table, source_table,
--                                          last_loaded_at, source_as_at)
--     VALUES ('rep.fact_incident', 'stg.pp', batch_to, src_as_at)
--     ON CONFLICT (target_table) DO UPDATE
--     SET last_loaded_at = EXCLUDED.last_loaded_at,
--         source_as_at   = EXCLUDED.source_as_at,
--         updated_at     = clock_timestamp();
-- END $$;
--
-- Typing happens here, on the way into rep, using the guarded casts so that a
-- value PostgreSQL will not accept degrades one field rather than failing the
-- statement. Because the transform is incremental, each row is cast once in
-- its life rather than on every rebuild.
--
-- Business rules belong here too - the village cleaning, the name handling.
-- stg holds what the source gave us; rep holds what it means.

RESET ROLE;
