-- Member File: landing -> staging, with validation.
--
-- One run handles every Member File landed since the previous run:
--   1. drain the landing stream into a work table
--   2. register each new file in FILE_BATCH, rejecting names outside the spec
--   3. validate each file's header against MEMBER_FILE_LAYOUT
--   4. parse detail records BY HEADER NAME, type them, derive Age/Stale,
--      and classify problems as errors (Reject) or warnings
--   5. write Rejects; fail any file over the Reject Threshold
--   6. stage the accepted records of every file that did not fail
-- All of it is one transaction: on any error nothing is written and the
-- landing stream is not consumed, so the run can simply be retried.

CREATE OR REPLACE PROCEDURE SP_LOAD_MEMBER_BATCHES()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  this_run    VARCHAR DEFAULT UUID_STRING();
  threshold   FLOAT;
  stale_days  NUMBER;
  summary     VARIANT;
BEGIN
  threshold  := (SELECT TO_DOUBLE(config_value) FROM PIPELINE_CONFIG WHERE config_key = 'MEMBER_REJECT_THRESHOLD');
  stale_days := (SELECT TO_NUMBER(config_value) FROM PIPELINE_CONFIG WHERE config_key = 'STALE_MEMBER_DAYS');

  BEGIN TRANSACTION;

  -- 1. Drain the stream. File names lose their stage prefix and .gz suffix;
  --    Windows line endings lose their trailing CR.
  DELETE FROM WRK_MEMBER_LINES;
  INSERT INTO WRK_MEMBER_LINES (file_name, file_row_number, raw_line)
    SELECT REGEXP_REPLACE(REGEXP_SUBSTR(file_path, '[^/]+$'), '[.]gz$', ''),
           file_row_number,
           RTRIM(raw_line, '\r')
    FROM LND_MEMBER_FILE_STREAM;

  -- 2. Register new files. A name already in FILE_BATCH has been processed
  --    before; its re-landed lines are ignored.
  INSERT INTO FILE_BATCH (run_id, feed_type, file_name, business_date, file_ts, status, status_reason)
    SELECT :this_run, 'MEMBER', file_name, TO_DATE(file_ts), file_ts,
           IFF(file_ts IS NULL, 'REJECTED', 'PENDING'),
           IFF(file_ts IS NULL, 'INVALID_FILE_NAME', NULL)
    FROM (
      SELECT file_name,
             DATEADD('millisecond', TO_NUMBER(hundredths) * 10,
                     TRY_TO_TIMESTAMP_NTZ(date_part || time_part, 'YYYYMMDDHH24MISS')) AS file_ts
      FROM (
        SELECT file_name,
               REGEXP_SUBSTR(file_name, '^SKYPOINTS_MEMBER_([0-9]{8})_([0-9]{6})([0-9]{2})[.]dat$', 1, 1, 'e', 1) AS date_part,
               REGEXP_SUBSTR(file_name, '^SKYPOINTS_MEMBER_([0-9]{8})_([0-9]{6})([0-9]{2})[.]dat$', 1, 1, 'e', 2) AS time_part,
               REGEXP_SUBSTR(file_name, '^SKYPOINTS_MEMBER_([0-9]{8})_([0-9]{6})([0-9]{2})[.]dat$', 1, 1, 'e', 3) AS hundredths
        FROM (SELECT DISTINCT file_name FROM WRK_MEMBER_LINES)
      )
    ) n
    WHERE NOT EXISTS (SELECT 1 FROM FILE_BATCH b WHERE b.file_name = n.file_name);

  -- 3. Header validation: exactly one H record, first in the file, carrying
  --    every required column, no unknown columns, no duplicates.
  UPDATE FILE_BATCH b
     SET header_columns = h.header_columns,
         status         = IFF(h.header_error IS NULL, b.status, 'REJECTED'),
         status_reason  = h.header_error
    FROM (
      SELECT s.batch_id,
             hl.header_columns,
             CASE
               WHEN s.header_count = 0 THEN 'HEADER_MISSING'
               WHEN s.header_count > 1 THEN 'HEADER_DUPLICATED'
               WHEN hl.file_row_number <> s.first_row THEN 'HEADER_NOT_FIRST_RECORD'
               WHEN ARRAY_SIZE(ARRAY_EXCEPT(lay.required_columns, hl.header_columns)) > 0
                 THEN 'HEADER_MISSING_COLUMNS: '
                      || ARRAY_TO_STRING(ARRAY_EXCEPT(lay.required_columns, hl.header_columns), ',')
               WHEN ARRAY_SIZE(ARRAY_EXCEPT(hl.header_columns, lay.allowed_columns)) > 0
                 THEN 'HEADER_UNKNOWN_COLUMNS: '
                      || ARRAY_TO_STRING(ARRAY_EXCEPT(hl.header_columns, lay.allowed_columns), ',')
               WHEN ARRAY_SIZE(ARRAY_DISTINCT(hl.header_columns)) <> ARRAY_SIZE(hl.header_columns)
                 THEN 'HEADER_DUPLICATE_COLUMNS'
             END AS header_error
      FROM (
        SELECT fb.batch_id,
               COUNT_IF(TRIM(SPLIT_PART(l.raw_line, '|', 2)) = 'H') AS header_count,
               MIN(l.file_row_number) AS first_row
        FROM WRK_MEMBER_LINES l
        JOIN FILE_BATCH fb ON fb.file_name = l.file_name
        WHERE fb.run_id = :this_run AND fb.status = 'PENDING'
        GROUP BY fb.batch_id
      ) s
      LEFT JOIN (
        SELECT fb.batch_id,
               l.file_row_number,
               ARRAY_AGG(TRIM(c.value::STRING)) WITHIN GROUP (ORDER BY c.index) AS header_columns
        FROM WRK_MEMBER_LINES l
        JOIN FILE_BATCH fb ON fb.file_name = l.file_name,
        LATERAL FLATTEN(INPUT => SPLIT(l.raw_line, '|')) c
        WHERE fb.run_id = :this_run AND fb.status = 'PENDING'
          AND TRIM(SPLIT_PART(l.raw_line, '|', 2)) = 'H'
          AND c.index >= 2
        GROUP BY fb.batch_id, l.file_row_number
        QUALIFY ROW_NUMBER() OVER (PARTITION BY fb.batch_id ORDER BY l.file_row_number) = 1
      ) hl ON hl.batch_id = s.batch_id
      CROSS JOIN (
        SELECT ARRAY_AGG(IFF(required_in_header, header_name, NULL)) AS required_columns,
               ARRAY_AGG(header_name) AS allowed_columns
        FROM MEMBER_FILE_LAYOUT
      ) lay
    ) h
   WHERE b.batch_id = h.batch_id;

  -- 4. Parse, type, derive and classify every detail record.
  DELETE FROM WRK_MEMBER_PARSED;
  INSERT INTO WRK_MEMBER_PARSED (
    batch_id, file_name, file_ts, business_date, file_row_number, record_order, raw_line,
    member_id, member_name, enrollment_date, last_flight_date, tier_code, agent_name, state,
    country_raw, country_code, post_code, date_of_birth, is_active, age, is_stale_member,
    dq_errors, dq_warnings
  )
  SELECT
    batch_id, file_name, file_ts, business_date, file_row_number,
    TO_CHAR(file_ts, 'YYYYMMDDHH24MISSFF3') || LPAD(file_row_number::VARCHAR, 12, '0'),
    raw_line,
    member_id, member_name, enrollment_date, last_flight_date, tier_code, agent_name, state,
    country_raw, country_code, post_code, date_of_birth, is_active, age, is_stale_member,

    ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(record_prefix <> '',                                'LEADING_DELIMITER_MISSING', NULL),
      IFF(record_type IS DISTINCT FROM 'D',                   'RECORD_TYPE_INVALID', NULL),
      IFF(field_count <> header_field_count,                  'FIELD_COUNT_MISMATCH', NULL),
      IFF(member_id IS NULL,                                  'MEMBER_ID_MISSING', NULL),
      IFF(member_name IS NULL,                                'MEMBER_NAME_MISSING', NULL),
      IFF(enrollment_date_raw IS NULL,                        'ENROLLMENT_DATE_MISSING', NULL),
      IFF(enrollment_date_raw IS NOT NULL AND enrollment_date IS NULL, 'ENROLLMENT_DATE_INVALID', NULL),
      IFF(country_raw IS NULL,                                'COUNTRY_MISSING', NULL),
      IFF(country_raw IS NOT NULL AND country_code IS NULL,   'COUNTRY_UNMAPPED', NULL),
      IFF(LENGTH(member_id)   > 18,                           'MEMBER_ID_TOO_LONG', NULL),
      IFF(LENGTH(member_name) > 255,                          'MEMBER_NAME_TOO_LONG', NULL),
      IFF(LENGTH(tier_code)   > 5,                            'TIER_CODE_TOO_LONG', NULL),
      IFF(LENGTH(agent_name)  > 255,                          'AGENT_NAME_TOO_LONG', NULL),
      IFF(LENGTH(state)       > 5,                            'STATE_TOO_LONG', NULL),
      IFF(LENGTH(country_raw) > 5,                            'COUNTRY_TOO_LONG', NULL),
      IFF(LENGTH(post_code)   > 5,                            'POST_CODE_TOO_LONG', NULL),
      IFF(LENGTH(is_active)   > 1,                            'IS_ACTIVE_TOO_LONG', NULL)
    )),

    ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(LENGTH(member_id) < 6,                              'MEMBER_ID_SHORT', NULL),
      IFF(NOT REGEXP_LIKE(member_id, '[0-9]+'),               'MEMBER_ID_NOT_NUMERIC', NULL),
      IFF(rows_for_member_in_file > 1,                        'DUPLICATE_MEMBER_IN_FILE', NULL),
      IFF(enrollment_date > business_date,                    'ENROLLMENT_DATE_IN_FUTURE', NULL),
      IFF(last_flight_date_raw IS NOT NULL AND last_flight_date IS NULL, 'LAST_FLIGHT_DATE_INVALID', NULL),
      IFF(last_flight_date > business_date,                   'LAST_FLIGHT_DATE_IN_FUTURE', NULL),
      IFF(last_flight_date < enrollment_date,                 'LAST_FLIGHT_BEFORE_ENROLLMENT', NULL),
      IFF(dob_raw IS NOT NULL AND date_of_birth IS NULL,      'DOB_INVALID', NULL),
      IFF(date_of_birth > business_date,                      'DOB_IN_FUTURE', NULL),
      IFF(date_of_birth > enrollment_date,                    'DOB_AFTER_ENROLLMENT', NULL),
      IFF(age > 120,                                          'AGE_OUT_OF_RANGE', NULL),
      IFF(tier_code IS NOT NULL AND NOT tier_known,           'TIER_CODE_UNKNOWN', NULL),
      IFF(is_active IS NOT NULL AND is_active NOT IN ('A', 'I'), 'IS_ACTIVE_INVALID', NULL),
      IFF(post_code IS NOT NULL AND NOT REGEXP_LIKE(post_code, '[0-9]+'), 'POST_CODE_INVALID', NULL)
    ))
  FROM (
    -- Derivations: Age in whole years and the stale flag, both as of the
    -- Business Date (ADR 0003).
    SELECT t.*,
           IFF(date_of_birth IS NULL OR date_of_birth > business_date, NULL,
               DATEDIFF('year', date_of_birth, business_date)
                 - IFF(DATEADD('year', DATEDIFF('year', date_of_birth, business_date), date_of_birth) > business_date, 1, 0)
           ) AS age,
           IFF(last_flight_date IS NULL, NULL,
               DATEDIFF('day', last_flight_date, business_date) > :stale_days) AS is_stale_member
    FROM (
      -- Typing. Dates must be exactly 8 digits before parsing, so a value
      -- that lost its leading zero ("3051985") is caught, not misread.
      SELECT f.*,
             IFF(REGEXP_LIKE(enrollment_date_raw, '[0-9]{8}'), TRY_TO_DATE(enrollment_date_raw, 'YYYYMMDD'), NULL) AS enrollment_date,
             IFF(REGEXP_LIKE(last_flight_date_raw, '[0-9]{8}'), TRY_TO_DATE(last_flight_date_raw, 'YYYYMMDD'), NULL) AS last_flight_date,
             IFF(REGEXP_LIKE(dob_raw, '[0-9]{8}'), TRY_TO_DATE(dob_raw, 'MMDDYYYY'), NULL) AS date_of_birth,
             ca.country_code,
             tr.tier_code IS NOT NULL AS tier_known,
             IFF(f.member_id IS NULL, 1,
                 COUNT(*) OVER (PARTITION BY f.batch_id, f.member_id)) AS rows_for_member_in_file
      FROM (
        -- Fields located by header name, never by position.
        SELECT fb.batch_id, fb.file_name, fb.file_ts, fb.business_date,
               l.file_row_number, l.raw_line,
               ARRAY_SIZE(fb.header_columns) AS header_field_count,
               SPLIT(l.raw_line, '|') AS parts,
               ARRAY_SLICE(parts, 2, ARRAY_SIZE(parts)) AS fields,
               ARRAY_SIZE(fields) AS field_count,
               GET(parts, 0)::STRING AS record_prefix,
               TRIM(GET(parts, 1)::STRING) AS record_type,
               NULLIF(TRIM(GET(fields, ARRAY_POSITION('Member_Name'::VARIANT,      fb.header_columns))::STRING), '') AS member_name,
               NULLIF(TRIM(GET(fields, ARRAY_POSITION('Member_Id'::VARIANT,        fb.header_columns))::STRING), '') AS member_id,
               NULLIF(TRIM(GET(fields, ARRAY_POSITION('Enrollment_Date'::VARIANT,  fb.header_columns))::STRING), '') AS enrollment_date_raw,
               NULLIF(TRIM(GET(fields, ARRAY_POSITION('Last_Flight_Date'::VARIANT, fb.header_columns))::STRING), '') AS last_flight_date_raw,
               NULLIF(TRIM(GET(fields, ARRAY_POSITION('Tier_Code'::VARIANT,        fb.header_columns))::STRING), '') AS tier_code,
               NULLIF(TRIM(GET(fields, ARRAY_POSITION('Agent_Name'::VARIANT,       fb.header_columns))::STRING), '') AS agent_name,
               NULLIF(TRIM(GET(fields, ARRAY_POSITION('State'::VARIANT,            fb.header_columns))::STRING), '') AS state,
               NULLIF(TRIM(GET(fields, ARRAY_POSITION('Country'::VARIANT,          fb.header_columns))::STRING), '') AS country_raw,
               NULLIF(TRIM(GET(fields, ARRAY_POSITION('Post_Code'::VARIANT,        fb.header_columns))::STRING), '') AS post_code,
               NULLIF(TRIM(GET(fields, ARRAY_POSITION('DOB'::VARIANT,              fb.header_columns))::STRING), '') AS dob_raw,
               NULLIF(TRIM(GET(fields, ARRAY_POSITION('Is_Active'::VARIANT,        fb.header_columns))::STRING), '') AS is_active
        FROM WRK_MEMBER_LINES l
        JOIN FILE_BATCH fb ON fb.file_name = l.file_name
        WHERE fb.run_id = :this_run AND fb.status = 'PENDING'
          AND TRIM(SPLIT_PART(l.raw_line, '|', 2)) <> 'H'
      ) f
      LEFT JOIN COUNTRY_ALIAS ca ON ca.alias = UPPER(f.country_raw)
      LEFT JOIN TIER_REF tr ON tr.tier_code = f.tier_code
    ) t
  );

  -- 5. Rejects are recorded even for files that then fail, for diagnosis.
  INSERT INTO MEMBER_REJECTS (batch_id, file_name, file_row_number, member_id, raw_line, reject_reasons, dq_warnings)
    SELECT batch_id, file_name, file_row_number, member_id, raw_line, dq_errors, dq_warnings
    FROM WRK_MEMBER_PARSED
    WHERE ARRAY_SIZE(dq_errors) > 0;

  UPDATE FILE_BATCH b
     SET total_records    = s.total_records,
         rejected_records = s.rejected_records,
         warning_records  = s.warning_records,
         reject_rate      = s.reject_rate,
         status           = IFF(s.reject_rate > :threshold, 'FAILED', b.status),
         status_reason    = IFF(s.reject_rate > :threshold, 'REJECT_THRESHOLD_EXCEEDED', b.status_reason)
    FROM (
      SELECT batch_id,
             COUNT(*) AS total_records,
             COUNT_IF(ARRAY_SIZE(dq_errors) > 0) AS rejected_records,
             COUNT_IF(ARRAY_SIZE(dq_errors) = 0 AND ARRAY_SIZE(dq_warnings) > 0) AS warning_records,
             COUNT_IF(ARRAY_SIZE(dq_errors) > 0) / COUNT(*) AS reject_rate
      FROM WRK_MEMBER_PARSED
      GROUP BY batch_id
    ) s
   WHERE b.batch_id = s.batch_id;

  -- 6. Stage accepted records of files still in play.
  INSERT INTO STG_MEMBER (
    batch_id, file_name, file_ts, business_date, file_row_number, record_order,
    member_id, member_name, enrollment_date, last_flight_date, tier_code, agent_name, state,
    country_raw, country_code, post_code, date_of_birth, is_active, age, is_stale_member, dq_warnings
  )
    SELECT p.batch_id, p.file_name, p.file_ts, p.business_date, p.file_row_number, p.record_order,
           p.member_id, p.member_name, p.enrollment_date, p.last_flight_date, p.tier_code, p.agent_name, p.state,
           p.country_raw, p.country_code, p.post_code, p.date_of_birth, p.is_active, p.age, p.is_stale_member,
           p.dq_warnings
    FROM WRK_MEMBER_PARSED p
    JOIN FILE_BATCH b ON b.batch_id = p.batch_id
    WHERE b.status = 'PENDING'
      AND ARRAY_SIZE(p.dq_errors) = 0;

  UPDATE FILE_BATCH
     SET status           = IFF(status = 'PENDING', 'LOADED', status),
         total_records    = IFF(status = 'PENDING', COALESCE(total_records, 0), total_records),
         rejected_records = IFF(status = 'PENDING', COALESCE(rejected_records, 0), rejected_records),
         warning_records  = IFF(status = 'PENDING', COALESCE(warning_records, 0), warning_records),
         reject_rate      = IFF(status = 'PENDING', COALESCE(reject_rate, 0), reject_rate),
         loaded_records   = IFF(status = 'PENDING', COALESCE(total_records, 0) - COALESCE(rejected_records, 0), 0),
         completed_at     = CURRENT_TIMESTAMP()
   WHERE run_id = :this_run;

  COMMIT;

  summary := (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
             'file_name', file_name, 'status', status, 'reason', status_reason,
             'total', total_records, 'loaded', loaded_records,
             'rejected', rejected_records, 'warned', warning_records
           )) WITHIN GROUP (ORDER BY file_ts, file_name)
    FROM FILE_BATCH
    WHERE run_id = :this_run
  );
  RETURN summary;

EXCEPTION
  WHEN OTHER THEN
    ROLLBACK;
    RAISE;
END;
$$;
