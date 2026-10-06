-- Redemption Feed: landing -> REDEMPTION_EVENT -> REDEMPTION_CURRENT.
--
-- Each landed record is one member object; its "redemptions" array is
-- flattened to one row per Redemption. Same shape as the member load: register
-- files, validate, reject, enforce the Reject Threshold, then append the
-- accepted Redemption Events. One transaction.

CREATE OR REPLACE PROCEDURE SP_LOAD_REDEMPTION_BATCHES()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  this_run   VARCHAR DEFAULT UUID_STRING();
  threshold  FLOAT;
  summary    VARIANT;
BEGIN
  threshold := (SELECT TO_DOUBLE(config_value) FROM PIPELINE_CONFIG WHERE config_key = 'REDEMPTION_REJECT_THRESHOLD');

  BEGIN TRANSACTION;

  DELETE FROM WRK_REDEMPTION_RECORDS;
  INSERT INTO WRK_REDEMPTION_RECORDS (file_name, file_row_number, raw_record)
    SELECT REGEXP_REPLACE(REGEXP_SUBSTR(file_path, '[^/]+$'), '[.]gz$', ''),
           file_row_number,
           raw_record
    FROM LND_REDEMPTION_FEED_STREAM;

  INSERT INTO FILE_BATCH (run_id, feed_type, file_name, business_date, file_ts, status, status_reason)
    SELECT :this_run, 'REDEMPTION', file_name, TO_DATE(file_ts), file_ts,
           IFF(file_ts IS NULL, 'REJECTED', 'PENDING'),
           IFF(file_ts IS NULL, 'INVALID_FILE_NAME', NULL)
    FROM (
      SELECT file_name,
             DATEADD('millisecond', TO_NUMBER(hundredths) * 10,
                     TRY_TO_TIMESTAMP_NTZ(date_part || time_part, 'YYYYMMDDHH24MISS')) AS file_ts
      FROM (
        SELECT file_name,
               REGEXP_SUBSTR(file_name, '^SKYPOINTS_REDEMPTION_([0-9]{8})_([0-9]{6})([0-9]{2})[.]json$', 1, 1, 'e', 1) AS date_part,
               REGEXP_SUBSTR(file_name, '^SKYPOINTS_REDEMPTION_([0-9]{8})_([0-9]{6})([0-9]{2})[.]json$', 1, 1, 'e', 2) AS time_part,
               REGEXP_SUBSTR(file_name, '^SKYPOINTS_REDEMPTION_([0-9]{8})_([0-9]{6})([0-9]{2})[.]json$', 1, 1, 'e', 3) AS hundredths
        FROM (SELECT DISTINCT file_name FROM WRK_REDEMPTION_RECORDS)
      )
    ) n
    WHERE NOT EXISTS (SELECT 1 FROM FILE_BATCH b WHERE b.file_name = n.file_name);

  -- Flatten and classify. A member object whose "redemptions" is missing or
  -- not an array yields one row with redemption_index NULL and is rejected
  -- whole; an empty array is a member with nothing to report and yields none.
  DELETE FROM WRK_REDEMPTION_PARSED;
  INSERT INTO WRK_REDEMPTION_PARSED (
    batch_id, file_name, file_ts, file_row_number, redemption_index, event_order,
    feed_date, member_id, txn_id, txn_date, partner, miles_redeemed, status, raw_redemption,
    dq_errors, dq_warnings
  )
  SELECT
    batch_id, file_name, file_ts, file_row_number, redemption_index,
    TO_CHAR(feed_date, 'YYYYMMDD') || TO_CHAR(file_ts, 'YYYYMMDDHH24MISSFF3')
      || LPAD(file_row_number::VARCHAR, 12, '0') || LPAD(redemption_index::VARCHAR, 6, '0'),
    feed_date, member_id, txn_id, txn_date, partner,
    IFF(miles_valid, miles_number, NULL),
    status, raw_redemption,

    ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(member_id IS NULL,                               'MEMBER_ID_MISSING', NULL),
      IFF(LENGTH(member_id) > 18,                          'MEMBER_ID_TOO_LONG', NULL),
      IFF(feed_date_raw IS NULL,                           'FEED_DATE_MISSING', NULL),
      IFF(feed_date_raw IS NOT NULL AND feed_date IS NULL, 'FEED_DATE_INVALID', NULL),
      IFF(redemption_index IS NULL,                        'REDEMPTIONS_NOT_ARRAY', NULL),
      IFF(redemption_index IS NOT NULL AND txn_id IS NULL, 'TXN_ID_MISSING', NULL),
      IFF(LENGTH(txn_id) > 50,                             'TXN_ID_TOO_LONG', NULL),
      IFF(redemption_index IS NOT NULL AND txn_date IS NULL, 'TXN_DATE_INVALID', NULL),
      IFF(txn_date > feed_date,                            'TXN_DATE_AFTER_FEED_DATE', NULL),
      IFF(redemption_index IS NOT NULL AND NOT miles_valid, 'MILES_REDEEMED_INVALID', NULL),
      IFF(redemption_index IS NOT NULL AND (status IS NULL OR status NOT IN ('PENDING', 'COMPLETED', 'CANCELLED', 'REVERSED')),
                                                           'STATUS_INVALID', NULL),
      IFF(LENGTH(partner) > 100,                           'PARTNER_TOO_LONG', NULL)
    )),

    ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(redemption_index IS NOT NULL AND partner IS NULL, 'PARTNER_MISSING', NULL),
      IFF(feed_date <> business_date,                      'FEED_DATE_MISMATCH', NULL),
      IFF(rows_for_txn_in_file > 1,                        'DUPLICATE_TXN_IN_FEED', NULL)
    ))
  FROM (
    SELECT p.*,
           COALESCE(miles_number > 0 AND miles_number < 1e12 AND miles_number = FLOOR(miles_number), FALSE) AS miles_valid,
           IFF(txn_id IS NULL, 1, COUNT(*) OVER (PARTITION BY batch_id, txn_id)) AS rows_for_txn_in_file
    FROM (
      SELECT r.batch_id, r.file_name, r.file_ts, r.business_date, r.file_row_number,
             x.index AS redemption_index,
             x.value AS raw_redemption,
             NULLIF(TRIM(r.raw_record:member_id::STRING), '') AS member_id,
             NULLIF(TRIM(r.raw_record:feed_date::STRING), '') AS feed_date_raw,
             IFF(REGEXP_LIKE(feed_date_raw, '[0-9]{8}'), TRY_TO_DATE(feed_date_raw, 'YYYYMMDD'), NULL) AS feed_date,
             COALESCE(IS_ARRAY(r.raw_record:redemptions), FALSE) AS has_redemptions_array,
             NULLIF(TRIM(x.value:txn_id::STRING), '') AS txn_id,
             IFF(REGEXP_LIKE(x.value:txn_date::STRING, '[0-9]{8}'), TRY_TO_DATE(x.value:txn_date::STRING, 'YYYYMMDD'), NULL) AS txn_date,
             NULLIF(TRIM(x.value:partner::STRING), '') AS partner,
             -- Scale 4 so that 12000.5 is seen as fractional instead of rounded.
             TRY_TO_NUMBER(x.value:miles_redeemed::STRING, 38, 4) AS miles_number,
             UPPER(NULLIF(TRIM(x.value:status::STRING), '')) AS status
      FROM (
        SELECT fb.batch_id, fb.file_name, fb.file_ts, fb.business_date, w.file_row_number, w.raw_record
        FROM WRK_REDEMPTION_RECORDS w
        JOIN FILE_BATCH fb ON fb.file_name = w.file_name
        WHERE fb.run_id = :this_run AND fb.status = 'PENDING'
      ) r,
      LATERAL FLATTEN(
        INPUT => IFF(IS_ARRAY(r.raw_record:redemptions), r.raw_record:redemptions, ARRAY_CONSTRUCT()),
        OUTER => TRUE
      ) x
    ) p
    WHERE p.redemption_index IS NOT NULL OR NOT p.has_redemptions_array
  );

  INSERT INTO REDEMPTION_REJECTS (batch_id, file_name, file_row_number, redemption_index, member_id, txn_id, raw_redemption, reject_reasons)
    SELECT batch_id, file_name, file_row_number, redemption_index, member_id, txn_id, raw_redemption, dq_errors
    FROM WRK_REDEMPTION_PARSED
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
      FROM WRK_REDEMPTION_PARSED
      GROUP BY batch_id
    ) s
   WHERE b.batch_id = s.batch_id;

  INSERT INTO REDEMPTION_EVENT (
    batch_id, file_name, file_ts, file_row_number, redemption_index, event_order,
    feed_date, member_id, txn_id, txn_date, partner, miles_redeemed, status, dq_warnings
  )
    SELECT p.batch_id, p.file_name, p.file_ts, p.file_row_number, p.redemption_index, p.event_order,
           p.feed_date, p.member_id, p.txn_id, p.txn_date, p.partner, p.miles_redeemed, p.status, p.dq_warnings
    FROM WRK_REDEMPTION_PARSED p
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

-- Redemption Events -> REDEMPTION_CURRENT: latest event per txn_id wins, by
-- feed date then arrival order. A PENDING redemption that later arrives as
-- COMPLETED is updated in place; the history stays in REDEMPTION_EVENT.
CREATE OR REPLACE PROCEDURE SP_MERGE_REDEMPTIONS()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
  MERGE INTO REDEMPTION_CURRENT t
  USING (
    SELECT *
    FROM REDEMPTION_EVENT_STREAM
    QUALIFY ROW_NUMBER() OVER (PARTITION BY txn_id ORDER BY event_order DESC) = 1
  ) s
  ON t.txn_id = s.txn_id
  WHEN MATCHED AND s.event_order > t.event_order THEN UPDATE SET
    member_id        = s.member_id,
    txn_date         = s.txn_date,
    partner          = s.partner,
    miles_redeemed   = s.miles_redeemed,
    status           = s.status,
    feed_date        = s.feed_date,
    event_order      = s.event_order,
    source_batch_id  = s.batch_id,
    updated_at       = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (
    txn_id, member_id, txn_date, partner, miles_redeemed, status, feed_date, event_order,
    source_batch_id, first_seen_at, updated_at
  ) VALUES (
    s.txn_id, s.member_id, s.txn_date, s.partner, s.miles_redeemed, s.status, s.feed_date, s.event_order,
    s.batch_id, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
  );

  RETURN OBJECT_CONSTRUCT('rows_merged', SQLROWCOUNT);
END;
$$;
