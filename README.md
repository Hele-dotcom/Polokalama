# PolicePro reporting data warehouse - development set

Clean build of the extraction pipeline and the database it writes into.
Companion to the Reporting Server Technical Documentation, which carries the
architecture, the operational procedures and the outstanding-work register.

```
fm_extract.py                     the extractor - runs on the FileMaker Server VM
fm_extract.config.example.json    copy, fill in, lock down
fm_discover.py                    discovery - assess a table before it enters the pipeline
fm_discover.config.example.json   separate config, carries an ADMIN role
sql/01_database_and_roles.sql     run once as superuser, on the postgres database
sql/02_stg_schema.sql             staging
sql/03_lnd_schema.sql             landing - re-run after adding a staging table
sql/04_elt_schema.sql             load audit and the monitoring views
sql/05_rep_schema.sql             reporting - schema and rules only, not yet built
sql/06_dsc_schema.sql             discovery working area and the column profile
```

## The four schemas

| | Holds | Lifecycle | Service account may |
|---|---|---|---|
| `lnd` | The current run's delta, one table per source table | Disposable, truncated every run | SELECT, INSERT, **TRUNCATE** |
| `stg` | Source data as extracted, every column text | Append-only history | SELECT, INSERT |
| `elt` | Run audit and reconciliation counts | Durable, not rebuildable | SELECT, INSERT, UPDATE |
| `rep` | Typed dimensional model for Power BI | Rebuildable from `stg` | *nothing* |
| `dsc` | Full-width copies for investigation, and column profiles | Ad hoc, administrative | *nothing* |

The split between `lnd` and `stg` exists for the grants as much as for the
inspectability. Landing tables need TRUNCATE and staging tables must never have
it - and PostgreSQL has no schema-level TRUNCATE, so inside one schema that rule
cannot be expressed as a default and every new table would need a hand-written
grant. The failure mode is what settles it: when one is forgotten the run fails
with "permission denied", and the quick fix under pressure is to grant TRUNCATE
across the schema, which would let the nightly job empty the history.

`rep` gets no grant at all. When the transformation exists, make it
`SECURITY DEFINER` owned by `pp_owner` with an explicit `search_path`, and grant
`EXECUTE` - so the loader can invoke one controlled operation without holding any
privilege on the reporting model.

## Installing

**Database and roles**, once, as superuser on the `postgres` database:

```
psql -h 192.168.0.117 -U postgres -d postgres -f sql/01_database_and_roles.sql
```

`postgres` stays empty. It is the maintenance database - assumed to exist by
pgAdmin, `pg_dumpall`, and anything invoked without `-d` - so it is neither
renamed nor used to hold objects.

**Schemas**, connected to `pp_rdw`, in order. `02` contains a marked place for
the staging table DDL; paste it in before running, or create the tables first
and run `02` for the functions and grants:

```
psql -h 192.168.0.117 -U postgres -d pp_rdw -f sql/02_stg_schema.sql
psql -h 192.168.0.117 -U postgres -d pp_rdw -f sql/03_lnd_schema.sql
psql -h 192.168.0.117 -U postgres -d pp_rdw -f sql/04_elt_schema.sql
psql -h 192.168.0.117 -U postgres -d pp_rdw -f sql/05_rep_schema.sql
```

**`pg_hba.conf`** names the database, so it needs a line for the new one - and
specific rules must sit **above** general ones, because first match wins rather
than best match:

```
host    pp_rdw    svc_py    192.168.0.6/32    scram-sha-256
```

Reload rather than restart (`systemctl reload postgresql@18-main`) - it re-reads
the file without dropping connections. Then confirm PostgreSQL's own parse:

```sql
SELECT line_number, type, database, user_name, address, auth_method, error
FROM pg_hba_file_rules ORDER BY line_number;
```

**Extraction host** - 64-bit Python, matching the driver's architecture:

```
py -m pip install pyodbc psycopg2-binary
py -c "import pyodbc; print('\n'.join(pyodbc.drivers()))"
```

`FileMaker ODBC` must appear. A 32/64-bit mismatch reports as "driver not found"
even when the driver is installed.

**Config** - copy the example, fill it in, then restrict it. The log directory
must exist; the file itself is created:

```
icacls fm_extract.config.json /inheritance:r /grant:r "svc_ppextract:(R)" /grant:r "SYSTEM:(F)"
```

**First load:**

```
py fm_extract.py --dry-run
py fm_extract.py
```

Then `SELECT * FROM elt.v_load_exceptions;` - empty means it reconciled.

## Verifying the privilege model

Rather than assuming the grants landed:

```sql
SELECT has_table_privilege('svc_py','stg.pp','INSERT')    AS stg_insert_true,
       has_table_privilege('svc_py','stg.pp','TRUNCATE')  AS stg_truncate_false,
       has_table_privilege('svc_py','lnd.pp','TRUNCATE')  AS lnd_truncate_true,
       has_schema_privilege('svc_py','rep','USAGE')       AS rep_usage_false;
```

## How a run works

One timestamp is taken at the start and used as the ceiling for every table.
The floor is `max(watermark)` in the **stg** table - never `lnd`, which holds
only the last batch.

**A floor exists.** Reads `floor < watermark <= ceiling`. The range is stable, so
all four counts must agree exactly.

**No floor** - an empty target. Reads with **no predicate at all**. A ceiling
matching every record makes the source evaluate a find across the whole file
before returning a row; on FileMaker that was ten minutes against thirty seconds
unbounded, while excluding only records the next run collects anyway. There is
also no stable source count for an unbounded read of a live system, so the
source figure is recorded as an observation rather than used as a gate.

That is safe because the next floor comes from what actually landed, not from
the ceiling this run used. A record created mid-run either arrived - raising the
floor - or sits above it and is collected next run.

Each run truncates its landing table, loads it in batches committing as it goes,
reconciles, then appends into `stg` in one server-side statement. A run that
dies after landing but before the append leaves `stg` untouched, so the next run
computes the same floor and re-pulls the same range. The risk is concentrated in
one atomic step rather than spread across every batch.

**Four counts, because they isolate the failure:** source against extracted is a
truncated fetch, extracted against staged is a loss writing to `lnd`, staged
against loaded is a failed append.

## Re-seeding

There is no seed flag. Truncate `stg.<table>` by hand as an administrator, then
run normally - the empty target means no floor, so it reads unbounded and loads
everything. The service account has no TRUNCATE on `stg` by design, so this
cannot happen by accident or by bug.

Roughly fifteen minutes for the incident table. Nightly incremental runs are
seconds.

## Discovery - assessing a table before it enters the pipeline

`fm_discover.py` pulls a full-width copy into `dsc` and profiles every column.

```
py fm_discover.py --list                      tables visible to the account
py fm_discover.py --table Charges --limit 2000    a quick look
py fm_discover.py --table Charges             the real thing
py fm_discover.py --profile dsc.charges       re-profile without re-pulling
```

It runs as an administrator, not `svc_py`, because it creates tables. That is
why it reads its own config - the admin credentials stay out of the extractor's.

It prints a summary and writes to `dsc.column_profile`, which accumulates across
tables. Three views read it:

```sql
SELECT * FROM dsc.v_watermark_candidates;   -- can this table be incremental?
SELECT * FROM dsc.v_empty_columns;          -- carries nothing at all
SELECT * FROM dsc.v_constant_columns;       -- populated but never varies
```

`v_watermark_candidates` distinguishes modification timestamps from creation
timestamps and marks the latter unusable. A creation timestamp cannot serve as a
watermark: it captures new records only, so edits - a case finalisation, a person
merge - would never reach the reporting server, with nothing to signal the gap.

The empty and constant columns are the evidence base for the vendor conversation
about retiring unused fields. They are a **candidate list, not a deletion list**:
a field empty in the data may still be referenced by a calculation, script or
relationship. The FileMaker Database Design Report is the other half - data says
nobody fills it in, the DDR says nothing depends on it, and both are needed
before anything is removed.

`--limit` is for a first look only. A row-limited pull misrepresents fill rates,
because a rarely-used field looks empty; the profile records that it was sampled,
and the summary says so.

## Adding a source table

1. `py fm_discover.py --table <name>` and read the summary.
2. Confirm the watermark candidate is a **modification** timestamp, and that the
   field is **indexed** - FileMaker only searches quickly on indexed fields, and
   an unindexed watermark turns an incremental run back into a full scan. A
   bounded `COUNT(*)` over a week returning in well under a second is the check.
3. Take the populated columns as the extract scope.
4. Add the table DDL to `02_stg_schema.sql` and run it.
5. Re-run `03_lnd_schema.sql` - the landing table and its grants are generated
   from `stg`, so neither can be forgotten.
6. Add the config entry with the pinned column list.
7. `--dry-run`, then run.

## Things that will look like bugs and are not

**Numbers arrive as floats.** FileMaker's Number type is float-based, so
`COUNT(*)` returns `11136.0`. Target types are `numeric`, not `integer`.

**Temporal values arrive as text.** The driver returns ISO-ordered ASCII and
pyodbc would parse it into date/time objects - but FileMaker Time fields may
hold more than 24 hours, which has no Python equivalent, and the exception
destroys the entire batch being fetched while naming neither row nor column. The
output converters take the text as-is. Do not remove them because they look
redundant.

**Sessions drop.** FileMaker Server disconnects idle xDBC sessions. The
extractor reconnects and retries once, then fails cleanly with the audit row
recording how far it got.

**The audit connection is separate and in autocommit.** Sharing the load's
connection would mean a failed batch rolled back the record of its own failure -
so the runs most needing evidence would leave none.

## Not yet done

- The transform call is a marked TODO in `fm_extract.py`
- Only `PP` is configured; other tables need their base table names and
  watermark columns confirmed
- `stg` appends, so a record modified twice appears twice. De-duplication to
  latest-by-watermark belongs in the transform
- Failure notification is unconfigured. `elt.v_heartbeat` and
  `elt.v_stalled_runs` are the intended basis, run from pg_cron on the reporting
  server - deliberately not on the extraction host, since the failure most
  needing detection is that host being unavailable
- The log file does not rotate
- `stg.pp_raw` from the original discovery belongs in `dsc`, or can be dropped
  now the profile is captured
