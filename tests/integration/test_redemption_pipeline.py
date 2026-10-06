import json
from datetime import date

import pytest

pytestmark = pytest.mark.integration


def current(w, txn_id):
    return w.query("SELECT * FROM REDEMPTION_CURRENT WHERE txn_id = %s", (txn_id,))[0]


def test_nested_redemptions_are_flattened_one_row_per_transaction(scenario):
    rows = scenario.query(
        "SELECT txn_id, member_id, partner, miles_redeemed, status FROM REDEMPTION_EVENT "
        "WHERE file_name = 'SKYPOINTS_REDEMPTION_20240115_09000000.json' ORDER BY txn_id"
    )
    assert [(r["txn_id"], r["member_id"], r["miles_redeemed"], r["status"]) for r in rows] == [
        ("RX10091", "223457", 12000, "COMPLETED"),
        ("RX10092", "223457", 5000, "PENDING"),
        ("RX20001", "999999", 1000, "COMPLETED"),
    ]


def test_latest_status_wins_and_history_is_kept(scenario):
    rx = current(scenario, "RX10092")
    assert (rx["status"], rx["feed_date"]) == ("COMPLETED", date(2024, 1, 16))
    history = scenario.query(
        "SELECT status FROM REDEMPTION_EVENT WHERE txn_id = 'RX10092' ORDER BY event_order"
    )
    assert [h["status"] for h in history] == ["PENDING", "COMPLETED"]


def test_redemptions_join_back_to_the_member_profile(scenario):
    row = scenario.query("SELECT * FROM V_REDEMPTION_ENRICHED WHERE txn_id = 'RX10091'")[0]
    assert (row["member_name"], row["country_code"], row["country_table"]) == (
        "Elena", "USA", "TABLE_USA",
    )
    assert row["is_orphan"] is False


def test_redemptions_for_unknown_members_are_kept_as_orphans(scenario):
    row = scenario.query("SELECT * FROM V_REDEMPTION_ENRICHED WHERE txn_id = 'RX20001'")[0]
    assert row["is_orphan"] is True
    assert row["member_name"] is None


def test_member_summary_counts_completed_miles(scenario):
    elena = scenario.query(
        "SELECT * FROM V_MEMBER_REDEMPTION_SUMMARY WHERE member_id = '223457'"
    )[0]
    assert (elena["redemption_count"], elena["miles_completed"], elena["miles_pending"]) == (
        2, 17000, 0,
    )


def test_each_redemption_reject_reason_is_recorded(scenario):
    rows = scenario.query(
        "SELECT file_row_number, txn_id, reject_reasons FROM REDEMPTION_REJECTS "
        "WHERE file_name = 'SKYPOINTS_REDEMPTION_20240117_09000000.json'"
    )
    by_key = {(r["file_row_number"], r["txn_id"]): json.loads(r["reject_reasons"]) for r in rows}
    assert by_key[(1, None)] == ["INVALID_JSON"]
    assert by_key[(2, "RX30001")] == ["MILES_REDEEMED_INVALID"]
    assert by_key[(2, "RX30002")] == ["TXN_DATE_AFTER_FEED_DATE"]
    assert by_key[(2, "RX30003")] == ["STATUS_INVALID"]
    assert by_key[(3, None)] == ["REDEMPTIONS_NOT_ARRAY"]


def test_warnings_load_but_are_flagged(scenario):
    event = scenario.query("SELECT * FROM REDEMPTION_EVENT WHERE txn_id = 'RX30004'")[0]
    assert event["status"] == "PENDING", "status is normalised to upper case"
    assert json.loads(event["dq_warnings"]) == ["PARTNER_MISSING"]


def test_empty_redemption_list_is_not_an_error(scenario):
    b = scenario.query(
        "SELECT * FROM FILE_BATCH WHERE file_name = 'SKYPOINTS_REDEMPTION_20240115_09000000.json'"
    )[0]
    assert (b["status"], b["total_records"], b["rejected_records"]) == ("LOADED", 3, 0)
