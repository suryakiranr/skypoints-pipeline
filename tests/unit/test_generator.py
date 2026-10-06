import json
from datetime import date, datetime

from skypoints.filenames import Feed, parse_file_name
from skypoints.generator import (
    MEMBER_HEADER,
    Defects,
    member_lines,
    redemption_lines,
    write_feed_files,
)

BUSINESS_DATE = date(2024, 1, 15)


def details(lines):
    return [line.split("|") for line in lines if line.startswith("|D|")]


def test_member_file_has_one_header_then_well_formed_details():
    lines = list(member_lines(50, BUSINESS_DATE))

    assert lines[0] == MEMBER_HEADER
    header_fields = len(MEMBER_HEADER.split("|"))
    assert all(len(fields) == header_fields for fields in details(lines))
    assert len(details(lines)) == 50


def test_clean_member_rows_satisfy_the_layout():
    for fields in details(member_lines(200, BUSINESS_DATE)):
        _, _, name, member_id, enrolled, flight, *_rest, dob, active = fields
        assert name and len(member_id) == 6
        assert datetime.strptime(enrolled, "%Y%m%d").date() <= BUSINESS_DATE
        assert flight >= enrolled
        assert datetime.strptime(dob, "%m%d%Y")
        assert active in {"A", "I"}


def test_same_seed_same_output_different_seed_different_output():
    def run(seed):
        return list(member_lines(20, BUSINESS_DATE, seed=seed))

    assert run(1) == run(1)
    assert run(1) != run(2)


def test_reject_defects_are_injected_at_roughly_the_requested_rate():
    rows = details(member_lines(2000, BUSINESS_DATE, defects=Defects(reject_fraction=0.1)))

    defective = [
        f for f in rows
        if f[3] == "" or f[9] == "XX" or f[4] == "2024-13-01"
    ]
    assert 140 <= len(defective) <= 260


def test_redemption_lines_are_one_json_member_object_each():
    lines = list(redemption_lines(30, BUSINESS_DATE, seed=3))

    assert len(lines) == 30
    records = [json.loads(line) for line in lines]
    assert all(r["feed_date"] == "20240115" for r in records)
    txn_ids = [t["txn_id"] for r in records for t in r["redemptions"]]
    assert len(txn_ids) == len(set(txn_ids))


def test_write_feed_files_names_files_per_spec(tmp_path):
    member_path, redemption_path = write_feed_files(tmp_path, 5, datetime(2024, 1, 15, 9, 30))

    assert parse_file_name(member_path.name).feed is Feed.MEMBER
    assert parse_file_name(redemption_path.name).feed is Feed.REDEMPTION
    assert b"\r\n" not in member_path.read_bytes()
