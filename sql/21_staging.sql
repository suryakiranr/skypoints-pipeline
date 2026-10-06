-- Staging: every accepted Member Record, typed, append-only. Holds the full
-- history of each Member, including the derived Age and Stale_Member flag as
-- of the record's Business Date (ADR 0003).
--
-- Column sizes follow the source spec. Two deliberate departures:
--   * Post Code is text, not INT: an INT drops leading zeros. The sample's
--     staged DOB ("3051985" for "03051985") shows exactly that defect.
--   * Every source column is VARCHAR. The spec's CHAR and VARCHAR behave
--     identically in Snowflake.

CREATE TABLE IF NOT EXISTS STG_MEMBER (
  batch_id          NUMBER        NOT NULL,
  file_name         VARCHAR(500)  NOT NULL,
  file_ts           TIMESTAMP_NTZ NOT NULL,
  business_date     DATE          NOT NULL,
  file_row_number   NUMBER        NOT NULL,
  record_order      VARCHAR(40)   NOT NULL,  -- sortable "latest record wins" key: file_ts + row

  member_id         VARCHAR(18)   NOT NULL,
  member_name       VARCHAR(255)  NOT NULL,
  enrollment_date   DATE          NOT NULL,
  last_flight_date  DATE,
  tier_code         VARCHAR(5),
  agent_name        VARCHAR(255),
  state             VARCHAR(5),
  country_raw       VARCHAR(5)    NOT NULL,  -- as sent, e.g. PHIL
  country_code      VARCHAR(3)    NOT NULL,  -- ISO alpha-3, e.g. PHL
  post_code         VARCHAR(5),
  date_of_birth     DATE,
  is_active         VARCHAR(1),

  age               NUMBER(3),               -- whole years at business_date
  is_stale_member   BOOLEAN,                 -- last_flight_date > 90 days before business_date
  dq_warnings       ARRAY         NOT NULL,

  staged_at         TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (business_date);

-- Records that failed an error-severity check, with the raw line for replay.
CREATE TABLE IF NOT EXISTS MEMBER_REJECTS (
  batch_id         NUMBER        NOT NULL,
  file_name        VARCHAR(500)  NOT NULL,
  file_row_number  NUMBER        NOT NULL,
  member_id        VARCHAR,
  raw_line         VARCHAR       NOT NULL,
  reject_reasons   ARRAY         NOT NULL,
  dq_warnings      ARRAY         NOT NULL,
  rejected_at      TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);
