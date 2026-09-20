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
    py fm_discover.py --probe                    which of them can actually be read
    py fm_discover.py --table Charges            pull in full, then profile
    py fm_discover.py --table Charges --limit 2000    a quick look first
    py fm_discover.py --profile dsc.charges      re-profile without re-pulling

The catalog is not a list of readable tables. It reports every table the
account's privilege set names, including tables belonging to external data
sources whose files are not hosted - those raise <File Missing> (100) on the
first SELECT, and nothing in the catalog distinguishes them beforehand.
--probe settles it empirically: one FETCH FIRST 1 ROWS ONLY per table, results
in dsc.table_probe. Run it before investing a full pull in any one table.

Read-only against FileMaker: SELECT and COUNT, nothing else.

PRIVACY: the profile records value shapes, and min and max per column. For a
name or address column those are real values from real records. dsc is
operational data - do not export the profile without checking what is in it.
"""

import argparse
import os
import re
import sys
import time

import psycopg2
import pyodbc

# Connections and identifier quoting are shared with the extractor so that the
# temporal output converters cannot drift between the two. They are the reason
# a Time field holding more than 24 hours does not destroy a batch.
from fm_extract import connect_filemaker, connect_postgres, quote, pgq, load_config

CONFIG_PATH = os.path.splitext(os.path.abspath(__file__))[0] + ".config.json"
BATCH = 1000


def catalog_tables(fm_cn):
    """Every base table the catalog reports, with whatever provenance it carries.

    table_cat is the file a table belongs to, which would separate this file's
    own tables from those reached through external data sources. The FileMaker
    driver leaves it NULL for every row, so it cannot. That is why --probe
    exists.
    """
    cur = fm_cn.cursor()
    rows = []
    for r in cur.tables(tableType="TABLE"):
        rows.append((r.table_name, r.table_cat, r.table_schem, r.remarks))
    return rows


def list_tables(fm_cn, like=None):
    rows = catalog_tables(fm_cn)
    if like:
        rx = re.compile(like.replace("%", ".*").replace("_", "."), re.I)
        rows = [r for r in rows if rx.search(r[0])]
    print("%d tables in the catalog%s:\n"
          % (len(rows), " matching %r" % like if like else ""))
    print("    %-44s %-16s %-16s %s" % ("TABLE", "FILE", "SCHEMA", "REMARKS"))
    for name, cat, schem, remarks in sorted(rows):
        print("    %-44s %-16s %-16s %s"
              % (name, cat or "-", schem or "-", (remarks or "")[:40]))
    if all(r[1] is None for r in rows):
        print("\nFILE is NULL for every row: the driver exposes no provenance, so this")
        print("list cannot tell you which tables are backed by a hosted file. Run")
        print("--probe to find out which ones actually read.")
    print("\nNote the ODBC catalog exposes base tables. Layout names, which is what")
    print("exported CSVs are usually named after, will not always correspond.")


# --------------------------------------------------------------------- probe
#
# The catalog lists every table the privilege set names. It does not say which
# of them can be read. A table reached through an external data source whose
# file is not hosted appears in the list and then raises <File Missing> (100)
# the first time it is selected from, and table_cat - the one catalog column
# that would have identified it - is NULL for every row this driver returns.
#
# So: ask each table directly. One row, no predicate, fresh cursor. Most
# failures come back immediately, so five hundred tables is minutes.

# FileMaker's native error codes, as they appear in parentheses at the end of
# the driver's message text. Only the ones worth telling apart are listed; the
# rest fall through to 'error' with the driver's own wording kept intact.
FM_ERRORS = {
    100: ("missing",  "table's file is not open on the server, or the external "
                      "data source it comes from is unavailable"),
    101: ("error",    "record is missing"),
    105: ("missing",  "layout is missing"),
    204: ("denied",   "data access is denied for this account"),
    212: ("denied",   "account is not permitted to use the fmxdbc extended privilege"),
    213: ("denied",   "account or password is invalid"),
    802: ("missing",  "unable to open the file"),
}


def classify(exc):
    """(status, native_error, sqlstate, message) from a pyodbc exception.

    status is one of: missing, denied, timeout, link, error. 'link' is the one
    the caller acts on - FileMaker drops an idle xDBC session, and the cure is
    to reconnect rather than to record a verdict about the table.
    """
    args = list(getattr(exc, "args", []))
    sqlstate = args[0] if args else ""
    message = " ".join(str(a) for a in args[1:]) or str(exc)
    message = " ".join(message.split())

    native = None
    m = re.search(r"\((\d+)\)\s*(\(SQL\w+\))?\s*$", message)
    if m:
        native = int(m.group(1))

    if sqlstate in ("08S01", "08003", "08001", "HY000") and "link failure" in message.lower():
        return "link", native, sqlstate, message
    if sqlstate in ("HYT00", "HYT01"):
        return "timeout", native, sqlstate, message
    if native in FM_ERRORS:
        return FM_ERRORS[native][0], native, sqlstate, message
    if "not permitted" in message.lower() or "denied" in message.lower():
        return "denied", native, sqlstate, message
    return "error", native, sqlstate, message


def probe_one(fm_cn, name, timeout):
    """SELECT one row. Returns (status, column_count, has_rows, native, state, msg).

    A fresh cursor each time: a pyodbc cursor that has raised is not reliably
    reusable, and reusing one would make the next table's verdict depend on the
    previous table's failure.
    """
    try:
        fm_cn.timeout = timeout          # query timeout; connect(timeout=) is login only
    except Exception:
        pass                             # driver may not support it - not fatal
    cur = fm_cn.cursor()
    try:
        cur.execute("SELECT * FROM %s FETCH FIRST 1 ROWS ONLY" % quote(name))
        rows = cur.fetchall()
        ncols = len(cur.description) if cur.description else 0
        return "ok", ncols, bool(rows), None, None, None
    except pyodbc.Error as exc:
        status, native, state, msg = classify(exc)
        return status, None, None, native, state, msg
    finally:
        try:
            cur.close()
        except Exception:
            pass


PROBE_INSERT = """
INSERT INTO dsc.table_probe (
    source_table, status, readable, column_count, has_rows,
    elapsed_ms, sqlstate, native_error, message, probed_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
"""


def probe(fm_cn, pg_cn, cfg, names, timeout):
    with pg_cn.cursor() as c:
        c.execute("SELECT to_regclass('dsc.table_probe'), clock_timestamp()")
        exists, run_at = c.fetchone()
    if exists is None:
        raise SystemExit(
            "dsc.table_probe does not exist. Run sql/02_dsc_schema.sql against "
            "this database first.")

    # One timestamp for the whole run, taken from the server and passed
    # explicitly, so results can be committed as they are produced without each
    # commit giving its rows a different run identifier. The same reason
    # column_profile uses now() rather than clock_timestamp(), arrived at from
    # the other direction: here the run outlives its transaction.
    print("Probing %d tables (timeout %ds each). Ctrl-C is safe - results are "
          "committed as they are found.\n" % (len(names), timeout), flush=True)

    tally = {}
    for i, name in enumerate(sorted(names), 1):
        t0 = time.time()
        status, ncols, has_rows, native, state, msg = probe_one(fm_cn, name, timeout)

        if status == "link":
            # The session dropped rather than the table failing. Reconnect and
            # give this table its one fair attempt before recording anything.
            print("  ... connection dropped, reconnecting", flush=True)
            try:
                fm_cn.close()
            except Exception:
                pass
            fm_cn = connect_filemaker(cfg["filemaker"])
            t0 = time.time()
            status, ncols, has_rows, native, state, msg = probe_one(fm_cn, name, timeout)

        elapsed = int((time.time() - t0) * 1000)
        tally[status] = tally.get(status, 0) + 1
        with pg_cn.cursor() as c:
            c.execute(PROBE_INSERT, (name, status, status == "ok", ncols, has_rows,
                                     elapsed, state, native, msg, run_at))
        pg_cn.commit()

        if status == "ok":
            detail = "%d column%s%s" % (ncols, "" if ncols == 1 else "s",
                                        "" if has_rows else ", no rows")
        else:
            detail = FM_ERRORS.get(native, (None, msg))[1]
            if len(detail) > 76:
                detail = detail[:73] + "..."
        print("  [%4d/%d] %-9s %-44s %s" % (i, len(names), status, name, detail),
              flush=True)

    print("\n%d probed: %s" % (len(names),
          ", ".join("%s %s" % (v, k) for k, v in sorted(tally.items()))))
    print("\n  ok       readable, and the column count is real")
    print("  missing  in the catalog but its file is not open - not extractable")
    print("  denied   the account's privilege set does not reach it")
    print("  timeout  did not answer within %ds - retry alone before judging it" % timeout)
    print("\n  SELECT * FROM dsc.v_readable_tables;")
    print("  SELECT * FROM dsc.v_unreadable_tables;")
    return fm_cn


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
    ap.add_argument("--probe", action="store_true",
                    help="read one row from every listed table, record what worked")
    # %% not %: argparse expands % in help text, and a literal one raises at
    # --help time rather than when the option is used.
    ap.add_argument("--like",
                    help="restrict --list or --probe, LIKE style: --like '%%CHARGE%%'")
    ap.add_argument("--probe-timeout", type=int, default=30, metavar="SECONDS",
                    help="per-table query timeout for --probe (default 30)")
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
    # connect() authenticates but touches no data, so a session can open and
    # every subsequent read still fail. The account and file in play are worth
    # printing before anything long starts: a catalog that lists more tables
    # than expected usually means this config names a different account from
    # the extractor's, and the privilege set is what the catalog reflects.
    print("Connected to %s as %s"
          % (cfg["filemaker"]["database"], cfg["filemaker"]["username"]))

    if args.list:
        list_tables(fm_cn, args.like)
        return 0

    if args.probe:
        names = [r[0] for r in catalog_tables(fm_cn)]
        if args.like:
            rx = re.compile(args.like.replace("%", ".*").replace("_", "."), re.I)
            names = [n for n in names if rx.search(n)]
        if not names:
            print("No tables matched.")
            return 1
        pg_cn = connect_postgres(cfg["postgres"])
        probe(fm_cn, pg_cn, cfg, names, args.probe_timeout)
        return 0

    if not args.table:
        ap.error("one of --list, --probe, --table or --profile is required")

    pg_cn = connect_postgres(cfg["postgres"])
    target = args.target or ("dsc." + args.table.lower())

    print("Reading columns from %s ..." % args.table)
    try:
        cols = columns_of(fm_cn, args.table)
    except pyodbc.Error as exc:
        # A bare traceback here says nothing useful. The common case is a table
        # the catalog lists but no hosted file backs, and the fix is not in this
        # script.
        status, native, state, msg = classify(exc)
        sys.stderr.write("\n%s could not be read (%s).\n  %s\n" % (args.table, status, msg))
        if status == "missing":
            sys.stderr.write(
                "\n  Listed in the catalog, but its file is not open on the server -\n"
                "  typically a table reached through an external data source. Nothing\n"
                "  in the catalog marks these, so run --probe to get the readable set\n"
                "  before choosing the next table.\n")
        elif status == "denied":
            sys.stderr.write(
                "\n  The privilege set for %s does not reach this table's records.\n"
                % cfg["filemaker"]["username"])
        return 1
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
