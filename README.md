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

## Changing the column scope

The extract scope is pinned, and changing it is a deliberate act. Nothing in
the schema scripts alters an existing staging table: `CREATE TABLE IF NOT
EXISTS` makes them safe to re-run, which also means an edited column list in
`02_stg_schema.sql` has no effect on a table that already exists. Adding a
column is therefore a procedure, not a re-run.

### Adding a column

1. Re-profile the source and confirm the column is genuinely populated.
   A column that is empty in the data adds nothing but width, and retrieval
   cost is per row, so there is no penalty for leaving it out and no reward
   for carrying it.

2. Add it to staging. Additive, so history survives:

   ```sql
   ALTER TABLE stg.pp ADD COLUMN "new_column" text;
   ```

   Existing rows get NULL. That is honest - the data genuinely was never
   extracted for those records, and backfilling it would require a full
   re-seed, which is a separate decision.

3. Regenerate the landing table. It is derived from `stg` and disposable, so
   dropping it costs nothing, but it will not pick up the new column on its
   own - `03` skips tables that already exist:

   ```sql
   DROP TABLE lnd.pp;
   ```
   then re-run `sql/03_lnd_schema.sql`.

4. Add the column to the config's `columns` list.

5. **Update `02_stg_schema.sql`** so the script still reconstructs what
   exists. This is the step that gets skipped, and it is the one that matters:
   the scripts are only a recovery path while they match reality.

6. Run the drift check below.

7. `--dry-run`, then run.

### Removing a column

Usually this means *stopping extraction*, not dropping anything: take the
column out of the config's `columns` list and leave it in `stg`. Dropping it
discards history that cannot be recovered, because the source no longer
populates it. Drop the column only when the data itself is unwanted, and
record that decision.

### Drift check

Run this after any scope change, and periodically. It compares the staging
table against both the source profile and the landing table, so a column added
in one place and forgotten in another shows up here rather than at 2am:

```sql
SELECT 'stg vs profile' AS check, coalesce(s.column_name, p.column_name) AS column_name,
       CASE WHEN s.column_name IS NULL THEN 'populated at source, missing from stg'
            ELSE 'in stg, not populated at source' END AS detail
FROM  (SELECT column_name FROM information_schema.columns
       WHERE table_schema='stg' AND table_name='pp' AND column_name <> 'loaded_at') s
FULL JOIN
      (SELECT column_name FROM dsc.column_profile
       WHERE source_table='PP' AND populated > 0
         AND profiled_at = (SELECT max(profiled_at) FROM dsc.column_profile
                            WHERE source_table='PP')) p USING (column_name)
WHERE s.column_name IS NULL OR p.column_name IS NULL

UNION ALL

SELECT 'stg vs lnd', coalesce(s.column_name, l.column_name),
       CASE WHEN l.column_name IS NULL THEN 'in stg, missing from lnd - regenerate lnd'
            ELSE 'in lnd, not in stg' END
FROM  (SELECT column_name FROM information_schema.columns
       WHERE table_schema='stg' AND table_name='pp') s
FULL JOIN
      (SELECT column_name FROM information_schema.columns
       WHERE table_schema='lnd' AND table_name='pp') l USING (column_name)
WHERE s.column_name IS NULL OR l.column_name IS NULL;
```

An empty result means the script, the staging table, the landing table and the
source all agree. "in stg, not populated at source" is not necessarily a fault
- a field may simply have fallen out of use - but it is worth knowing, and it
is the signal that the fill-rate profile is due to be re-run.

## The transform, and data currency

Not built yet; `sql/05_rep_schema.sql` carries the pattern and the reasoning.
Two decisions in it are worth knowing before you build it.

**The transform is incremental, watermarked on `stg.loaded_at`** - not on the
source modification timestamp. `loaded_at` is the warehouse's own clock: it
only moves forward, and a row re-pulled after a failed batch gets a new one
even though its source timestamp is unchanged. A watermark on the source
timestamp would silently skip those rows, and anything backfilled with an
older timestamp. The position is held per target table in
`elt.transform_watermark`, because one staging table feeds several rep tables
and they can be at different points if one fails.

Casting therefore happens once per row, on the way into `rep`, rather than on
every rebuild. `stg` stays text, which is what keeps a load unable to fail.

**Two things make it correct, and both are easy to leave out.** `stg` is
append-only, so a record modified twice appears twice - the transform must
`ON CONFLICT ... DO UPDATE` rather than insert, or the second version sits
beside the first. And it needs `DISTINCT ON (key) ... ORDER BY key,
<watermark> DESC` to collapse duplicates *within* a batch, because PostgreSQL
refuses to let one statement affect the same row twice:

```
ERROR: ON CONFLICT DO UPDATE command cannot affect row a second time
```

**Data currency for reports** comes from `rep.v_data_currency`, which reports
`as_at` - the point in time the source was read up to for the data now in that
table. That is the honest answer to "how current is this report", and it is
deliberately not the time the report was run, which tells a reader nothing.

Reporting consumers hold SELECT on `rep` and nothing at all on `elt`, so the
figure is surfaced through a view: a view runs with its owner's privileges, so
it reaches `elt` on the reader's behalf without granting them access to it.

**One index note.** There is deliberately no index on the staging watermark
column. An expression index on `(modification_date_timestamp::timestamp)`
cannot be created - casting text to timestamp is STABLE rather than IMMUTABLE,
because it depends on `DateStyle`, and PostgreSQL refuses stable functions in
index expressions. The extractor reads its floor from `elt.extract_watermark`
instead, which is a single-row lookup rather than a scan that grows with
history. `stg.loaded_at` does want a plain index, for the transform.

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
