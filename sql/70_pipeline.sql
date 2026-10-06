-- Orchestration: stage -> landing -> staging -> hub -> Country Tables, and the
-- redemption flow, as one callable unit plus a daily Task.

-- Copies every not-yet-loaded file from the stage into landing. COPY keeps
-- per-file load metadata, so a file already loaded is skipped (64-day window;
-- beyond that, FILE_BATCH's unique file_name still prevents reprocessing).
CREATE OR REPLACE PROCEDURE SP_INGEST_FILES()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  member_lines NUMBER;
  redemption_lines NUMBER;
BEGIN
  COPY INTO LND_MEMBER_FILE (file_path, file_row_number, raw_line)
    FROM (SELECT METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, $1 FROM @STG_INBOUND/member/)
    FILE_FORMAT = (FORMAT_NAME = 'FF_TEXT_LINE');
  member_lines := SQLROWCOUNT;

  COPY INTO LND_REDEMPTION_FEED (file_path, file_row_number, raw_line)
    FROM (SELECT METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, $1 FROM @STG_INBOUND/redemption/)
    FILE_FORMAT = (FORMAT_NAME = 'FF_TEXT_LINE');
  redemption_lines := SQLROWCOUNT;

  RETURN OBJECT_CONSTRUCT('member_lines_landed', member_lines, 'redemption_lines_landed', redemption_lines);
END;
$$;

-- The whole daily run. Returns a summary of every step.
-- fail_on_dq_error: raise when an ERROR-severity check fails, so a scheduled
-- run shows up as FAILED in task history and alerting; interactive callers
-- pass FALSE and read the summary instead.
CREATE OR REPLACE PROCEDURE SP_RUN_PIPELINE(fail_on_dq_error BOOLEAN)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  dq_failed EXCEPTION (-20002, 'SkyPoints pipeline: ERROR-severity data quality checks failed; see SP_RUN_DQ_CHECKS()');
  ingest VARIANT;
  member_files VARIANT;
  hub VARIANT;
  countries VARIANT;
  redemption_files VARIANT;
  redemptions VARIANT;
  dq_failures VARIANT;
  dq_error_count NUMBER;
BEGIN
  CALL SP_INGEST_FILES();
  ingest := (SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));

  CALL SP_LOAD_MEMBER_BATCHES();
  member_files := (SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));

  CALL SP_MERGE_MEMBER_HUB();
  hub := (SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));

  CALL SP_REFRESH_COUNTRY_TABLES();
  countries := (SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));

  CALL SP_LOAD_REDEMPTION_BATCHES();
  redemption_files := (SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));

  CALL SP_MERGE_REDEMPTIONS();
  redemptions := (SELECT $1 FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));

  CALL SP_RUN_DQ_CHECKS();
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT('check', check_name, 'severity', severity, 'failures', failures)),
         COUNT_IF(severity = 'ERROR')
    INTO :dq_failures, :dq_error_count
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
   WHERE failures > 0;

  IF (fail_on_dq_error AND dq_error_count > 0) THEN
    RAISE dq_failed;
  END IF;

  RETURN OBJECT_CONSTRUCT(
    'ingest', ingest,
    'member_files', member_files,
    'member_hub', hub,
    'country_tables', countries,
    'redemption_files', redemption_files,
    'redemptions', redemptions,
    'dq_failures', dq_failures
  );
END;
$$;

-- Daily schedule. Created suspended: run `ALTER TASK TASK_SKYPOINTS_DAILY RESUME`
-- once the source system is delivering. In production, Snowpipe auto-ingest
-- from cloud storage would replace the COPY step (see README).
CREATE OR REPLACE TASK TASK_SKYPOINTS_DAILY
  WAREHOUSE = {{ warehouse }}
  SCHEDULE = 'USING CRON 0 6 * * * UTC'
  COMMENT = 'SkyPoints daily member and redemption load'
AS
  CALL SP_RUN_PIPELINE(TRUE);
