"""
FileMaker discovery
===================

Pulls a full-width copy of a source table into the dsc schema and profiles
every column, so a table can be assessed before it enters the pipeline.

Answers the three questions that decide whether and how a table is extracted:

  Is there a modification timestamp?  Without one, incremental extraction
  captures new records only and silently never reflects edits. A creation
  timestamp is not a substitute.

  Which columns carry data?  The extract scope is the populated subset, not
  everything the table exposes.

  What do the values look like?  Formats, character sets, stray whitespace,
  and how many values in each column would survive typing.

Administrative: it creates tables, which the extraction service account cannot
do and should not. Give it a config carrying an admin role - the script reads
fm_discover.config.json, so those credentials stay out of the extractor's.

    py fm_discover.py --list                     tables visible to the account
    py fm_discover.py --table Charges            pull in full, then profile
    py fm_discover.py --table Charges --limit 2000    a quick look first
    py fm_discover.py --profile dsc.charges      re-profile without re-pulling

Read-only against FileMaker: SELECT and COUNT, nothing else.

PRIVACY: the profile records value shapes, and min and max per column. For a
name or address column those are real values from real records. dsc is
operational data - do not export the profile without checking what is in it.
"""

import argparse
import os
import re
import sys

import psycopg2
import pyodbc

# Connections and identifier quoting are shared with the extractor so that the
# temporal output converters cannot drift between the two. They are the reason
# a Time field holding more than 24 hours does not destroy a batch.
from fm_extract import connect_filemaker, connect_postgres, quote, pgq, load_config

CONFIG_PATH = os.path.splitext(os.path.abspath(__file__))[0] + ".config.json"
BATCH = 1000


def list_tables(fm_cn):
    cur = fm_cn.cursor()
    names = [r.table_name for r in cur.tables(tableType="TABLE")]
    print("%d tables visible to this account:\n" % len(names))
    for n in sorted(names):
        print("   ", n)
    print("\nNote the ODBC catalog exposes base tables. Layout names, which is what")
    print("exported CSVs are usually named after, will not always correspond.")


def columns_of(fm_cn, source):
    """Column names and types, via a one-row query rather than the catalog.

    cursor.columns() reads FileMaker's ODBC catalog, which crawls on a large
    solution - minutes, sometimes appearing to hang. A one-row SELECT returns
    the same information through cursor.description in about a second, and the
    type it reports is the Python type pyodbc will actually produce.
    """
    cur = fm_cn.cursor()
    cur.execute("SELECT * FROM %s FETCH FIRST 1 ROWS ONLY" % quote(source))
    cur.fetchall()
    return [(d[0], d[1]) for d in cur.description]


def create_target(pg_cn, target, names):
    lowered = [n.lower() for n in names]
    dupes = {n for n in lowered if lowered.count(n) > 1}
    if dupes:
        raise SystemExit(
            "Column names collide when folded to lower case: %s\n"
            "PostgreSQL folds unquoted identifiers, so these cannot share a table."
            % ", ".join(sorted(dupes)))
    ddl = ", ".join(pgq(n) + " text" for n in names)
    with pg_cn.cursor() as c:
        c.execute("CREATE SCHEMA IF NOT EXISTS dsc")
        c.execute("DROP TABLE IF EXISTS %s" % target)
        c.execute("CREATE TABLE %s (%s, loaded_at timestamp NOT NULL DEFAULT clock_timestamp())"
                  % (target, ddl))
    pg_cn.commit()


def pull(fm_cn, pg_cn, source, target, names, limit):
    """Unbounded read: no predicate at all.

    A ceiling matching every record makes FileMaker evaluate a find across the
    whole file before returning the first row - measured at ten minutes against
    thirty seconds unbounded. Discovery has no floor to respect, so there is
    nothing to gain by bounding it.
    """
    from psycopg2.extras import execute_values
    cur = fm_cn.cursor()
    sql = "SELECT * FROM " + quote(source)
    if limit:
        sql += " FETCH FIRST %d ROWS ONLY" % limit
    cur.execute(sql)

    cols = ", ".join(pgq(n) for n in names)
    ins = "INSERT INTO " + target + " (" + cols + ") VALUES %s"
    total = 0
    while True:
        raw = cur.fetchmany(BATCH)
        if not raw:
            break
        # Every value becomes text or NULL. psycopg2 would send a float as a
        # numeric literal, which PostgreSQL will not implicitly cast into a
        # text column; None passes through so it lands as NULL rather than the
        # string 'None', which would quietly ruin the fill-rate figures.
        batch = [tuple(None if v is None else str(v) for v in row) for row in raw]
        with pg_cn.cursor() as c:
            execute_values(c, ins, batch)
        pg_cn.commit()
        total += len(batch)
        print("  %s rows" % total, flush=True)
    return total


# One pass over the table, unpivoted with jsonb so the query is independent of
# how many columns there are and keeps working when the column list changes.
#
# Pattern matching rather than the guarded cast functions: those wrap each
# value in a plpgsql exception block, which opens a subtransaction per call.
# Across a wide table that is millions of subtransactions and takes far longer
# than the pull did. A regex is approximate but fast, and the driver emits ISO
# order, so it is accurate enough to decide which columns deserve typing.
PROFILE_SQL = """
INSERT INTO dsc.column_profile (
    source_table, column_name, total_rows, populated, pct_filled,
    distinct_values, looks_timestamp, looks_date, looks_numeric,
    min_value, max_value, sampled)
SELECT %(label)s,
       j.key,
       count(*),
       count(*) FILTER (WHERE nullif(j.value, '') IS NOT NULL),
       round(100.0 * count(*) FILTER (WHERE nullif(j.value, '') IS NOT NULL)
             / nullif(count(*), 0), 1),
       count(DISTINCT nullif(j.value, '')),
       count(*) FILTER (WHERE j.value ~ '^\\d{4}-\\d{2}-\\d{2}[ T]\\d{2}:\\d{2}'),
       count(*) FILTER (WHERE j.value ~ '^\\d{4}-\\d{2}-\\d{2}$'),
       count(*) FILTER (WHERE j.value ~ '^-?\\d+(\\.\\d+)?$'),
       min(nullif(j.value, '')),
       max(nullif(j.value, '')),
       %(sampled)s
FROM   {table} t,
       LATERAL jsonb_each_text(to_jsonb(t)) AS j(key, value)
WHERE  j.key <> 'loaded_at'
GROUP  BY j.key
"""


def profile(pg_cn, table, label, sampled):
    # Plain replace, not str.format: the regexes contain {4} and {2}, which
    # format() would read as replacement fields and refuse.
    if not re.match(r"^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$", table):
        raise SystemExit("Refusing to profile %r - expected schema.table, "
                         "lower case, no quoting. The name is interpolated into "
                         "SQL and cannot be parameterised." % table)
    with pg_cn.cursor() as c:
        c.execute(PROFILE_SQL.replace("{table}", table),
                  {"label": label, "sampled": sampled})
    pg_cn.commit()

    with pg_cn.cursor() as c:
        c.execute("""
            SELECT count(*),
                   count(*) FILTER (WHERE populated = 0),
                   count(*) FILTER (WHERE populated > 0 AND distinct_values = 1),
                   max(total_rows)
            FROM   dsc.column_profile
            WHERE  source_table = %s
              AND  profiled_at = (SELECT max(profiled_at) FROM dsc.column_profile
                                  WHERE source_table = %s)""", (label, label))
        cols, empty, constant, rows = c.fetchone()

        c.execute("""
            SELECT column_name, kind, min_value, max_value
            FROM   dsc.v_watermark_candidates WHERE source_table = %s
            ORDER  BY kind, column_name""", (label,))
        candidates = c.fetchall()

    print("\n%s: %s rows, %s columns" % (label, rows, cols))
    print("  %s columns hold no value at all" % empty)
    print("  %s columns are populated but never vary" % constant)
    if sampled:
        print("  NOTE: row-limited pull. Fill rates reflect the sample, not the table -")
        print("        a rarely-used field can look empty. Re-run in full before")
        print("        anything here informs a decision.")

    print("\n  Watermark candidates:")
    if not candidates:
        print("    none - no column parses as a timestamp in every populated row.")
        print("    Incremental extraction is not safe for this table: it would capture")
        print("    new records only and never reflect edits, with nothing to signal it.")
        print("    Either raise a vendor change request for an auto-enter modification")
        print("    timestamp, or load this table by full refresh.")
    else:
        for name, kind, lo, hi in candidates:
            print("    %-34s %-22s %s .. %s" % (name, kind, lo, hi))
        if not any(k == "modification" for _, k, _, _ in candidates):
            print("\n    None is a modification timestamp. A creation timestamp cannot")
            print("    serve as a watermark - edits to existing records would never")
            print("    reach the reporting server.")

    print("\n  Next:")
    print("    SELECT * FROM dsc.v_empty_columns    WHERE source_table = '%s';" % label)
    print("    SELECT * FROM dsc.v_constant_columns WHERE source_table = '%s';" % label)


def main():
    ap = argparse.ArgumentParser(description="FileMaker discovery (read-only at source)")
    ap.add_argument("--config", default=CONFIG_PATH)
    ap.add_argument("--list", action="store_true", help="list tables and exit")
    ap.add_argument("--table", help="source table to pull and profile")
    ap.add_argument("--target", help="destination, default dsc.<lowercased source>")
    ap.add_argument("--limit", type=int, help="row limit for a first look")
    ap.add_argument("--profile", help="profile an existing dsc table without re-pulling")
    args = ap.parse_args()

    cfg = load_config(args.config, require_tables=False)

    if args.profile:
        pg_cn = connect_postgres(cfg["postgres"])
        label = args.profile.split(".")[-1]
        profile(pg_cn, args.profile, label, sampled=False)
        return 0

    fm_cn = connect_filemaker(cfg["filemaker"])
    if args.list:
        list_tables(fm_cn)
        return 0
    if not args.table:
        ap.error("one of --list, --table or --profile is required")

    pg_cn = connect_postgres(cfg["postgres"])
    target = args.target or ("dsc." + args.table.lower())

    print("Reading columns from %s ..." % args.table)
    cols = columns_of(fm_cn, args.table)
    print("  %d columns" % len(cols))

    names = [n for n, _ in cols]
    create_target(pg_cn, target, names)
    print("Pulling %s -> %s%s"
          % (args.table, target, " (limit %d)" % args.limit if args.limit else ""))
    rows = pull(fm_cn, pg_cn, args.table, target, names, args.limit)
    if rows == 0:
        print("No rows returned. The account may lack access to this table's records.")
        return 1

    print("Profiling ...")
    profile(pg_cn, target, args.table, sampled=bool(args.limit))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        sys.stderr.write("interrupted\n")
        raise SystemExit(1)
