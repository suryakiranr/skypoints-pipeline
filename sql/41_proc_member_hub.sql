-- Staging -> Member Hub: "latest record wins".
--
-- Latest = the highest record_order: the Member File's timestamp, then the
-- line number within the file. Comparing against the hub's current
-- record_order means a late-arriving OLDER file never overwrites a newer
-- record; its rows stay in staging as history.
--
-- One MERGE statement: atomic, and the only consumer of STG_MEMBER_STREAM.

CREATE OR REPLACE PROCEDURE SP_MERGE_MEMBER_HUB()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
  MERGE INTO MEMBER_HUB t
  USING (
    SELECT *
    FROM STG_MEMBER_STREAM
    QUALIFY ROW_NUMBER() OVER (PARTITION BY member_id ORDER BY record_order DESC) = 1
  ) s
  ON t.member_id = s.member_id
  WHEN MATCHED AND s.record_order > t.record_order THEN UPDATE SET
    member_name       = s.member_name,
    enrollment_date   = s.enrollment_date,
    last_flight_date  = s.last_flight_date,
    tier_code         = s.tier_code,
    agent_name        = s.agent_name,
    state             = s.state,
    country_raw       = s.country_raw,
    country_code      = s.country_code,
    post_code         = s.post_code,
    date_of_birth     = s.date_of_birth,
    is_active         = s.is_active,
    age               = s.age,
    is_stale_member   = s.is_stale_member,
    dq_warnings       = s.dq_warnings,
    business_date     = s.business_date,
    record_order      = s.record_order,
    source_batch_id   = s.batch_id,
    source_file_name  = s.file_name,
    source_row_number = s.file_row_number,
    updated_at        = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (
    member_id, member_name, enrollment_date, last_flight_date, tier_code, agent_name, state,
    country_raw, country_code, post_code, date_of_birth, is_active, age, is_stale_member, dq_warnings,
    business_date, record_order, source_batch_id, source_file_name, source_row_number,
    first_seen_at, updated_at
  ) VALUES (
    s.member_id, s.member_name, s.enrollment_date, s.last_flight_date, s.tier_code, s.agent_name, s.state,
    s.country_raw, s.country_code, s.post_code, s.date_of_birth, s.is_active, s.age, s.is_stale_member, s.dq_warnings,
    s.business_date, s.record_order, s.batch_id, s.file_name, s.file_row_number,
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
  );

  RETURN OBJECT_CONSTRUCT('rows_merged', SQLROWCOUNT);
END;
$$;
