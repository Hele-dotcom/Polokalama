-- ---------------------------------------------------------------------------
-- 02  dsc - discovery
-- ---------------------------------------------------------------------------
-- Working area for investigating source tables before they enter the pipeline.
-- Full-width copies pulled straight from FileMaker, and the column profiles
-- derived from them.
--
-- Deliberately not lnd. Landing tables are generated from stg, truncated every
-- run and granted TRUNCATE to the service account; discovery tables are ad hoc,
-- created by hand, and outlive a single run. Mixing them would blur what lnd
-- means and leave orphans in it that the generator does not manage.
--
-- The service account is granted nothing here. Discovery is administrative
-- work: it creates tables, which svc_py cannot do and should not.
--
-- Excluded from backups along with lnd - everything here is reproducible from
-- source:  pg_dump --exclude-schema=lnd --exclude-schema=dsc
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS dsc;

-- Accumulates across tables, so the profile becomes a single artefact covering
-- everything examined rather than a query someone has to remember to re-run.
-- It is the evidence base for two separate conversations: which columns the
-- extract should carry, and which fields the vendor might retire.
CREATE TABLE IF NOT EXISTS dsc.column_profile (
    source_table     TEXT NOT NULL,
    column_name      TEXT NOT NULL,
    total_rows       INTEGER NOT NULL,
    populated        INTEGER NOT NULL,   -- neither NULL nor empty string
    pct_filled       NUMERIC(5,1),
    distinct_values  INTEGER,
    looks_timestamp  INTEGER,            -- pattern counts, not cast attempts
    looks_date       INTEGER,
    looks_numeric    INTEGER,
    min_value        TEXT,
    max_value        TEXT,
    sampled          BOOLEAN NOT NULL DEFAULT false,  -- true if row-limited
    -- now(), not clock_timestamp(): this identifies the profiling run, so
    -- every row from one pass must share it. clock_timestamp() advances within
    -- a statement, which would give each column its own value and make "the
    -- latest profile" mean a single row. The opposite choice from loaded_at in
    -- stg, for the opposite reason - there per-row progress is the point.
    profiled_at      TIMESTAMP NOT NULL DEFAULT now(),
    PRIMARY KEY (source_table, column_name, profiled_at)
);

-- Columns carrying nothing at all. Candidates for the vendor to review, not a
-- deletion list: a field empty in this data may still be referenced by a
-- calculation, script or relationship. The FileMaker Database Design Report is
-- the complement - data says nobody fills it in, the DDR says nothing depends
-- on it, and both are needed before anything is removed.
CREATE OR REPLACE VIEW dsc.v_empty_columns AS
SELECT source_table, column_name, total_rows, sampled
FROM   dsc.column_profile p
WHERE  populated = 0
  AND  profiled_at = (SELECT max(profiled_at) FROM dsc.column_profile x
                      WHERE x.source_table = p.source_table)
ORDER  BY source_table, column_name;

-- Populated but never varying: no use for reporting, and a different
-- conversation with the vendor from a field nobody fills in.
CREATE OR REPLACE VIEW dsc.v_constant_columns AS
SELECT source_table, column_name, populated, min_value AS the_only_value
FROM   dsc.column_profile p
-- populated > 1: a column with a single populated row shows no variation
-- because there is nothing to vary against, not because it is constant. It
-- belongs in the fill-rate figures, not here.
WHERE  populated > 1 AND distinct_values = 1
  AND  profiled_at = (SELECT max(profiled_at) FROM dsc.column_profile x
                      WHERE x.source_table = p.source_table)
ORDER  BY source_table, column_name;

-- Watermark candidates. A modification timestamp is what makes incremental
-- extraction possible; a creation timestamp is not a substitute, because it
-- would capture new records only and silently never reflect edits.
CREATE OR REPLACE VIEW dsc.v_watermark_candidates AS
SELECT source_table, column_name, populated, min_value, max_value,
       CASE WHEN column_name ~* '(modif|updat|changed|amend|edit)' THEN 'modification'
            WHEN column_name ~* 'creat'                            THEN 'creation (not usable)'
            ELSE 'unclassified' END AS kind
FROM   dsc.column_profile p
WHERE  looks_timestamp > 0
  AND  looks_timestamp = populated          -- every populated value parses
  AND  profiled_at = (SELECT max(profiled_at) FROM dsc.column_profile x
                      WHERE x.source_table = p.source_table)
ORDER  BY source_table, kind, column_name;

-- The catalog is not a list of readable tables. cursor.tables() reports every
-- base table the account's privilege set names - including tables reached
-- through external data sources whose files are not open on the server. Those
-- appear in the list and then raise <File Missing> (100) on the first SELECT,
-- and table_cat, the one catalog column that would identify them, is NULL for
-- every row the FileMaker driver returns.
--
-- So the readable set is established by asking: fm_discover.py --probe reads
-- one row from each table and records what happened here. Consult this before
-- committing a full pull to any table - a wide one takes a quarter of an hour.
--
-- probed_at identifies the run and is the same for every row in it. The value
-- is taken once from the server and passed in explicitly rather than
-- defaulted, because a probe of five hundred tables commits as it goes, so its
-- rows are written across hundreds of transactions - a default of now() would
-- give each one its own.
CREATE TABLE IF NOT EXISTS dsc.table_probe (
    source_table  TEXT NOT NULL,
    status        TEXT NOT NULL,      -- ok | missing | denied | timeout | error
    readable      BOOLEAN NOT NULL,
    column_count  INTEGER,            -- ok only, and it is the real width
    has_rows      BOOLEAN,            -- readable but empty is not a failure
    elapsed_ms    INTEGER,
    sqlstate      TEXT,
    native_error  INTEGER,            -- FileMaker's own code, 100 and friends
    message       TEXT,
    probed_at     TIMESTAMP NOT NULL,
    PRIMARY KEY (source_table, probed_at),
    CONSTRAINT table_probe_status_ck CHECK (
        status IN ('ok', 'missing', 'denied', 'timeout', 'error'))
);

-- Latest verdict per table, not per run: --probe accepts --like, so a narrow
-- re-probe of a handful of tables must not hide the full sweep that preceded
-- it. Same reasoning as column_profile, which is scoped per source_table for
-- the same reason.
CREATE OR REPLACE VIEW dsc.v_table_probe_latest AS
SELECT p.*
FROM   dsc.table_probe p
WHERE  p.probed_at = (SELECT max(x.probed_at) FROM dsc.table_probe x
                      WHERE x.source_table = p.source_table);

-- The working list: everything a full pull can be attempted against.
CREATE OR REPLACE VIEW dsc.v_readable_tables AS
SELECT source_table, column_count, has_rows, elapsed_ms, probed_at
FROM   dsc.v_table_probe_latest
WHERE  readable
ORDER  BY source_table;

-- Everything else, with the reason. 'missing' is the expected bulk of it and
-- needs no action here; 'denied' is a privilege-set question for the FileMaker
-- administrator; 'timeout' means the table did not answer in time, which is
-- not the same as unreadable - re-probe it alone with a longer
-- --probe-timeout before concluding anything.
CREATE OR REPLACE VIEW dsc.v_unreadable_tables AS
SELECT source_table, status, native_error, message, probed_at
FROM   dsc.v_table_probe_latest
WHERE  NOT readable
ORDER  BY status, source_table;

-- ---------------------------------------------------------------------------
-- Generators
-- ---------------------------------------------------------------------------
-- The profile is the source of truth for the extract scope, so the staging
-- DDL and the config's column list are derived from it rather than typed out.
-- Both read the latest profile for the named source table.
--
-- Functions rather than a script of queries: no client-side variables to set,
-- nothing to edit before running, and they work the same from psql, pgAdmin
-- and a script. They replace the hand-edited profiler.sql.
--
--   SELECT dsc.stg_ddl('PP');       -- paste into 03_stg_schema.sql and run
--   SELECT dsc.column_list('PP');   -- paste into the config's "columns"
--
-- Column names come back lower case because the discovery table was created
-- that way, which is what staging expects - the extractor folds FileMaker's
-- casing to match. They are quoted anyway, so a name needing quoting works.

-- The populated subset, quoted and comma-separated, ready for the config.
CREATE OR REPLACE FUNCTION dsc.column_list(p_source text)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT string_agg('"' || column_name || '"', ', ' ORDER BY column_name)
    FROM   dsc.column_profile
    WHERE  source_table = p_source
      AND  populated > 0
      AND  profiled_at = (SELECT max(profiled_at) FROM dsc.column_profile
                          WHERE source_table = p_source);
$$;

-- The staging table, all text, populated columns only.
--
-- It refuses to emit from a row-limited profile. A sampled pull understates
-- fill rates - a rarely-used field looks empty - so the DDL would silently
-- omit real columns, and the omission would not surface until someone went
-- looking for data that was never extracted. Re-profile in full, or pass
-- p_allow_sampled to accept it deliberately.
CREATE OR REPLACE FUNCTION dsc.stg_ddl(p_source        text,
                                       p_target        text    DEFAULT NULL,
                                       p_allow_sampled boolean DEFAULT false)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_at      timestamp;
    v_sampled boolean;
    v_cols    text;
BEGIN
    SELECT max(profiled_at) INTO v_at
    FROM   dsc.column_profile WHERE source_table = p_source;

    IF v_at IS NULL THEN
        RAISE EXCEPTION 'No profile for %. Run: py fm_discover.py --table %',
            p_source, p_source;
    END IF;

    SELECT bool_or(sampled) INTO v_sampled
    FROM   dsc.column_profile
    WHERE  source_table = p_source AND profiled_at = v_at;

    IF v_sampled AND NOT p_allow_sampled THEN
        RAISE EXCEPTION 'The latest profile of % was row-limited', p_source
            USING HINT = 'Fill rates reflect the sample, so populated columns '
                         'can look empty and would be left out of the table. '
                         'Re-run fm_discover.py without --limit, or call with '
                         'p_allow_sampled => true.';
    END IF;

    SELECT string_agg('    "' || column_name || '" text', ',' || E'\n'
                      ORDER BY column_name)
    INTO   v_cols
    FROM   dsc.column_profile
    WHERE  source_table = p_source AND profiled_at = v_at AND populated > 0;

    IF v_cols IS NULL THEN
        RAISE EXCEPTION 'Every column of % profiled as empty', p_source
            USING HINT = 'Check the pull returned rows before building a table '
                         'from it.';
    END IF;

    -- clock_timestamp(), not now(): now() returns the transaction start time,
    -- so every row in a batch would share a value and progress through a load
    -- would be invisible. The landing table copies this column across on
    -- append, so it records when a row was extracted, not when it was
    -- appended.
    RETURN 'CREATE TABLE IF NOT EXISTS stg.' || coalesce(p_target, lower(p_source))
           || ' (' || E'\n' || v_cols || ',' || E'\n'
           || '    loaded_at timestamp NOT NULL DEFAULT clock_timestamp()'
           || E'\n);';
END $$;
