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
