-- Core: the Member Hub (ADR 0002) and the redemption model.

-- One row per Member: their Current Member Record. Country Tables are created
-- LIKE this table, so both always share one shape.
CREATE TABLE IF NOT EXISTS MEMBER_HUB (
  member_id          VARCHAR(18)   NOT NULL PRIMARY KEY,
  member_name        VARCHAR(255)  NOT NULL,
  enrollment_date    DATE          NOT NULL,
  last_flight_date   DATE,
  tier_code          VARCHAR(5),
  agent_name         VARCHAR(255),
  state              VARCHAR(5),
  country_raw        VARCHAR(5)    NOT NULL,
  country_code       VARCHAR(3)    NOT NULL,
  post_code          VARCHAR(5),
  date_of_birth      DATE,
  is_active          VARCHAR(1),
  age                NUMBER(3),
  is_stale_member    BOOLEAN,
  dq_warnings        ARRAY         NOT NULL,

  -- Lineage of the record currently held.
  business_date      DATE          NOT NULL,
  record_order       VARCHAR(40)   NOT NULL,
  source_batch_id    NUMBER        NOT NULL,
  source_file_name   VARCHAR(500)  NOT NULL,
  source_row_number  NUMBER        NOT NULL,
  first_seen_at      TIMESTAMP_LTZ NOT NULL,
  updated_at         TIMESTAMP_LTZ NOT NULL
)
CLUSTER BY (country_code);

-- Every sighting of every redemption: the status history.
CREATE TABLE IF NOT EXISTS REDEMPTION_EVENT (
  batch_id          NUMBER        NOT NULL,
  file_name         VARCHAR(500)  NOT NULL,
  file_ts           TIMESTAMP_NTZ NOT NULL,
  file_row_number   NUMBER        NOT NULL,
  redemption_index  NUMBER        NOT NULL,  -- position in the member's redemptions array
  event_order       VARCHAR(60)   NOT NULL,  -- sortable "latest wins" key: feed_date + file_ts + row + index

  feed_date         DATE          NOT NULL,
  member_id         VARCHAR(18)   NOT NULL,
  txn_id            VARCHAR(50)   NOT NULL,
  txn_date          DATE          NOT NULL,
  partner           VARCHAR(100),
  miles_redeemed    NUMBER(12, 0) NOT NULL,
  status            VARCHAR(20)   NOT NULL,
  dq_warnings       ARRAY         NOT NULL,

  loaded_at         TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (feed_date);

-- One row per txn_id: its latest known state.
CREATE TABLE IF NOT EXISTS REDEMPTION_CURRENT (
  txn_id             VARCHAR(50)   NOT NULL PRIMARY KEY,
  member_id          VARCHAR(18)   NOT NULL,
  txn_date           DATE          NOT NULL,
  partner            VARCHAR(100),
  miles_redeemed     NUMBER(12, 0) NOT NULL,
  status             VARCHAR(20)   NOT NULL,
  feed_date          DATE          NOT NULL,
  event_order        VARCHAR(60)   NOT NULL,
  source_batch_id    NUMBER        NOT NULL,
  first_seen_at      TIMESTAMP_LTZ NOT NULL,
  updated_at         TIMESTAMP_LTZ NOT NULL
)
CLUSTER BY (member_id);

CREATE TABLE IF NOT EXISTS REDEMPTION_REJECTS (
  batch_id          NUMBER        NOT NULL,
  file_name         VARCHAR(500)  NOT NULL,
  file_row_number   NUMBER        NOT NULL,
  redemption_index  NUMBER,                  -- NULL when the whole member object is bad
  member_id         VARCHAR,
  txn_id            VARCHAR,
  raw_redemption    VARIANT,
  reject_reasons    ARRAY         NOT NULL,
  rejected_at       TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);
