-- ---------------------------------------------------------------------------
-- 06  dsc - discovery
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
