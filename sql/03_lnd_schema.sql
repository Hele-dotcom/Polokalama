-- ---------------------------------------------------------------------------
-- 03  lnd - landing
-- ---------------------------------------------------------------------------
-- Where each run lands before appending into stg. Two reasons it exists.
--
-- Inspectability: after a run, the landing table holds exactly that run's
-- delta, so an unexpected result can be examined in isolation rather than
-- hunted for inside the history.
--
-- Grants: landing tables need TRUNCATE and stg tables must never have it.
-- PostgreSQL has no schema-level TRUNCATE, and ALTER DEFAULT PRIVILEGES is the
-- only way to cover tables that do not exist yet - so in a single schema the
-- rule cannot be expressed, and every new table needs a hand-written grant.
-- The failure mode matters: when one is forgotten the run fails with
-- "permission denied", and the quick fix under pressure is to grant TRUNCATE
-- across the schema, which would let the nightly job empty the history. A
-- separate schema removes the temptation by removing the problem.
--
-- Landing tables are rebuildable by definition, so backups can exclude them
-- with a flag rather than a maintained list:  pg_dump --exclude-schema=lnd
--
-- Re-run this file after adding a staging table. It is idempotent.
-- ---------------------------------------------------------------------------


-- Everything below is created as pp_owner, so that ownership is consistent and
-- ALTER DEFAULT PRIVILEGES below applies to it. Default privileges attach to a
-- granting role, not to a schema: declared while running as someone else, they
-- silently do not cover tables pp_owner creates - which shows up months later
-- as a new table with no grants on it.
SET ROLE pp_owner;

CREATE SCHEMA IF NOT EXISTS lnd;
GRANT USAGE ON SCHEMA lnd TO svc_py;

-- Derived from stg rather than listed by hand, so the two cannot drift. A
-- landing table that does not exist is a broken run; generating them removes
-- the chance of forgetting one.
DO $$
DECLARE t record;
BEGIN
    FOR t IN SELECT table_name
             FROM   information_schema.tables
             WHERE  table_schema = 'stg'
               AND  table_type = 'BASE TABLE'
               AND  table_name <> 'parse_errors'      -- not an extract target
    LOOP
        EXECUTE format('CREATE TABLE IF NOT EXISTS lnd.%I (LIKE stg.%I INCLUDING DEFAULTS)',
                       t.table_name, t.table_name);
    END LOOP;
END $$;

-- Existing tables, then future ones. ALTER DEFAULT PRIVILEGES applies only to
-- tables created after it runs, and only to those created by the role running
-- it - so run it as the role that creates tables here.
GRANT SELECT, INSERT, TRUNCATE ON ALL TABLES IN SCHEMA lnd TO svc_py;
ALTER DEFAULT PRIVILEGES FOR ROLE pp_owner IN SCHEMA lnd
    GRANT SELECT, INSERT, TRUNCATE ON TABLES TO svc_py;

RESET ROLE;
