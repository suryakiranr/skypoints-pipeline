import json
from datetime import date

import pytest

from skypoints.pipeline import dq_checks

pytestmark = pytest.mark.integration


def members_in(w, table):
    return {r["member_id"] for r in w.query(f"SELECT member_id FROM {table}")}


def hub(w, member_id):
    row = w.query("SELECT * FROM MEMBER_HUB WHERE member_id = %s", (member_id,))[0]
    return {**row, "dq_warnings": json.loads(row["dq_warnings"])}


def batch(w, file_name):
    return w.query("SELECT * FROM FILE_BATCH WHERE file_name = %s", (file_name,))[0]


def test_members_are_split_into_their_country_tables(scenario):
    assert members_in(scenario, "TABLE_USA") == {"223457", "223458", "300001", "300002", "300010"}
    assert members_in(scenario, "TABLE_INDIA") == {"300003"}
    assert members_in(scenario, "TABLE_PHILIPPINES") == {"223459"}
    assert members_in(scenario, "TABLE_CANADA") == {"300004"}
    assert members_in(scenario, "TABLE_AUSTRALIA") == {"2256", "22345"}


def test_source_country_spellings_map_to_one_iso_code(scenario):
    assert hub(scenario, "223459")["country_raw"] == "PHIL"
    assert hub(scenario, "223459")["country_code"] == "PHL"
    assert hub(scenario, "2256")["country_code"] == "AUS"   # sent as AU
    assert hub(scenario, "300004")["country_code"] == "CAN"  # sent as CA


def test_country_move_leaves_the_old_table(scenario):
    assert "223458" not in members_in(scenario, "TABLE_INDIA")
    assert hub(scenario, "223458")["country_code"] == "USA"
    staged = scenario.scalar("SELECT COUNT(*) FROM STG_MEMBER WHERE member_id = '223458'")
    assert staged == 2, "staging keeps every version"


def test_later_record_overwrites_attributes(scenario):
    row = scenario.query("SELECT member_name FROM TABLE_PHILIPPINES WHERE member_id = '223459'")[0]
    assert row["member_name"] == "Mateo R"


def test_late_arriving_older_file_does_not_win(scenario):
    elena = hub(scenario, "223457")
    assert elena["country_code"] == "USA"
    assert elena["source_file_name"] == "SKYPOINTS_MEMBER_20240115_09000000.dat"
    assert hub(scenario, "300004")["member_name"] == "Hana", "new members in a late file still load"


def test_within_a_file_the_later_line_wins_and_both_are_flagged(scenario):
    nora = hub(scenario, "22345")
    assert nora["country_code"] == "AUS"
    assert nora["source_row_number"] == 3
    flagged = scenario.scalar(
        "SELECT COUNT(*) FROM STG_MEMBER WHERE member_id = '22345' "
        "AND ARRAY_CONTAINS('DUPLICATE_MEMBER_IN_FILE'::VARIANT, dq_warnings)"
    )
    assert flagged == 2


def test_age_and_stale_flag_are_as_of_the_business_date(scenario):
    liam, olivia, priya = (hub(scenario, m) for m in ("300001", "300002", "300003"))
    assert liam["business_date"] == date(2024, 1, 15)
    assert (liam["age"], liam["is_stale_member"]) == (34, False)       # birthday today; 90 days
    assert (olivia["age"], olivia["is_stale_member"]) == (33, True)    # birthday tomorrow; 91 days
    assert priya["is_stale_member"] is None
    assert hub(scenario, "223457")["is_stale_member"] is True          # last flew in 2012


def test_dob_that_lost_its_leading_zero_is_not_misread(scenario):
    jacob = hub(scenario, "2256")
    assert jacob["date_of_birth"] is None
    assert jacob["age"] is None
    assert "DOB_INVALID" in jacob["dq_warnings"]
    assert "MEMBER_ID_SHORT" in jacob["dq_warnings"]


def test_file_over_the_reject_threshold_fails_whole(scenario):
    b = batch(scenario, "SKYPOINTS_MEMBER_20240118_09000000.dat")
    assert (b["status"], b["status_reason"]) == ("FAILED", "REJECT_THRESHOLD_EXCEEDED")
    assert (b["total_records"], b["rejected_records"], b["loaded_records"]) == (2, 1, 0)
    assert not scenario.query("SELECT 1 FROM MEMBER_HUB WHERE member_id = '300005'")


def test_each_reject_reason_is_recorded(scenario):
    rows = scenario.query(
        "SELECT file_row_number, reject_reasons FROM MEMBER_REJECTS "
        "WHERE file_name = 'SKYPOINTS_MEMBER_20240119_09000000.dat' ORDER BY file_row_number"
    )
    reasons = {r["file_row_number"]: json.loads(r["reject_reasons"]) for r in rows}
    assert "MEMBER_ID_MISSING" in reasons[3]
    assert "COUNTRY_UNMAPPED" in reasons[4]
    assert "ENROLLMENT_DATE_INVALID" in reasons[5]
    assert "COUNTRY_MISSING" in reasons[6]
    assert "FIELD_COUNT_MISMATCH" in reasons[7]
    assert "TIER_CODE_TOO_LONG" in reasons[8]
    assert "LEADING_DELIMITER_MISSING" in reasons[9]
    assert 2 not in reasons

    b = batch(scenario, "SKYPOINTS_MEMBER_20240119_09000000.dat")
    assert (b["status"], b["total_records"], b["loaded_records"], b["rejected_records"]) == (
        "LOADED", 8, 1, 7,
    )


@pytest.mark.parametrize(
    ("file_name", "reason"),
    [
        ("members_jan.dat", "INVALID_FILE_NAME"),
        ("SKYPOINTS_MEMBER_20240120_09000000.dat", "HEADER_MISSING_COLUMNS: Country"),
    ],
)
def test_bad_files_are_rejected_whole(scenario, file_name, reason):
    b = batch(scenario, file_name)
    assert (b["status"], b["status_reason"]) == ("REJECTED", reason)
    assert not scenario.query("SELECT 1 FROM MEMBER_HUB WHERE member_id IN ('300020', '300021')")


def test_a_run_with_nothing_new_changes_nothing(scenario):
    idle = scenario.runs["idle"]
    assert idle["member_files"] == []
    assert idle["member_hub"]["rows_merged"] == 0
    assert idle["country_tables"]["changed_members"] == 0


def test_no_data_quality_invariant_is_broken(scenario):
    broken = [c for c in dq_checks(scenario.conn) if c["severity"] == "ERROR" and c["failures"]]
    assert broken == []
