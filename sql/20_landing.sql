-- Landing (raw) tables: exactly what arrived, plus where it came from. No
-- parsing, no typing, so a load can never fail on content and nothing is lost.
-- Consumers read these through append-only streams (30_streams.sql), never by
-- scanning, so the tables can grow and be purged on a retention schedule.

CREATE TABLE IF NOT EXISTS LND_MEMBER_FILE (
  file_path        VARCHAR(1000) NOT NULL,  -- METADATA$FILENAME, stage-relative
  file_row_number  NUMBER        NOT NULL,  -- METADATA$FILE_ROW_NUMBER, 1-based
  raw_line         VARCHAR       NOT NULL,
  landed_at        TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS LND_REDEMPTION_FEED (
  file_path        VARCHAR(1000) NOT NULL,
  file_row_number  NUMBER        NOT NULL,
  raw_line         VARCHAR       NOT NULL,  -- one JSON member object with its redemptions
  landed_at        TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);
