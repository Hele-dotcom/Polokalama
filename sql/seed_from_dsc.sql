-- ---------------------------------------------------------------------------
-- Seed a staging table from its discovery copy
-- ---------------------------------------------------------------------------
-- Generates, it does not run. Set the source table on the line marked below
-- and run this. It returns one row with two columns:
--
--   seed_script   the SQL that builds and fills the staging table. Copy it into
--                 a query window, read it, then run it.
--   config_entry  the matching entry for the "tables" array in
--                 fm_extract.config.json. Same column list, so the extract
--                 scope and the table it writes into cannot disagree.
--
-- The seed script, in one transaction:
--   1. creates stg.<table> from the latest profile - populated columns only,
--      all text, plus loaded_at - as pp_owner, so the grants and default
--      privileges reach it
--   2. refuses to go further if the profile was row-limited, or if the
--      staging table already holds rows
--   3. copies the same columns across from dsc.<table>
--   4. checks the two row counts agree before committing
--
-- Any failure rolls the whole thing back, table included, so a half-seeded
-- staging table cannot be left behind. That holds in pgAdmin and in psql,
-- with or without ON_ERROR_STOP.
--
-- Run as an administrator: it reads dsc, which pp_owner and svc_py cannot.
-- Afterwards, re-run 04_lnd_schema.sql to generate the landing table.
-- ---------------------------------------------------------------------------

WITH src AS (
    SELECT 'arr'::text AS source_table          -- <<< the only line to edit
),
latest AS (
    SELECT p.*
    FROM   dsc.column_profile p
    JOIN   src ON p.source_table = src.source_table
    WHERE  p.profiled_at = (SELECT max(x.profiled_at) FROM dsc.column_profile x
                            WHERE x.source_table = src.source_table)
),
facts AS (
    SELECT max(profiled_at)                          AS profiled_at,
           bool_or(sampled)                          AS sampled,
           count(*)                                  AS all_cols,
           count(*) FILTER (WHERE populated > 0)     AS kept_cols,
           -- %I quotes a name only when it needs quoting, which also makes a
           -- column name with a space or capital in it safe.
           string_agg(format('    %I text', column_name), E',\n'
                      ORDER BY column_name) FILTER (WHERE populated > 0) AS ddl_cols,
           string_agg(format('%I', column_name), E',\n       '
                      ORDER BY column_name) FILTER (WHERE populated > 0) AS col_list,
           -- to_json escapes anything that needs it, so the block below is
           -- valid JSON whatever the source called its columns.
           string_agg(to_json(column_name)::text, E',\n                '
                      ORDER BY column_name) FILTER (WHERE populated > 0) AS json_cols
    FROM   latest
),
-- The key: complete and unique in the profiled data. A FileMaker __pkey column
-- wins where several qualify. This is what the data supports, not a declaration
-- of intent - check it against the source before relying on it.
keyc AS (
    SELECT column_name
    FROM   latest
    WHERE  populated = total_rows AND distinct_values = populated AND populated > 0
    ORDER  BY (column_name LIKE '\_\_pkey%') DESC, column_name
    LIMIT  1
),
-- The watermark: parses as a timestamp in every populated row, and is named
-- like a modification rather than a creation. A creation timestamp is not a
-- substitute - it would capture new records and never reflect edits.
wmc AS (
    SELECT column_name
    FROM   latest
    WHERE  populated > 0 AND looks_timestamp = populated
      AND  column_name ~* '(modif|updat|changed|amend|edit)'
    ORDER  BY column_name
    LIMIT  1
)
SELECT CASE WHEN f.profiled_at IS NULL
            THEN '-- No profile for ' || s.source_table
                 || '. Run: py fm_discover.py --table ' || s.source_table
            WHEN f.kept_cols = 0
            THEN '-- Every column of ' || s.source_table || ' profiled as empty.'
                 || ' Check the pull returned rows before building a table from it.'
            ELSE format(
$script$-- Seed %1$s from %2$s
-- Profile of %3$s taken %4$s: %5$s of %6$s columns populated.

BEGIN;

SET ROLE pp_owner;
CREATE TABLE IF NOT EXISTS %1$s (
%7$s,
    loaded_at timestamp NOT NULL DEFAULT clock_timestamp()
);
RESET ROLE;

DO $guard$
BEGIN
    IF %8$L::boolean THEN
        RAISE EXCEPTION 'The profile this script was generated from was row-limited'
            USING HINT = 'Fill rates reflect the sample, so real columns may be '
                         'missing from the table. Re-run fm_discover.py without '
                         '--limit, then regenerate.';
    END IF;
    IF EXISTS (SELECT 1 FROM %1$s) THEN
        RAISE EXCEPTION '%1$s already holds rows'
            USING HINT = 'Seeding is for an empty table. Re-seeding means '
                         'truncating it first, deliberately, as an administrator.';
    END IF;
END $guard$;

INSERT INTO %1$s (
       %9$s,
       loaded_at)
SELECT %9$s,
       loaded_at
FROM   %2$s;

DO $check$
DECLARE n_dsc bigint; n_stg bigint;
BEGIN
    SELECT count(*) INTO n_dsc FROM %2$s;
    SELECT count(*) INTO n_stg FROM %1$s;
    IF n_dsc <> n_stg THEN
        RAISE EXCEPTION 'Row counts disagree: dsc %%, stg %%', n_dsc, n_stg;
    END IF;
    RAISE NOTICE 'Seeded %%: %% rows', '%1$s', n_stg;
END $check$;

COMMIT;
$script$,
                format('stg.%I', lower(s.source_table)),     -- %1
                format('dsc.%I', lower(s.source_table)),     -- %2
                s.source_table,                              -- %3
                f.profiled_at,                               -- %4
                f.kept_cols,                                 -- %5
                f.all_cols,                                  -- %6
                f.ddl_cols,                                  -- %7
                f.sampled,                                   -- %8
                f.col_list)                                  -- %9
       END AS seed_script,

       CASE WHEN f.profiled_at IS NULL OR f.kept_cols = 0 THEN NULL
            ELSE format(
$cfg${
    "source_table": %1$s,
    "target_table": %2$s,
    "staging_table": %3$s,
    "key_column": %4$s,
    "watermark_column": %5$s,
    "columns": [
                %6$s
    ]
}$cfg$,
                to_json(s.source_table)::text,                       -- %1
                to_json(format('stg.%I', lower(s.source_table)))::text,  -- %2
                to_json(format('lnd.%I', lower(s.source_table)))::text,  -- %3
                to_json(coalesce((SELECT column_name FROM keyc),
                                 'NO UNIQUE COMPLETE COLUMN IN THE PROFILE - SET THIS BY HAND'))::text,
                to_json(coalesce((SELECT column_name FROM wmc),
                                 'NO MODIFICATION TIMESTAMP IN THE PROFILE - FULL REFRESH ONLY'))::text,
                f.json_cols)
       END AS config_entry
FROM   src s CROSS JOIN facts f;
