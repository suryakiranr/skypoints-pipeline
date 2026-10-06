-- Consumption views.

-- Members as of today. Hub Age/Stale are as of each Member's last Business
-- Date (ADR 0003); because the Member File is a delta, a Member absent from
-- recent files keeps those values. This view gives the as-of-today reading.
CREATE OR REPLACE VIEW V_MEMBER_CURRENT AS
SELECT
  h.*,
  r.target_table AS country_table,
  IFF(h.date_of_birth IS NULL, NULL,
      DATEDIFF('year', h.date_of_birth, CURRENT_DATE())
        - IFF(DATEADD('year', DATEDIFF('year', h.date_of_birth, CURRENT_DATE()), h.date_of_birth) > CURRENT_DATE(), 1, 0)
  ) AS age_today,
  IFF(h.last_flight_date IS NULL, NULL,
      DATEDIFF('day', h.last_flight_date, CURRENT_DATE())
        > (SELECT TO_NUMBER(config_value) FROM PIPELINE_CONFIG WHERE config_key = 'STALE_MEMBER_DAYS')
  ) AS is_stale_today
FROM MEMBER_HUB h
JOIN COUNTRY_REF r ON r.country_code = h.country_code;

-- How redemptions join back to member profiles.
--
-- Join key: member_id, on the Member Hub, not on the Country Tables. The hub
-- holds every Member exactly once whatever their country, so this is one
-- equi-join instead of a UNION over N tables, and it follows a Country Move
-- automatically. It is a LEFT join so Orphan Redemptions (redemptions for a
-- member_id the profile feed has not delivered yet) stay visible and flagged
-- rather than silently disappearing; they resolve once the Member arrives.
-- Both sides are clustered for this join (MEMBER_HUB by country, REDEMPTION_CURRENT by member_id).
CREATE OR REPLACE VIEW V_REDEMPTION_ENRICHED AS
SELECT
  rc.txn_id,
  rc.member_id,
  rc.txn_date,
  rc.partner,
  rc.miles_redeemed,
  rc.status,
  rc.feed_date,
  h.member_id IS NULL AS is_orphan,
  h.member_name,
  h.tier_code,
  h.country_code,
  r.target_table AS country_table,
  h.is_active,
  h.is_stale_member
FROM REDEMPTION_CURRENT rc
LEFT JOIN MEMBER_HUB h ON h.member_id = rc.member_id
LEFT JOIN COUNTRY_REF r ON r.country_code = h.country_code;

-- Per-member miles, the typical question the join answers.
CREATE OR REPLACE VIEW V_MEMBER_REDEMPTION_SUMMARY AS
SELECT
  h.member_id,
  h.member_name,
  h.country_code,
  h.tier_code,
  COUNT(rc.txn_id)                                               AS redemption_count,
  COALESCE(SUM(IFF(rc.status = 'COMPLETED', rc.miles_redeemed, 0)), 0) AS miles_completed,
  COALESCE(SUM(IFF(rc.status = 'PENDING',   rc.miles_redeemed, 0)), 0) AS miles_pending,
  MAX(rc.txn_date)                                               AS last_redemption_date
FROM MEMBER_HUB h
LEFT JOIN REDEMPTION_CURRENT rc ON rc.member_id = h.member_id
GROUP BY h.member_id, h.member_name, h.country_code, h.tier_code;

-- Data quality reporting: why records were rejected and what was warned.
CREATE OR REPLACE VIEW V_DQ_ISSUE_SUMMARY AS
SELECT 'MEMBER' AS feed_type, 'REJECT' AS severity, mr.batch_id, mr.file_name, reason.value::STRING AS issue_code, COUNT(*) AS records
FROM MEMBER_REJECTS mr, LATERAL FLATTEN(INPUT => mr.reject_reasons) reason
GROUP BY mr.batch_id, mr.file_name, reason.value::STRING
UNION ALL
SELECT 'MEMBER', 'WARNING', s.batch_id, s.file_name, w.value::STRING, COUNT(*)
FROM STG_MEMBER s, LATERAL FLATTEN(INPUT => s.dq_warnings) w
GROUP BY s.batch_id, s.file_name, w.value::STRING
UNION ALL
SELECT 'REDEMPTION', 'REJECT', rr.batch_id, rr.file_name, reason.value::STRING, COUNT(*)
FROM REDEMPTION_REJECTS rr, LATERAL FLATTEN(INPUT => rr.reject_reasons) reason
GROUP BY rr.batch_id, rr.file_name, reason.value::STRING
UNION ALL
SELECT 'REDEMPTION', 'WARNING', e.batch_id, e.file_name, w.value::STRING, COUNT(*)
FROM REDEMPTION_EVENT e, LATERAL FLATTEN(INPUT => e.dq_warnings) w
GROUP BY e.batch_id, e.file_name, w.value::STRING;
