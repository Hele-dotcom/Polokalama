"""
FileMaker -> PostgreSQL extractor
=================================

Runs on the FileMaker Server VM. Reads over the FileMaker ODBC client driver on
the loopback interface, writes to the stg schema on the reporting server, and
records every run in the elt schema.

Table-agnostic: every table is a config entry, so adding one is configuration
rather than code. Not source-agnostic - the temporal converters, the qmark
parameter style and the identifier quoting are specific to FileMaker over ODBC
and PostgreSQL as the target.

This is the critical path established during build on 9 September 2026, with the
audit, locking and error handling a scheduled job needs. It is a base to extend,
not a finished production job: see the TODO markers and Appendix H of the
technical documentation.

    py fm_extract.py                 normal run
    py fm_extract.py --dry-run       extract and reconcile, write nothing

Options:
    --config <path>                  use a config other than the one beside
                                     this script (a second source database, or
                                     a test config against a copy)
    --trigger-source <label>         recorded in elt.load_run.trigger_source.
                                     Defaults to 'manual'; the scheduled task
                                     passes 'scheduled' explicitly, so an
                                     ad-hoc run is never mislabelled by a flag
                                     someone forgot at four in the afternoon.

There is no seed mode. Re-seeding is a deliberate administrative act: truncate
the main staging table by hand as an administrator, then run normally. The
service account has TRUNCATE in the lnd schema only, and the run pattern below
falls out of the empty target on its own - so the mode is derived from the data
rather than asserted by a flag that could disagree with it.

Each run lands in the lnd schema before appending into stg, so the delta from
the last run stays inspectable after the fact. The watermark is read from the
stg table, never from lnd, which holds only the last batch.

Two read patterns, chosen by whether a watermark floor exists:

  Bounded (a floor exists).  Reads floor < watermark <= ceiling, where the
  ceiling is one timestamp taken at the start of the run. The range is stable,
  so all three counts - source, extracted, loaded - must match exactly.

  Unbounded (no floor: an empty target).  Reads with no predicate at all. A bound that matches every record costs the source a full scan and buys
  nothing, and against a live system an unbounded read has no stable source
  count by definition. So an unbounded run reconciles extracted against loaded,
  and records the source count as informational rather than as a gate.

  This is safe because the next run's floor comes from max(watermark) over the
  data that actually landed, not from the ceiling this run used. A record
  created during an unbounded run either arrived - raising the floor - or sits
  above the floor and is collected next run. The ceiling exists for
  reconciliation, not for correctness of what follows.

Requires: Python 3.9+ (64-bit), pyodbc, psycopg2-binary.
Exit codes: 0 success, 1 failure, 2 could not start (config, lock, connection).
"""

import argparse
import datetime as dt
import json
import logging
import os
import socket
import struct
import sys

import psycopg2
import pyodbc
from psycopg2.extras import execute_values

# Derived from this script's own filename so that renaming the script renames
# the config it looks for, and the pair cannot drift apart.
CONFIG_PATH = os.path.splitext(os.path.abspath(__file__))[0] + ".config.json"

# One arbitrary but fixed key. Any run holding it blocks another from starting.
ADVISORY_LOCK_KEY = 8412771

# ODBC SQL type codes for DATE, TIME and TIMESTAMP. FileMaker permits temporal
# values Python cannot represent - a Time field may legitimately hold more than
# 24 hours - and pyodbc raises while building the object, destroying the whole
# batch rather than the single field. Taking them as text moves that failure to
# the typed layer in PostgreSQL, where it costs one field and is logged.
SQL_TYPE_DATE, SQL_TYPE_TIME, SQL_TYPE_TIMESTAMP = 91, 92, 93

log = logging.getLogger("fm_extract")


# ---------------------------------------------------------------- configuration

def load_config(path, require_tables=True):
    """Read and check the config.

    require_tables is False for the discovery tool, which takes its table on
    the command line - it shares this loader so that the connection settings
    are validated the same way.
    """
    if not os.path.exists(path):
        sys.stderr.write("Config not found: %s\n" % path)
        raise SystemExit(2)
    with open(path, "r", encoding="utf-8") as fh:
        cfg = json.load(fh)
    for key in ("filemaker", "postgres"):
        if key not in cfg:
            sys.stderr.write("Config is missing the '%s' section\n" % key)
            raise SystemExit(2)
    if require_tables and not cfg.get("tables"):
        sys.stderr.write("Config lists no tables\n")
        raise SystemExit(2)
    return cfg


def setup_logging(cfg):
    handlers = [logging.StreamHandler(sys.stdout)]
    logfile = cfg.get("log_file")
    if logfile:
        handlers.append(logging.FileHandler(logfile, encoding="utf-8"))
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
        handlers=handlers,
    )


# ---------------------------------------------------------------- connections

def connect_filemaker(fm):
    """Open the ODBC connection and register the temporal output converters.

    The converters are properties of the connection, so they must be registered
    again after any reconnect. Doing it here rather than at the call site is what
    stops a reconnect silently losing them.
    """
    cs = (
        "DRIVER={" + fm["driver"] + "};"
        "SERVER=" + fm["server"] + ";"
        "PORT=" + str(fm.get("port", 2399)) + ";"
        "DATABASE=" + fm["database"] + ";"
        "UID=" + fm["username"] + ";"
        "PWD=" + fm["password"]
    )
    cn = pyodbc.connect(cs, timeout=int(fm.get("connect_timeout_seconds", 20)))

    # The driver returns temporal values as ISO-ordered ASCII text, and pyodbc
    # parses that into date/time objects. FileMaker Time fields may hold values
    # beyond 24 hours, which have no Python equivalent, and the exception
    # destroys the whole batch being fetched rather than the single field.
    # Taking the text as-is avoids that; typing happens in PostgreSQL, where a
    # bad value costs one field and is logged. ISO order casts unambiguously.
    def as_text(raw):
        return None if raw is None else raw.decode("ascii", "replace").strip()

    for sql_type in (SQL_TYPE_DATE, SQL_TYPE_TIME, SQL_TYPE_TIMESTAMP):
        cn.add_output_converter(sql_type, as_text)

    return cn


def connect_postgres(pgcfg):
    return psycopg2.connect(
        host=pgcfg["host"], port=pgcfg.get("port", 5432), dbname=pgcfg["database"],
        user=pgcfg["username"], password=pgcfg["password"],
        connect_timeout=int(pgcfg.get("connect_timeout_seconds", 20)),
        # Keepalives stop a long-running statement being dropped by an idle
        # network timer between the extraction host and the reporting server.
        keepalives=1, keepalives_idle=30, keepalives_interval=10,
        application_name="fm_extract",
    )


# ---------------------------------------------------------------- audit
# The audit connection is deliberately separate and in autocommit. If it shared
# the connection doing the load, a failed batch would abort the transaction and
# roll back the record of its own failure - so the runs that most need evidence
# would be the ones that leave none.

class Audit:
    def __init__(self, conn):
        self.conn = conn
        self.conn.autocommit = True
        self.run_id = None

    def start_run(self, watermark_to, trigger_source):
        with self.conn.cursor() as c:
            c.execute(
                "INSERT INTO elt.load_run (watermark_to, trigger_source, host_name) "
                "VALUES (%s, %s, %s) RETURNING run_id",
                (watermark_to, trigger_source, socket.gethostname()))
            self.run_id = c.fetchone()[0]
        log.info("run %s started, watermark ceiling %s", self.run_id, watermark_to)
        return self.run_id

    def start_table(self, source_table, watermark_from):
        with self.conn.cursor() as c:
            c.execute(
                "INSERT INTO elt.load_table_run (run_id, source_table, watermark_from) "
                "VALUES (%s, %s, %s)", (self.run_id, source_table, watermark_from))

    def finish_table(self, source_table, source_n, extracted_n, staged_n, loaded_n,
                     status, error=None):
        with self.conn.cursor() as c:
            c.execute(
                "UPDATE elt.load_table_run SET source_row_count=%s, extracted_row_count=%s, "
                "staged_row_count=%s, loaded_row_count=%s, status=%s, error_message=%s, "
                "finished_at=clock_timestamp() WHERE run_id=%s AND source_table=%s",
                (source_n, extracted_n, staged_n, loaded_n, status, error,
                 self.run_id, source_table))

    def finish_run(self, status, error=None):
        with self.conn.cursor() as c:
            c.execute(
                "UPDATE elt.load_run SET status=%s, error_message=%s, "
                "finished_at=clock_timestamp() WHERE run_id=%s",
                (status, error, self.run_id))
        log.info("run %s finished: %s", self.run_id, status)


# ---------------------------------------------------------------- helpers

def quote(identifier):
    """Quote an identifier for FileMaker, preserving case (it is case-insensitive)."""
    return '"' + identifier.replace('"', '""') + '"'


def pgq(identifier):
    """Quote an identifier for PostgreSQL, folded to lower case.

    PostgreSQL folds unquoted identifiers to lower case but treats quoted ones
    as case-sensitive. Staging columns were created lower case, so config values
    carrying FileMaker's original casing must be folded here or every reference
    misses. FileMaker does not care either way, so one config value serves both.
    """
    return '"' + identifier.lower().replace('"', '""') + '"'


def acquire_lock(conn):
    """Refuse to start if a previous run is still going.

    Cheap insurance: a run that overruns its schedule would otherwise have the
    next one pile on top of it, doubling load on the application server and
    producing two sets of rows for the same window.
    """
    with conn.cursor() as c:
        c.execute("SELECT pg_try_advisory_lock(%s)", (ADVISORY_LOCK_KEY,))
        return c.fetchone()[0]


def current_watermark(conn, target_table, watermark_column):
    """Floor for this run: the newest record already staged.

    A record that failed to load previously keeps a modification timestamp above
    this floor, so it is re-presented next run without pulling the whole table.
    """
    with conn.cursor() as c:
        c.execute("SELECT max(%s::timestamp) FROM %s" % (pgq(watermark_column), target_table))
        return c.fetchone()[0]


def row_count(conn, target_table):
    with conn.cursor() as c:
        c.execute("SELECT count(*) FROM %s" % target_table)
        return c.fetchone()[0]


def source_count(fm_cur, source_table, watermark_column, wm_from, wm_to):
    """Count at source. Bounded when a floor exists, unbounded otherwise.

    Unbounded, this is a point-in-time observation of a live system and cannot
    be a reconciliation gate - the caller records it as informational.
    """
    sql = "SELECT COUNT(*) FROM %s" % quote(source_table)
    params = []
    if wm_from is not None:
        sql += " WHERE %s > ? AND %s <= ?" % (quote(watermark_column), quote(watermark_column))
        params = [wm_from, wm_to]
    fm_cur.execute(sql, *params)
    # FileMaker Numbers are float-based, so COUNT returns e.g. 11136.0.
    return int(fm_cur.fetchone()[0])


def build_select(source_table, columns, watermark_column, incremental):
    """Bounded read when a floor exists; otherwise no predicate at all.

    A ceiling that matches every record makes the source evaluate a find across
    the whole file before returning the first row - on FileMaker this was ten
    minutes against thirty seconds unbounded - while excluding only the handful
    of records created during the run, which the next run collects anyway.
    """
    cols = ", ".join(quote(c) for c in columns)
    sql = "SELECT " + cols + " FROM " + quote(source_table)
    if incremental:
        sql += " WHERE %s > ? AND %s <= ?" % (quote(watermark_column), quote(watermark_column))
    return sql


# ---------------------------------------------------------------- the load

def load_table(cfg, tbl, fm_cn, pg_cn, audit, wm_to, dry_run):
    """Extract one table into its landing table, then append into staging.

    Landing first keeps the delta from the last run inspectable after the fact,
    and concentrates the risk in a single atomic append rather than spreading it
    across every batch. A run that dies after landing but before the append
    leaves stg untouched, so the next run computes the same floor and re-pulls
    the same range into a freshly truncated landing table.

    Returns (source, extracted, staged, loaded, bounded).
    """
    source = tbl["source_table"]
    target = tbl["target_table"]
    # Landing tables live in their own schema so that TRUNCATE can be granted
    # there by default and withheld from stg entirely. PostgreSQL has no
    # schema-level TRUNCATE, so a single schema would force a per-table grant
    # for every new table - and the tempting fix when one is forgotten is to
    # grant it across the schema, which is exactly what must not happen.
    staging = tbl.get("staging_table") or ("lnd." + target.split(".")[-1])
    wm_col = tbl["watermark_column"]
    columns = tbl["columns"]
    batch_size = int(cfg.get("batch_size", 1000))

    # The floor comes from the stg table, never from lnd, which holds only the
    # last batch - reading it there would re-pull everything every night.
    wm_from = current_watermark(pg_cn, target, wm_col)
    incremental = wm_from is not None
    audit.start_table(source, wm_from)
    log.info("%s -> %s -> %s | %s | floor %s", source, staging, target,
             "bounded" if incremental else "unbounded (empty target)", wm_from)

    fm_cur = fm_cn.cursor()
    src_n = source_count(fm_cur, source, wm_col, wm_from, wm_to)
    log.info("%s: %s rows at source%s", source, src_n,
             " in range" if incremental else " (unbounded observation)")

    if not dry_run:
        with pg_cn.cursor() as c:
            c.execute("TRUNCATE %s" % staging)
        pg_cn.commit()

    sql = build_select(source, columns, wm_col, incremental)
    params = [wm_from, wm_to] if incremental else []
    fm_cur.execute(sql, *params)

    collist = ", ".join(pgq(c) for c in columns)
    insert_sql = "INSERT INTO " + staging + " (" + collist + ") VALUES %s"

    extracted = 0
    while True:
        raw = fm_cur.fetchmany(batch_size)
        if not raw:
            break
        # Staging is text throughout, so every value becomes text or NULL.
        # psycopg2 would otherwise send a float as a numeric literal, which
        # PostgreSQL will not implicitly cast into a text column. None is passed
        # through untouched so it lands as NULL rather than the string 'None'.
        batch = [tuple(None if v is None else str(v) for v in row) for row in raw]
        extracted += len(batch)
        if not dry_run:
            with pg_cn.cursor() as c:
                execute_values(c, insert_sql, batch)
            # Commit per batch into lnd, not per table. A dropped xDBC session
            # then costs one batch rather than the whole extract.
            pg_cn.commit()
        log.info("%s: %s rows", source, extracted)

    if dry_run:
        return src_n, extracted, 0, 0, incremental

    staged = row_count(pg_cn, staging)

    # The append: one statement, server-side, in one transaction. Columns are
    # listed explicitly rather than SELECT *, so the two tables need not share
    # a column order. loaded_at carries across, recording when the row was
    # extracted rather than when it was appended.
    before = row_count(pg_cn, target)
    with pg_cn.cursor() as c:
        c.execute("INSERT INTO %s (%s, loaded_at) SELECT %s, loaded_at FROM %s"
                  % (target, collist, collist, staging))
    pg_cn.commit()
    loaded = row_count(pg_cn, target) - before

    return src_n, extracted, staged, loaded, incremental


def main():
    ap = argparse.ArgumentParser(description="PolicePro to PostgreSQL extractor")
    ap.add_argument("--config", default=CONFIG_PATH)
    ap.add_argument("--dry-run", action="store_true",
                    help="extract and reconcile without writing to staging")
    # Defaults to manual: the scheduled task states its own source once, in a
    # definition nobody has to remember, whereas ad-hoc runs are exactly the
    # ones where a forgotten flag would quietly falsify the audit trail.
    ap.add_argument("--trigger-source", default="manual")
    args = ap.parse_args()

    cfg = load_config(args.config)
    setup_logging(cfg)

    # One timestamp taken up front and used as the ceiling for every table.
    # PolicePro is in use around the clock; without an upper bound, records
    # created between the count and the fetch make the reconciliation disagree
    # for no real reason, and the run cannot be reproduced.
    wm_to = dt.datetime.now().replace(microsecond=0)

    try:
        pg_cn = connect_postgres(cfg["postgres"])
        audit_cn = connect_postgres(cfg["postgres"])
    except Exception as exc:
        log.error("cannot reach the reporting server: %s", exc)
        return 2

    if not acquire_lock(pg_cn):
        log.error("a previous run still holds the lock; exiting without action")
        return 2

    audit = Audit(audit_cn)
    audit.start_run(wm_to, args.trigger_source)

    try:
        fm_cn = connect_filemaker(cfg["filemaker"])
        # Which account, in the log, every run. The FileMaker account decides
        # which tables are visible and readable at all, so when a table starts
        # failing this is the first thing worth ruling out.
        log.info("connected to %s as %s",
                 cfg["filemaker"]["database"], cfg["filemaker"]["username"])
    except Exception as exc:
        log.error("cannot reach PolicePro: %s", exc)
        audit.finish_run("failed", "filemaker connection: %s" % exc)
        return 2

    failures = []
    for tbl in cfg["tables"]:
        source = tbl["source_table"]
        try:
            src_n, extracted, staged, loaded, bounded = load_table(
                cfg, tbl, fm_cn, pg_cn, audit, wm_to, args.dry_run)
        except pyodbc.Error as exc:
            # FileMaker Server drops idle xDBC sessions, so a mid-run loss is an
            # expected condition. One reconnect and retry; if that fails the run
            # ends cleanly and the watermark lets the next one resume.
            log.warning("%s: source error, reconnecting and retrying once: %s", source, exc)
            try:
                pg_cn.rollback()
                fm_cn = connect_filemaker(cfg["filemaker"])
                src_n, extracted, staged, loaded, bounded = load_table(
                    cfg, tbl, fm_cn, pg_cn, audit, wm_to, args.dry_run)
            except Exception as exc2:
                log.error("%s: failed after retry: %s", source, exc2)
                pg_cn.rollback()
                audit.finish_table(source, None, None, None, None, "failed", str(exc2)[:2000])
                failures.append(source)
                continue
        except Exception as exc:
            log.error("%s: failed: %s", source, exc)
            pg_cn.rollback()
            audit.finish_table(source, None, None, None, None, "failed", str(exc)[:2000])
            failures.append(source)
            continue

        # A bounded read covers a stable range, so all three counts must match:
        # source against extracted catches a truncated fetch, extracted against
        # loaded catches a loss on the PostgreSQL side, and one comparison alone
        # would say something is wrong without saying which side.
        #
        # An unbounded read has no stable source count - the system is live - so
        # the source figure is recorded as an observation, and only extracted
        # against loaded can gate the run.
        # Four counts, and they isolate the failure. Source against extracted
        # catches a truncated fetch; extracted against staged catches a loss
        # writing to lnd; staged against loaded catches a failed append. One
        # comparison would say something is wrong without saying which side.
        #
        # An unbounded read has no stable source count - the system is live -
        # so the source figure is an observation there, not a gate.
        if args.dry_run:
            reconciled = True
        else:
            reconciled = (extracted == staged == loaded)
            if bounded:
                reconciled = reconciled and (src_n == extracted)
            elif src_n != extracted:
                log.info("%s: source held %s at count time, %s extracted - expected "
                         "on an unbounded read of a live system", source, src_n, extracted)
        status = "succeeded" if reconciled else "failed"
        if not reconciled:
            log.error("%s: reconciliation failed - source %s, extracted %s, staged %s, "
                      "loaded %s", source, src_n, extracted, staged, loaded)
            failures.append(source)
        else:
            log.info("%s: reconciled - %s rows", source, loaded)
        audit.finish_table(source, src_n, extracted, staged, loaded, status,
                           None if reconciled else "counts do not reconcile")

    if failures:
        audit.finish_run("failed", "tables failed: " + ", ".join(failures))
        return 1

    # Bring rep up to date from what has just landed. Only after every table
    # reconciled - a failure above returns before this point - and never on a
    # dry run, which wrote nothing to transform.
    #
    # wm_to is passed as the as-at date: the point PolicePro was read up to,
    # which is what a report means by "current to". The procedure runs as its
    # owner, so svc_py needs EXECUTE on it and nothing on rep. It commits or
    # rolls back as one unit, so rep and its watermark never disagree.
    if not args.dry_run:
        try:
            del pg_cn.notices[:]
            with pg_cn.cursor() as c:
                c.execute("CALL elt.run_transforms(%s)", (wm_to,))
            pg_cn.commit()
            for notice in pg_cn.notices:
                log.info("transform: %s", notice.strip().replace("NOTICE:  ", ""))
        except psycopg2.Error as exc:
            pg_cn.rollback()
            # The loads above are committed and stay. Nothing is lost: the
            # transform watermark did not move, so the next run - or a manual
            # CALL elt.run_transforms() - picks up these rows as well.
            log.error("transform failed: %s", exc)
            audit.finish_run("failed", "loaded, but transform failed: %s" % exc)
            return 1

    audit.finish_run("succeeded")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        sys.stderr.write("interrupted\n")
        raise SystemExit(1)
