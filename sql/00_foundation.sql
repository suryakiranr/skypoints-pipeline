-- Foundation: file formats, the inbound stage, and pipeline control tables.
--
-- Every script creates objects in the session's current database/schema; the
-- deployer (skypoints.deploy) selects it. That is what lets integration tests
-- deploy the whole pipeline into a throwaway schema.

-- Member File: each physical line lands whole, as text. Splitting on '|' and
-- matching columns by header name happens in SQL, so a layout change surfaces
-- as a validation failure instead of silently shifted columns.
CREATE OR REPLACE FILE FORMAT FF_MEMBER_LINE
  TYPE = CSV
  FIELD_DELIMITER = NONE
  RECORD_DELIMITER = '\n'
  SKIP_HEADER = 0
  SKIP_BLANK_LINES = TRUE
  FIELD_OPTIONALLY_ENCLOSED_BY = NONE
  ESCAPE = NONE
  ESCAPE_UNENCLOSED_FIELD = NONE
  TRIM_SPACE = FALSE
  EMPTY_FIELD_AS_NULL = FALSE
  ENCODING = 'UTF8'
  COMPRESSION = AUTO;

-- Redemption Feed: newline-delimited JSON, one member object per line. A
-- top-level JSON array is also accepted (STRIP_OUTER_ARRAY).
CREATE OR REPLACE FILE FORMAT FF_REDEMPTION_JSON
  TYPE = JSON
  STRIP_OUTER_ARRAY = TRUE
  COMPRESSION = AUTO;

-- Files arrive under member/ and redemption/ prefixes.
CREATE STAGE IF NOT EXISTS STG_INBOUND
  COMMENT = 'Inbound SkyPoints feeds: member/ and redemption/ prefixes';

CREATE SEQUENCE IF NOT EXISTS SEQ_BATCH_ID;

-- Operational knobs that must be tunable without a deploy.
CREATE TABLE IF NOT EXISTS PIPELINE_CONFIG (
  config_key    VARCHAR(100)  NOT NULL PRIMARY KEY,
  config_value  VARCHAR(1000) NOT NULL,
  description   VARCHAR(1000)
);

MERGE INTO PIPELINE_CONFIG t
USING (
  SELECT column1 AS config_key, column2 AS config_value, column3 AS description
  FROM VALUES
    ('MEMBER_REJECT_THRESHOLD',     '0.05', 'Max share of rejected records in a Member File before the whole file fails'),
    ('REDEMPTION_REJECT_THRESHOLD', '0.05', 'Max share of rejected redemptions in a Redemption Feed before the whole feed fails'),
    ('STALE_MEMBER_DAYS',           '90',   'A member is stale when Last Flight Date is more than this many days before the Business Date')
) s
ON t.config_key = s.config_key
-- Insert only: never overwrite a value ops has tuned.
WHEN NOT MATCHED THEN INSERT (config_key, config_value, description)
  VALUES (s.config_key, s.config_value, s.description);

-- One row per file seen, whatever happened to it. This is the audit trail and
-- the reconciliation point: total_records = loaded_records + rejected_records.
CREATE TABLE IF NOT EXISTS FILE_BATCH (
  batch_id          NUMBER        NOT NULL DEFAULT SEQ_BATCH_ID.NEXTVAL PRIMARY KEY,
  run_id            VARCHAR(36)   NOT NULL,
  feed_type         VARCHAR(20)   NOT NULL,   -- MEMBER | REDEMPTION
  file_name         VARCHAR(500)  NOT NULL UNIQUE,
  business_date     DATE,                     -- NULL only when the name is invalid
  file_ts           TIMESTAMP_NTZ,
  status            VARCHAR(20)   NOT NULL,   -- PENDING | LOADED | FAILED | REJECTED
  status_reason     VARCHAR(1000),
  header_columns    ARRAY,                    -- Member Files: column names from the H record
  total_records     NUMBER,
  loaded_records    NUMBER,
  rejected_records  NUMBER,
  warning_records   NUMBER,
  reject_rate       NUMBER(9, 6),
  registered_at     TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  completed_at      TIMESTAMP_LTZ
);
