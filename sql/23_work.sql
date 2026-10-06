-- Work tables: per-run scratch space, emptied at the start of each step and
-- written inside the step's transaction. Transient, so they skip Fail-safe.

CREATE TRANSIENT TABLE IF NOT EXISTS WRK_MEMBER_LINES (
  file_name        VARCHAR(500) NOT NULL,
  file_row_number  NUMBER       NOT NULL,
  raw_line         VARCHAR      NOT NULL
);

CREATE TRANSIENT TABLE IF NOT EXISTS WRK_MEMBER_PARSED (
  batch_id          NUMBER,
  file_name         VARCHAR(500),
  file_ts           TIMESTAMP_NTZ,
  business_date     DATE,
  file_row_number   NUMBER,
  record_order      VARCHAR(40),
  raw_line          VARCHAR,
  member_id         VARCHAR,
  member_name       VARCHAR,
  enrollment_date   DATE,
  last_flight_date  DATE,
  tier_code         VARCHAR,
  agent_name        VARCHAR,
  state             VARCHAR,
  country_raw       VARCHAR,
  country_code      VARCHAR(3),
  post_code         VARCHAR,
  date_of_birth     DATE,
  is_active         VARCHAR,
  age               NUMBER(3),
  is_stale_member   BOOLEAN,
  dq_errors         ARRAY,
  dq_warnings       ARRAY
);

-- Members touched by the latest hub MERGE, with the country of each row image
-- (old and new), so only the affected Country Tables are rewritten.
CREATE TRANSIENT TABLE IF NOT EXISTS WRK_HUB_CHANGES (
  member_id     VARCHAR(18) NOT NULL,
  country_code  VARCHAR(3)  NOT NULL
);

CREATE TRANSIENT TABLE IF NOT EXISTS WRK_REDEMPTION_RECORDS (
  file_name        VARCHAR(500) NOT NULL,
  file_row_number  NUMBER       NOT NULL,
  raw_line         VARCHAR      NOT NULL,
  raw_record       VARIANT                 -- NULL when the line is not valid JSON
);

CREATE TRANSIENT TABLE IF NOT EXISTS WRK_REDEMPTION_PARSED (
  batch_id          NUMBER,
  file_name         VARCHAR(500),
  file_ts           TIMESTAMP_NTZ,
  file_row_number   NUMBER,
  redemption_index  NUMBER,
  event_order       VARCHAR(60),
  feed_date         DATE,
  member_id         VARCHAR,
  txn_id            VARCHAR,
  txn_date          DATE,
  partner           VARCHAR,
  miles_redeemed    NUMBER(12, 0),
  status            VARCHAR,
  raw_redemption    VARIANT,
  dq_errors         ARRAY,
  dq_warnings       ARRAY
);
