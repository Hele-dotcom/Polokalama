-- ---------------------------------------------------------------------------
-- 07  rep - transforms
-- ---------------------------------------------------------------------------
-- Builds and maintains the reporting tables from stg, incrementally: each is
-- created once, and every run after that upserts only what has arrived in stg
-- since the last one. Currently rep.fact_incident and
-- rep.fact_incident_charge.
--
-- How it runs. fm_extract.py calls elt.run_transforms() once every table has
-- loaded and reconciled, passing the run's watermark ceiling as the as-at
-- date. It can also be called by hand at any time - it is idempotent, and
-- does nothing when nothing new has arrived:
--
--     CALL elt.run_transforms();
--
-- Adding a reporting table: write its CREATE TABLE and transform procedure
-- below, following rep.transform_fact_incident, then add one CALL line to
-- elt.run_transforms. Re-run this file.
--
-- Safe to re-run. Run as an administrator, connected to pp_rdw.
-- ---------------------------------------------------------------------------

-- A table created by hand while developing belongs to whoever created it,
-- usually postgres. The transform runs as pp_owner and could not write to it.
-- Transferring ownership fixes that, and is a no-op once it is right.
ALTER TABLE IF EXISTS rep.fact_incident OWNER TO pp_owner;
ALTER TABLE IF EXISTS rep.fact_incident_charge OWNER TO pp_owner;

SET ROLE pp_owner;

-- ---------------------------------------------------------------------------
-- rep.fact_incident
-- ---------------------------------------------------------------------------
-- One row per incident: the latest version of each PolicePro record.
CREATE TABLE IF NOT EXISTS rep.fact_incident (
    pk_incident                  text PRIMARY KEY,
    incident_no                  text,
    call_type                    text,
    call_source                  text,
    creation_date_timestamp      timestamp,
    modification_date_timestamp  timestamp,
    crime_type                   text,
    date_occurred                date,
    time_occurred                time,
    date_reported                date,
    time_received                time,
    time_dispatched              time,
    finalisation_status          text,
    incident_village             text,
    section                      text,
    location                     text,
    location_of_incident_street  text,
    location_of_incident_other   text,
    flag_alcohol                 boolean,
    flag_domestic                boolean,
    flag_narcotics               boolean,
    narcotics_type               text,
    flag_mental_health           boolean,
    flag_significant             boolean,
    loaded_at                    timestamp NOT NULL,   -- when this version reached stg
    transformed_at               timestamp NOT NULL DEFAULT clock_timestamp()
);

-- For a table that already existed before transformed_at was added.
ALTER TABLE rep.fact_incident
    ADD COLUMN IF NOT EXISTS transformed_at timestamp NOT NULL DEFAULT clock_timestamp();

-- Each call takes everything that reached stg.pp since the previous call,
-- keeps the latest version of each record, and upserts it.
--
-- The floor is stg.loaded_at, the warehouse's own clock, held in
-- elt.transform_watermark. Not the source modification timestamp: a record
-- re-pulled after a failed batch arrives with a new loaded_at but an unchanged
-- modification timestamp, and a source-clock watermark would skip it. On the
-- first call there is no floor, so it processes the whole of stg.pp - which is
-- how an existing rep table gets brought under this without a rebuild.
CREATE OR REPLACE PROCEDURE rep.transform_fact_incident(p_source_as_at timestamp)
LANGUAGE plpgsql AS $$
DECLARE
    wm         timestamp;
    batch_to   timestamp;
    n_batch    bigint;
    n_nokey    bigint;
    n_written  bigint;
BEGIN
    SELECT last_loaded_at INTO wm
    FROM   elt.transform_watermark WHERE target_table = 'rep.fact_incident';
    wm := coalesce(wm, '-infinity'::timestamp);

    -- Ceiling, taken once, so the batch is a fixed range rather than whatever
    -- happens to be in stg while the statement runs.
    SELECT max(loaded_at) INTO batch_to FROM stg.pp WHERE loaded_at > wm;
    IF batch_to IS NULL THEN
        RAISE NOTICE 'rep.fact_incident: nothing new in stg.pp since %', wm;
        RETURN;
    END IF;

    SELECT count(*), count(*) FILTER (WHERE __pkeypolicepro_id IS NULL)
    INTO   n_batch, n_nokey
    FROM   stg.pp WHERE loaded_at > wm AND loaded_at <= batch_to;

    INSERT INTO rep.fact_incident (
        pk_incident, incident_no, call_type, call_source,
        creation_date_timestamp, modification_date_timestamp, crime_type,
        date_occurred, time_occurred, date_reported, time_received,
        time_dispatched, finalisation_status, incident_village, section,
        location, location_of_incident_street, location_of_incident_other,
        flag_alcohol, flag_domestic, flag_narcotics, narcotics_type,
        flag_mental_health, flag_significant, loaded_at)
    SELECT
        __pkeypolicepro_id,
        bltr,
        call_type,
        call_source,
        stg.try_ts(creation_date_timestamp),
        stg.try_ts(modification_date_timestamp),
        crime_type,
        stg.try_date(date_occurred),
        stg.try_time(time_occurred),
        stg.try_date("date"),
        stg.try_time(time_received),
        stg.try_time(time_dispatched),
        finalisation_status,
        village,
        section,
        location,
        location_of_incident_street,
        location_of_incident_other,
        -- A checkbox is set when it holds anything but whitespace. nullif
        -- guards against an empty string counting as ticked.
        nullif(btrim(alcohol), '')        IS NOT NULL,
        nullif(btrim(domestic), '')       IS NOT NULL,
        nullif(btrim(narcotics_flag), '') IS NOT NULL,
        narcotics_type,
        nullif(btrim(mental_health), '')  IS NOT NULL,
        nullif(btrim(significant), '')    IS NOT NULL,
        loaded_at
    FROM (
        -- Latest version per record within this batch. Needed, not just
        -- tidy: a record modified twice between runs is in the batch twice,
        -- and ON CONFLICT cannot touch the same row twice in one statement.
        -- NULLS LAST, because a descending sort puts NULLs first by default.
        -- Rows without a key are excluded - they cannot be matched to
        -- anything - and counted in the notice below.
        SELECT DISTINCT ON (__pkeypolicepro_id) *
        FROM   stg.pp
        WHERE  loaded_at > wm AND loaded_at <= batch_to
          AND  __pkeypolicepro_id IS NOT NULL
        ORDER  BY __pkeypolicepro_id,
                  stg.try_ts(modification_date_timestamp) DESC NULLS LAST,
                  loaded_at DESC
    ) latest
    ON CONFLICT (pk_incident) DO UPDATE SET
        incident_no                 = EXCLUDED.incident_no,
        call_type                   = EXCLUDED.call_type,
        call_source                 = EXCLUDED.call_source,
        creation_date_timestamp     = EXCLUDED.creation_date_timestamp,
        modification_date_timestamp = EXCLUDED.modification_date_timestamp,
        crime_type                  = EXCLUDED.crime_type,
        date_occurred               = EXCLUDED.date_occurred,
        time_occurred               = EXCLUDED.time_occurred,
        date_reported               = EXCLUDED.date_reported,
        time_received               = EXCLUDED.time_received,
        time_dispatched             = EXCLUDED.time_dispatched,
        finalisation_status         = EXCLUDED.finalisation_status,
        incident_village            = EXCLUDED.incident_village,
        section                     = EXCLUDED.section,
        location                    = EXCLUDED.location,
        location_of_incident_street = EXCLUDED.location_of_incident_street,
        location_of_incident_other  = EXCLUDED.location_of_incident_other,
        flag_alcohol                = EXCLUDED.flag_alcohol,
        flag_domestic               = EXCLUDED.flag_domestic,
        flag_narcotics              = EXCLUDED.flag_narcotics,
        narcotics_type              = EXCLUDED.narcotics_type,
        flag_mental_health          = EXCLUDED.flag_mental_health,
        flag_significant            = EXCLUDED.flag_significant,
        loaded_at                   = EXCLUDED.loaded_at,
        transformed_at              = clock_timestamp()
    -- Never let an older version overwrite a newer one. Normal loads arrive
    -- in modification order, but a re-seed or a manual backfill need not.
    WHERE rep.fact_incident.modification_date_timestamp IS NULL
       OR EXCLUDED.modification_date_timestamp
              >= rep.fact_incident.modification_date_timestamp;

    GET DIAGNOSTICS n_written = ROW_COUNT;

    INSERT INTO elt.transform_watermark
           (target_table, source_table, last_loaded_at, source_as_at)
    VALUES ('rep.fact_incident', 'stg.pp', batch_to,
            coalesce(p_source_as_at,
                     (SELECT max(watermark_to) FROM elt.load_run
                      WHERE status = 'succeeded')))
    ON CONFLICT (target_table) DO UPDATE
    SET last_loaded_at = EXCLUDED.last_loaded_at,
        source_as_at   = EXCLUDED.source_as_at,
        updated_at     = clock_timestamp();

    RAISE NOTICE 'rep.fact_incident: % staged rows since %, % written, % without a key skipped',
        n_batch, wm, n_written, n_nokey;
END $$;

-- Only the orchestrator below may call it. Procedures are executable by
-- PUBLIC unless revoked.
REVOKE EXECUTE ON PROCEDURE rep.transform_fact_incident(timestamp) FROM PUBLIC;


-- ---------------------------------------------------------------------------
-- rep.fact_incident_charge
-- ---------------------------------------------------------------------------
-- One row per charge: the latest version of each PolicePro charge record.
-- fk_incident joins to rep.fact_incident. No foreign key is declared - a charge
-- can reach staging before the incident it belongs to, and a constraint would
-- fail the transform for a sequencing accident rather than a data fault. The
-- orphan check below the procedure is the way to see it.
CREATE TABLE IF NOT EXISTS rep.fact_incident_charge (
    pk_incident_charge           text PRIMARY KEY,   -- __pkeycharge_id
    arrest_no                    text,
    creation_date_timestamp      timestamp,
    created_by                   text,
    modification_date_timestamp  timestamp,
    fk_incident                  text,               -- _fkeypolicepro_id
    fk_law                       text,               -- _fkeynyslaw_id, dimension to follow
    fk_arrest                    text,               -- _fkeyarrest_id, dimension to follow
    code                         text,               -- candidate for a dimension
    class                        text,
    offense                      text,
    attempt                      boolean,
    judge                        text,
    disp_date                    date,
    disp_sentence                text,
    conviction                   boolean,
    counts                       numeric,
    loaded_at                    timestamp NOT NULL, -- when this version reached stg
    transformed_at               timestamp NOT NULL DEFAULT clock_timestamp()
);

-- For a table that already existed before transformed_at was added.
ALTER TABLE rep.fact_incident_charge
    ADD COLUMN IF NOT EXISTS transformed_at timestamp NOT NULL DEFAULT clock_timestamp();

-- Same shape as rep.transform_fact_incident: everything that reached stg.charges
-- since the last call, latest version of each record, upserted.
CREATE OR REPLACE PROCEDURE rep.transform_fact_incident_charge(p_source_as_at timestamp)
LANGUAGE plpgsql AS $$
DECLARE
    wm         timestamp;
    batch_to   timestamp;
    n_batch    bigint;
    n_nokey    bigint;
    n_written  bigint;
BEGIN
    -- CHARGES may not be in the pipeline yet. Skip rather than fail, so this
    -- file and the nightly run both work before the table is seeded.
    IF to_regclass('stg.charges') IS NULL THEN
        RAISE NOTICE 'rep.fact_incident_charge: stg.charges does not exist yet, skipped';
        RETURN;
    END IF;

    SELECT last_loaded_at INTO wm
    FROM   elt.transform_watermark WHERE target_table = 'rep.fact_incident_charge';
    wm := coalesce(wm, '-infinity'::timestamp);

    SELECT max(loaded_at) INTO batch_to FROM stg.charges WHERE loaded_at > wm;
    IF batch_to IS NULL THEN
        RAISE NOTICE 'rep.fact_incident_charge: nothing new in stg.charges since %', wm;
        RETURN;
    END IF;

    SELECT count(*), count(*) FILTER (WHERE __pkeycharge_id IS NULL)
    INTO   n_batch, n_nokey
    FROM   stg.charges WHERE loaded_at > wm AND loaded_at <= batch_to;

    INSERT INTO rep.fact_incident_charge (
        pk_incident_charge, arrest_no, creation_date_timestamp, created_by,
        modification_date_timestamp, fk_incident, fk_law, fk_arrest, code,
        class, offense, attempt, judge, disp_date, disp_sentence, conviction,
        counts, loaded_at)
    SELECT
        __pkeycharge_id,
        "arrest_#",
        stg.try_ts(creation_timestamp),
        created_by,
        stg.try_ts(modification_timestamp),
        _fkeypolicepro_id,
        _fkeynyslaw_id,
        _fkeyarrest_id,
        code,
        class,
        offense,
        -- nullif, so an empty string does not read as ticked. btrim('') is ''
        -- and therefore NOT NULL, which would make every record an attempt.
        nullif(btrim(attempt), '')    IS NOT NULL,
        judge,
        stg.try_date(disp_date),
        disp_sentence,
        nullif(btrim(conviction), '') IS NOT NULL,
        stg.try_numeric(counts),
        loaded_at
    FROM (
        SELECT DISTINCT ON (__pkeycharge_id) *
        FROM   stg.charges
        WHERE  loaded_at > wm AND loaded_at <= batch_to
          AND  __pkeycharge_id IS NOT NULL
        ORDER  BY __pkeycharge_id,
                  stg.try_ts(modification_timestamp) DESC NULLS LAST,
                  loaded_at DESC
    ) latest
    ON CONFLICT (pk_incident_charge) DO UPDATE SET
        arrest_no                   = EXCLUDED.arrest_no,
        creation_date_timestamp     = EXCLUDED.creation_date_timestamp,
        created_by                  = EXCLUDED.created_by,
        modification_date_timestamp = EXCLUDED.modification_date_timestamp,
        fk_incident                 = EXCLUDED.fk_incident,
        fk_law                      = EXCLUDED.fk_law,
        fk_arrest                   = EXCLUDED.fk_arrest,
        code                        = EXCLUDED.code,
        class                       = EXCLUDED.class,
        offense                     = EXCLUDED.offense,
        attempt                     = EXCLUDED.attempt,
        judge                       = EXCLUDED.judge,
        disp_date                   = EXCLUDED.disp_date,
        disp_sentence               = EXCLUDED.disp_sentence,
        conviction                  = EXCLUDED.conviction,
        counts                      = EXCLUDED.counts,
        loaded_at                   = EXCLUDED.loaded_at,
        transformed_at              = clock_timestamp()
    WHERE rep.fact_incident_charge.modification_date_timestamp IS NULL
       OR EXCLUDED.modification_date_timestamp
              >= rep.fact_incident_charge.modification_date_timestamp;

    GET DIAGNOSTICS n_written = ROW_COUNT;

    INSERT INTO elt.transform_watermark
           (target_table, source_table, last_loaded_at, source_as_at)
    VALUES ('rep.fact_incident_charge', 'stg.charges', batch_to,
            coalesce(p_source_as_at,
                     (SELECT max(watermark_to) FROM elt.load_run
                      WHERE status = 'succeeded')))
    ON CONFLICT (target_table) DO UPDATE
    SET last_loaded_at = EXCLUDED.last_loaded_at,
        source_as_at   = EXCLUDED.source_as_at,
        updated_at     = clock_timestamp();

    RAISE NOTICE 'rep.fact_incident_charge: % staged rows since %, % written, % without a key skipped',
        n_batch, wm, n_written, n_nokey;
END $$;

REVOKE EXECUTE ON PROCEDURE rep.transform_fact_incident_charge(timestamp) FROM PUBLIC;

-- Charges whose incident is not in rep. Expected briefly while CHARGES and PP
-- are seeded at different times; persistent rows are a source data question.
--
--   SELECT count(*) FROM rep.fact_incident_charge c
--   LEFT JOIN rep.fact_incident i ON i.pk_incident = c.fk_incident
--   WHERE  c.fk_incident IS NOT NULL AND i.pk_incident IS NULL;

-- ---------------------------------------------------------------------------
-- elt.run_transforms - the one entry point
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER: runs as pp_owner, so svc_py can bring rep up to date
-- without holding any privilege on rep. The pinned search_path matters - an
-- unpinned one on a SECURITY DEFINER routine lets the caller substitute their
-- own objects. pg_temp goes last for the same reason.
--
-- All targets run in the caller's single transaction: either every rep table
-- and its watermark moves forward, or none does.
--
-- p_source_as_at is the source-side cut-off the data is current to. The
-- extractor passes its run ceiling; called by hand it defaults to the newest
-- successful run's.
CREATE OR REPLACE PROCEDURE elt.run_transforms(p_source_as_at timestamp DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rep, stg, elt, pg_temp
AS $$
BEGIN
    CALL rep.transform_fact_incident(p_source_as_at);
    CALL rep.transform_fact_incident_charge(p_source_as_at);
    -- CALL rep.transform_<next table>(p_source_as_at);
END $$;

REVOKE EXECUTE ON PROCEDURE elt.run_transforms(timestamp) FROM PUBLIC;
GRANT  EXECUTE ON PROCEDURE elt.run_transforms(timestamp) TO svc_py;

RESET ROLE;
