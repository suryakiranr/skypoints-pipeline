-- Post-load data quality checks: invariants that must hold after every run.
-- Record-level validation (mandatory fields, formats, lengths, reference
-- lookups) happens during load; these checks catch defects in the pipeline
-- itself, and in the data across files.
--
-- Severity: ERROR = an invariant is broken; WARN = needs ops attention;
-- INFO = expected, but worth watching.

CREATE OR REPLACE VIEW V_DQ_INVARIANTS AS
-- Key-column uniqueness. Snowflake does not enforce PRIMARY KEY.
SELECT 'HUB_DUPLICATE_MEMBER_ID' AS check_name, 'ERROR' AS severity, COUNT(*) AS failures
FROM (SELECT member_id FROM MEMBER_HUB GROUP BY member_id HAVING COUNT(*) > 1)
UNION ALL
SELECT 'REDEMPTION_CURRENT_DUPLICATE_TXN_ID', 'ERROR', COUNT(*)
FROM (SELECT txn_id FROM REDEMPTION_CURRENT GROUP BY txn_id HAVING COUNT(*) > 1)
UNION ALL
-- Latest record wins: the hub must hold each Member's highest-ordered staged record.
SELECT 'HUB_NOT_LATEST_RECORD', 'ERROR', COUNT(*)
FROM MEMBER_HUB h
JOIN (SELECT member_id, MAX(record_order) AS latest FROM STG_MEMBER GROUP BY member_id) s
  ON s.member_id = h.member_id
WHERE h.record_order <> s.latest
UNION ALL
SELECT 'STAGED_MEMBER_NOT_IN_HUB', 'ERROR', COUNT(DISTINCT s.member_id)
FROM STG_MEMBER s
LEFT JOIN MEMBER_HUB h ON h.member_id = s.member_id
WHERE h.member_id IS NULL
UNION ALL
-- Reconciliation: every record of a loaded file is either loaded or rejected,
-- and the loaded count matches what actually reached staging / events.
SELECT 'BATCH_COUNTS_DO_NOT_RECONCILE', 'ERROR', COUNT(*)
FROM FILE_BATCH
WHERE status = 'LOADED' AND total_records <> loaded_records + rejected_records
UNION ALL
SELECT 'MEMBER_BATCH_STAGED_ROWS_MISMATCH', 'ERROR', COUNT(*)
FROM FILE_BATCH b
LEFT JOIN (SELECT batch_id, COUNT(*) AS staged FROM STG_MEMBER GROUP BY batch_id) s ON s.batch_id = b.batch_id
WHERE b.feed_type = 'MEMBER' AND b.status = 'LOADED' AND b.loaded_records <> COALESCE(s.staged, 0)
UNION ALL
SELECT 'REDEMPTION_BATCH_EVENT_ROWS_MISMATCH', 'ERROR', COUNT(*)
FROM FILE_BATCH b
LEFT JOIN (SELECT batch_id, COUNT(*) AS events FROM REDEMPTION_EVENT GROUP BY batch_id) e ON e.batch_id = b.batch_id
WHERE b.feed_type = 'REDEMPTION' AND b.status = 'LOADED' AND b.loaded_records <> COALESCE(e.events, 0)
UNION ALL
-- Reference integrity.
SELECT 'HUB_COUNTRY_NOT_IN_REFERENCE', 'ERROR', COUNT(*)
FROM MEMBER_HUB h
LEFT JOIN COUNTRY_REF r ON r.country_code = h.country_code
WHERE r.country_code IS NULL
UNION ALL
SELECT 'COUNTRY_ALIAS_WITHOUT_COUNTRY', 'ERROR', COUNT(*)
FROM COUNTRY_ALIAS a
LEFT JOIN COUNTRY_REF r ON r.country_code = a.country_code
WHERE r.country_code IS NULL
UNION ALL
-- Derived columns agree with their definition.
SELECT 'HUB_STALE_FLAG_INCONSISTENT', 'ERROR', COUNT(*)
FROM MEMBER_HUB
WHERE is_stale_member IS DISTINCT FROM IFF(
        last_flight_date IS NULL, NULL,
        DATEDIFF('day', last_flight_date, business_date)
          > (SELECT TO_NUMBER(config_value) FROM PIPELINE_CONFIG WHERE config_key = 'STALE_MEMBER_DAYS'))
UNION ALL
SELECT 'FILES_NOT_LOADED', 'WARN', COUNT(*)
FROM FILE_BATCH
WHERE status IN ('FAILED', 'REJECTED')
UNION ALL
SELECT 'ORPHAN_REDEMPTIONS', 'INFO', COUNT(*)
FROM REDEMPTION_CURRENT rc
LEFT JOIN MEMBER_HUB h ON h.member_id = rc.member_id
WHERE h.member_id IS NULL;

-- All checks, including the per-Country-Table ones generated from COUNTRY_REF.
CREATE OR REPLACE PROCEDURE SP_RUN_DQ_CHECKS()
RETURNS TABLE (check_name VARCHAR, severity VARCHAR, failures NUMBER)
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  countries CURSOR FOR SELECT country_code, target_table FROM COUNTRY_REF ORDER BY country_code;
  -- The first branch names the columns of the whole UNION.
  stmt VARCHAR DEFAULT 'SELECT check_name, severity, failures FROM V_DQ_INVARIANTS';
  all_members VARCHAR DEFAULT '';
  results RESULTSET;
BEGIN
  -- Also validates every table name before it is spliced in below.
  CALL SP_ENSURE_COUNTRY_TABLES();

  FOR c IN countries DO
    stmt := stmt
      || ' UNION ALL SELECT ''COUNTRY_TABLE_WRONG_COUNTRY:' || c.target_table || ''', ''ERROR'', COUNT(*) FROM '
      || c.target_table || ' WHERE country_code <> ''' || c.country_code || ''''
      -- The Country Table must mirror the hub's rows for that country exactly.
      || ' UNION ALL SELECT ''COUNTRY_TABLE_OUT_OF_SYNC:' || c.target_table || ''', ''ERROR'', COUNT(*) FROM ('
      || '(SELECT member_id, record_order FROM ' || c.target_table
      || ' EXCEPT SELECT member_id, record_order FROM MEMBER_HUB WHERE country_code = ''' || c.country_code || ''')'
      || ' UNION ALL '
      || '(SELECT member_id, record_order FROM MEMBER_HUB WHERE country_code = ''' || c.country_code || ''''
      || ' EXCEPT SELECT member_id, record_order FROM ' || c.target_table || '))';
    all_members := all_members
      || IFF(all_members = '', '', ' UNION ALL ')
      || 'SELECT member_id FROM ' || c.target_table;
  END FOR;

  IF (all_members <> '') THEN
    stmt := stmt
      || ' UNION ALL SELECT ''MEMBER_IN_MULTIPLE_COUNTRY_TABLES'', ''ERROR'', COUNT(*) FROM ('
      || 'SELECT member_id FROM (' || all_members || ') GROUP BY member_id HAVING COUNT(*) > 1)';
  END IF;

  stmt := 'SELECT * FROM (' || stmt || ') ORDER BY failures > 0 DESC, severity, check_name';

  results := (EXECUTE IMMEDIATE :stmt);
  RETURN TABLE(results);
END;
$$;
