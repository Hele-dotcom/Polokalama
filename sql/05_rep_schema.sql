-- ---------------------------------------------------------------------------
-- 05  rep - reporting
-- ---------------------------------------------------------------------------
-- The typed dimensional model Power BI consumes. Not yet built.
--
-- Two rules established during discovery that apply when it is:
--
--   Numbers from FileMaker are float-based, so numeric is the target type,
--   not integer. Rounding a float into an integer column is how quiet
--   arithmetic errors start.
--
--   Time values may exceed 24 hours. Where those prove to be durations the
--   target type is interval, not time. Where they prove to be mis-keyed clock
--   times they are data quality exceptions. The two are indistinguishable by
--   type and must be told apart by looking at the values.
--
-- Which columns warrant which type is settled by counting how many values in
-- each column survive each guarded cast, rather than inferred from the field
-- names: a column where every value casts cleanly is that type; one where a
-- handful fail identifies the records to investigate.
--
--   SELECT count(*) FILTER (WHERE stg.try_ts(col) IS NOT NULL) AS as_timestamp,
--          count(*) FILTER (WHERE stg.try_numeric(col) IS NOT NULL) AS as_numeric,
--          count(*) AS total
--   FROM   stg.pp;
--
-- Access model when this is populated: reporting consumers are granted SELECT
-- on rep and nothing at all on stg, which holds person-level policing data in
-- its raw form.
-- ---------------------------------------------------------------------------


-- Everything below is created as pp_owner, so that ownership is consistent and
-- ALTER DEFAULT PRIVILEGES below applies to it. Default privileges attach to a
-- granting role, not to a schema: declared while running as someone else, they
-- silently do not cover tables pp_owner creates - which shows up months later
-- as a new table with no grants on it.
SET ROLE pp_owner;

CREATE SCHEMA IF NOT EXISTS rep;

-- svc_py is deliberately granted nothing here. When the transformation exists,
-- make it SECURITY DEFINER owned by pp_owner with an explicit search_path, and
-- grant EXECUTE to svc_py - so the loader can invoke one controlled operation
-- without holding any privilege on rep itself. An unpinned search_path on a
-- SECURITY DEFINER function is a known escalation route.
--
--   CREATE PROCEDURE elt.run_transforms() ... SECURITY DEFINER SET search_path = rep, stg, pg_temp;
--   GRANT EXECUTE ON PROCEDURE elt.run_transforms() TO svc_py;

RESET ROLE;
