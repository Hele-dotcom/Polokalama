-- ---------------------------------------------------------------------------
-- 04  elt - load audit
-- ---------------------------------------------------------------------------
-- The durable record of every run. The extraction process is transient and
-- Windows Task Scheduler keeps only a single overwritten result code, so this
-- is the only place a run's history survives.
--
-- Separate from stg deliberately. Staging is disposable and rebuildable from
-- source; the audit history is the one thing that is not, and a rebuild script
-- that drops and recreates stg must not be able to take it along. The split
-- also allows read access to load history without any privilege on staging,
-- which holds person-level policing data.
-- ---------------------------------------------------------------------------


-- Everything below is created as pp_owner, so that ownership is consistent and
-- ALTER DEFAULT PRIVILEGES below applies to it. Default privileges attach to a
-- granting role, not to a schema: declared while running as someone else, they
-- silently do not cover tables pp_owner creates - which shows up months later
-- as a new table with no grants on it.
SET ROLE pp_owner;

CREATE SCHEMA IF NOT EXISTS elt;
GRANT USAGE ON SCHEMA elt TO svc_py;

CREATE TABLE IF NOT EXISTS elt.load_run (
    run_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
    finished_at    TIMESTAMP,
    watermark_to   TIMESTAMP NOT NULL,   -- ceiling taken once, used by every table
    status         TEXT NOT NULL DEFAULT 'running'
                   CHECK (status IN ('running','succeeded','failed')),
    trigger_source TEXT NOT NULL DEFAULT 'manual',
    host_name      TEXT,
    error_message  TEXT
);

-- Four counts, because they isolate where a run went wrong:
--   source    vs extracted   a truncated or timed-out fetch
--   extracted vs staged      a loss writing to the landing table
--   staged    vs loaded      a failed append into stg
-- One comparison would say something is wrong without saying which side.
CREATE TABLE IF NOT EXISTS elt.load_table_run (
    run_id              BIGINT NOT NULL REFERENCES elt.load_run(run_id),
    source_table        TEXT NOT NULL,
    watermark_from      TIMESTAMP,        -- NULL means the read was unbounded
    source_row_count    INTEGER,
    extracted_row_count INTEGER,
    staged_row_count    INTEGER,
    loaded_row_count    INTEGER,
    started_at          TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
    finished_at         TIMESTAMP,
    status              TEXT NOT NULL DEFAULT 'running',
    error_message       TEXT,
    PRIMARY KEY (run_id, source_table)
);

GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA elt TO svc_py;
ALTER DEFAULT PRIVILEGES FOR ROLE pp_owner IN SCHEMA elt
    GRANT SELECT, INSERT, UPDATE ON TABLES TO svc_py;

-- No sequence grant is needed: run_id is GENERATED ALWAYS AS IDENTITY, and for
-- identity columns INSERT on the table is sufficient. A serial would differ.


-- ---------------------------------------------------------------------------
-- Extract watermark
-- ---------------------------------------------------------------------------
-- The floor for the next extract: the newest source modification timestamp
-- already in stg, per table.
--
-- Held here rather than computed as max(<watermark>::timestamp) from the
-- staging table, for two reasons. It is O(1) instead of a scan that grows with
-- history. And it cannot be indexed away: casting text to timestamp is STABLE,
-- not IMMUTABLE, because it depends on DateStyle, so PostgreSQL will not allow
-- an expression index on it.
--
-- The extractor updates this after a successful append, taking the maximum
-- from the landing table - which holds only that run's rows and is therefore
-- small - never from stg.
--
-- If it is ever lost or suspect, it is rebuildable:
--   INSERT INTO elt.extract_watermark (source_table, target_table, last_watermark)
--   SELECT 'PP', 'stg.pp', max(modification_date_timestamp::timestamp) FROM stg.pp
--   ON CONFLICT (source_table) DO UPDATE SET last_watermark = EXCLUDED.last_watermark;
-- An absent row is not an error: the extractor falls back to that scan, which
-- is also what makes a first run work.
CREATE TABLE IF NOT EXISTS elt.extract_watermark (
    source_table   TEXT PRIMARY KEY,
    target_table   TEXT NOT NULL,
    last_watermark TIMESTAMP NOT NULL,
    updated_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------------
-- Transform watermark
-- ---------------------------------------------------------------------------
-- How far each rep table has consumed its staging source, so the transform can
-- be incremental rather than rebuilding from the whole of stg every night.
--
-- Keyed on stg.loaded_at, NOT on the source modification timestamp. loaded_at
-- is the warehouse's own clock: it only moves forward, and a row that is
-- re-pulled after a failed batch gets a NEW loaded_at even though its source
-- timestamp is unchanged. A watermark on the source timestamp would silently
-- skip those rows, and skip anything backfilled with an older timestamp.
--
-- Held here rather than derived from rep because one staging table feeds
-- several rep tables, which can be at different points if one of them fails.
--
-- svc_py is deliberately granted nothing on this. The transform runs as its
-- owner through a SECURITY DEFINER procedure, so the loader updates this by
-- invoking that procedure and in no other way.
CREATE TABLE IF NOT EXISTS elt.transform_watermark (
    target_table   TEXT PRIMARY KEY,
    source_table   TEXT NOT NULL,
    last_loaded_at TIMESTAMP NOT NULL,   -- warehouse clock: how far consumed
    source_as_at   TIMESTAMP,            -- source clock: what the data is current to
    updated_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- source_as_at is recorded by the transform, not inferred later. It is the
-- ceiling of the load whose rows the transform has just consumed - the point
-- in time the source was read up to - and it is what a report means by "as at".
-- last_loaded_at cannot answer that: it is a warehouse processing time, which
-- says when a row was written here, not how current the underlying data is.
-- Inferring one from the other after the fact is guesswork, because rows are
-- committed throughout a run rather than at a single instant.

-- Transform lag. A rep table whose watermark is well behind the staging table
-- feeding it has stopped being transformed, which no error in the extractor
-- would reveal - the load can succeed every night while the model goes stale.
CREATE OR REPLACE VIEW elt.v_transform_lag AS
SELECT w.target_table, w.source_table, w.last_loaded_at,
       now() - w.last_loaded_at AS lag,
       now() - w.last_loaded_at > interval '26 hours' AS overdue
FROM   elt.transform_watermark w;

-- ---------------------------------------------------------------------------
-- Operational views
-- ---------------------------------------------------------------------------

-- The daily check. An empty result means the last run reconciled.
--
-- A NULL watermark_from means the read was unbounded, because the target was
-- empty. An unbounded read of a live system has no stable source count, so
-- source-against-extracted is not a defect there and must not be flagged. The
-- other two comparisons hold on every run.
CREATE OR REPLACE VIEW elt.v_load_exceptions AS
SELECT r.run_id, r.started_at, t.source_table, t.watermark_from,
       t.source_row_count, t.extracted_row_count,
       t.staged_row_count, t.loaded_row_count,
       t.status, COALESCE(t.error_message, r.error_message) AS error_message
FROM   elt.load_run r
JOIN   elt.load_table_run t USING (run_id)
WHERE  t.status <> 'succeeded'
   OR  t.extracted_row_count IS DISTINCT FROM t.staged_row_count
   OR  t.staged_row_count    IS DISTINCT FROM t.loaded_row_count
   OR  (t.watermark_from IS NOT NULL
        AND t.source_row_count IS DISTINCT FROM t.extracted_row_count);

-- A run still showing 'running' from a previous night died without being able
-- to record why - which no amount of error handling inside it can catch.
CREATE OR REPLACE VIEW elt.v_stalled_runs AS
SELECT * FROM elt.load_run
WHERE  status = 'running' AND started_at < now() - interval '6 hours';

-- Heartbeat for the pg_cron job. Deliberately hosted here rather than on the
-- extraction host: the failure most in need of detection is that host being
-- unavailable, and a watchdog that dies with the thing it watches is none.
-- COALESCE to true matters: with no successful run ever - a fresh install, or
-- a job that has been dead since before the audit was kept - max() is NULL and
-- the comparison is NULL, so a monitor testing "overdue = true" would stay
-- silent at exactly the moment it should not.
CREATE OR REPLACE VIEW elt.v_heartbeat AS
SELECT max(finished_at)                          AS last_success,
       now() - max(finished_at)                  AS age,
       COALESCE(now() - max(finished_at) > interval '26 hours', true) AS overdue
FROM   elt.load_run
WHERE  status = 'succeeded';

RESET ROLE;
