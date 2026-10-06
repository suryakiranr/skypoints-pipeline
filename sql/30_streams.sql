-- Streams make every step incremental: each run processes only what arrived
-- since the last successful run. A stream's offset advances only when the
-- consuming transaction commits, so a failed run is simply retried.

CREATE STREAM IF NOT EXISTS LND_MEMBER_FILE_STREAM
  ON TABLE LND_MEMBER_FILE APPEND_ONLY = TRUE;

CREATE STREAM IF NOT EXISTS LND_REDEMPTION_FEED_STREAM
  ON TABLE LND_REDEMPTION_FEED APPEND_ONLY = TRUE;

CREATE STREAM IF NOT EXISTS STG_MEMBER_STREAM
  ON TABLE STG_MEMBER APPEND_ONLY = TRUE;

-- Standard (not append-only): an UPDATE appears as a DELETE of the old row
-- image plus an INSERT of the new one, which is how Country Moves are seen.
CREATE STREAM IF NOT EXISTS MEMBER_HUB_STREAM
  ON TABLE MEMBER_HUB;

CREATE STREAM IF NOT EXISTS REDEMPTION_EVENT_STREAM
  ON TABLE REDEMPTION_EVENT APPEND_ONLY = TRUE;
