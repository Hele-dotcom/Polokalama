
-- Column profiling script for use in discovery.
-- Run a select * from src and step through each.

SELECT j.key AS column_name,
       count(*) FILTER (WHERE j.value IS NOT NULL AND j.value <> '') AS populated,
       round(100.0 * count(*) FILTER (WHERE j.value IS NOT NULL AND j.value <> '')
             / count(*), 1) AS pct_filled,
       count(DISTINCT j.value) FILTER (WHERE j.value IS NOT NULL AND j.value <> '') AS distinct_values
FROM   dsc.pp t,
       LATERAL jsonb_each_text(to_jsonb(t)) AS j(key, value)
GROUP  BY j.key
ORDER  BY populated, j.key;

WITH profile AS (
  SELECT j.key AS column_name,
         count(*) FILTER (WHERE j.value IS NOT NULL AND j.value <> '') AS populated
  FROM   dsc.pp t, LATERAL jsonb_each_text(to_jsonb(t)) AS j(key, value)
  GROUP  BY j.key
)
SELECT string_agg('"' || column_name || '"', ', ' ORDER BY column_name)
FROM   profile WHERE populated > 0;


SELECT 'CREATE TABLE stg.' || lower('PP') || ' (' || E'\n' ||
       string_agg('    "' || column_name || '" text', ',' || E'\n' ORDER BY column_name) ||
       ',' || E'\n    loaded_at timestamp NOT NULL DEFAULT clock_timestamp()' || E'\n);'
FROM   dsc.column_profile
WHERE  source_table = 'PP'
  AND  populated > 0
  AND  profiled_at = (SELECT max(profiled_at) FROM dsc.column_profile
                      WHERE source_table = 'PP');