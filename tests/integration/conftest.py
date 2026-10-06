"""Integration tests: the whole pipeline on a live Snowflake account.

A uniquely named schema is created in SNOWFLAKE_DATABASE, the pipeline is
deployed into it, one scenario of daily runs is played through, and the schema
is dropped afterwards (set SKYPOINTS_KEEP_TEST_SCHEMA=1 to keep it for a look).
Skipped entirely when no Snowflake settings are present; see snowflake_conn.py.
"""

from __future__ import annotations

import os
import uuid
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import pytest

from skypoints import pipeline
from skypoints.snowflake_conn import Target, connect, settings_present, target_from_env

pytestmark = pytest.mark.integration

HEADER = (
    "|H|Member_Name|Member_Id|Enrollment_Date|Last_Flight_Date|Tier_Code|Agent_Name"
    "|State|Country|DOB|Is_Active"
)


def pytest_collection_modifyitems(config, items):
    if settings_present():
        return
    skip = pytest.mark.skip(reason="no Snowflake settings in the environment")
    for item in items:
        if "integration" in str(item.fspath):
            item.add_marker(skip)


@dataclass
class Warehouse:
    conn: Any
    target: Target
    files_dir: Path
    runs: dict[str, dict] = field(default_factory=dict)

    def query(self, sql: str, params: tuple | None = None) -> list[dict[str, Any]]:
        return pipeline.query(self.conn, sql, params)

    def scalar(self, sql: str, params: tuple | None = None) -> Any:
        rows = self.query(sql, params)
        return next(iter(rows[0].values())) if rows else None

    def set_config(self, key: str, value: str) -> None:
        self.query("UPDATE PIPELINE_CONFIG SET config_value = %s WHERE config_key = %s", (value, key))

    def write(self, name: str, lines: list[str]) -> Path:
        path = self.files_dir / name
        path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
        return path

    def run(self, label: str, *files: Path) -> dict:
        if files:
            pipeline.put_files(self.conn, list(files))
        self.runs[label] = pipeline.run_pipeline(self.conn)
        return self.runs[label]


@pytest.fixture(scope="session")
def warehouse(tmp_path_factory) -> Iterator[Warehouse]:
    base = target_from_env()
    target = Target(base.warehouse, base.database, f"SKYPOINTS_IT_{uuid.uuid4().hex[:10]}")
    with connect(target) as conn:
        try:
            pipeline.deploy(conn, target)
            yield Warehouse(conn, target, tmp_path_factory.mktemp("feeds"))
        finally:
            if not os.environ.get("SKYPOINTS_KEEP_TEST_SCHEMA"):
                conn.cursor().execute(f"DROP SCHEMA IF EXISTS {target.schema}")


@pytest.fixture(scope="session")
def scenario(warehouse: Warehouse) -> Warehouse:
    """A week of feeds, one pipeline run per step, covering every rule."""
    w = warehouse

    # Day 1: the brief's sample (Jacob's DOB has lost its leading zero, as in
    # the brief's staging table), plus the stale-boundary and age cases.
    w.run(
        "day1",
        w.write("SKYPOINTS_MEMBER_20240115_09000000.dat", [
            HEADER,
            "|D|Elena|223457|20101012|20121013|GLD|Sam|CA|USA|03051985|A",
            "|D|Ravi|223458|20101012|20121013|SLV|Sam|TN|IND|03051985|A",
            "|D|Mateo|223459|20101012|20121013|GLD|Sam|NCR|PHIL|03051985|A",
            "|D|Nora|22345|20101012|20121013|PLT|Sam|ONT|CAN|03051985|A",
            "|D|Jacob|2256|20101012|20121013|SLV|Sam|VIC|AU|3051985|A",
            "|D|Liam|300001|20101012|20231017|GLD|Sam|NY|USA|01151990|A",    # flew exactly 90 days ago
            "|D|Olivia|300002|20101012|20231016|GLD|Sam|NY|USA|01161990|A",  # 91 days ago
            "|D|Priya|300003|20101012||GLD|Sam|KA|IND|12311990|A",           # never flown
        ]),
        w.write("SKYPOINTS_REDEMPTION_20240115_09000000.json", [
            '{"member_id": "223457", "feed_date": "20240115", "redemptions": ['
            '{"txn_id": "RX10091", "txn_date": "20240110", "partner": "AeroLink", "miles_redeemed": 12000, "status": "COMPLETED"},'
            '{"txn_id": "RX10092", "txn_date": "20240113", "partner": "SkyPoints", "miles_redeemed": 5000, "status": "PENDING"}]}',
            '{"member_id": "999999", "feed_date": "20240115", "redemptions": ['
            '{"txn_id": "RX20001", "txn_date": "20240112", "partner": "AeroLink", "miles_redeemed": 1000, "status": "COMPLETED"}]}',
            '{"member_id": "223458", "feed_date": "20240115", "redemptions": []}',
        ]),
    )

    # Day 2: Ravi moves IND -> USA; Mateo's name changes; RX10092 completes.
    w.run(
        "day2",
        w.write("SKYPOINTS_MEMBER_20240116_09000000.dat", [
            HEADER,
            "|D|Ravi|223458|20101012|20240110|SLV|Sam|NY|USA|03051985|A",
            "|D|Mateo R|223459|20101012|20121013|GLD|Sam|NCR|PHIL|03051985|A",
        ]),
        w.write("SKYPOINTS_REDEMPTION_20240116_09000000.json", [
            '{"member_id": "223457", "feed_date": "20240116", "redemptions": ['
            '{"txn_id": "RX10092", "txn_date": "20240113", "partner": "SkyPoints", "miles_redeemed": 5000, "status": "COMPLETED"}]}',
        ]),
    )

    # A late file, OLDER than day 1: Elena's CAN record must not win.
    w.run(
        "late_older_file",
        w.write("SKYPOINTS_MEMBER_20240114_09000000.dat", [
            HEADER,
            "|D|Elena|223457|20101012|20121013|GLD|Sam|ONT|CAN|03051985|A",
            "|D|Hana|300004|20101012|20121013|SLV|Sam|BC|CA|07041980|A",
        ]),
    )

    # The same member twice in one file: the later line wins.
    w.run(
        "same_file_duplicate",
        w.write("SKYPOINTS_MEMBER_20240117_09000000.dat", [
            HEADER,
            "|D|Nora|22345|20101012|20121013|PLT|Sam|ONT|CAN|03051985|A",
            "|D|Nora|22345|20101012|20121013|PLT|Sam|NSW|AUS|03051985|A",
        ]),
    )

    # 1 of 2 records rejected: 50% is over the 5% threshold, so the file fails whole.
    w.run(
        "threshold_breach",
        w.write("SKYPOINTS_MEMBER_20240118_09000000.dat", [
            HEADER,
            "|D|Good|300005|20101012|20121013|GLD|Sam|CA|USA|03051985|A",
            "|D|Bad|300006|20101012|20121013|GLD|Sam|ZZ|XX|03051985|A",
        ]),
    )

    # One of each reject reason, loaded under a raised threshold.
    w.set_config("MEMBER_REJECT_THRESHOLD", "0.9")
    w.set_config("REDEMPTION_REJECT_THRESHOLD", "0.9")
    try:
        w.run(
            "rejects",
            w.write("SKYPOINTS_MEMBER_20240119_09000000.dat", [
                HEADER,
                "|D|Kept|300010|20101012|20121013|GLD|Sam|CA|USA|03051985|A",
                "|D|NoId||20101012|20121013|GLD|Sam|CA|USA|03051985|A",
                "|D|Zed|300011|20101012|20121013|GLD|Sam|ZZ|XYZ|03051985|A",
                "|D|BadDate|300012|20101399|20121013|GLD|Sam|CA|USA|03051985|A",
                "|D|NoCountry|300013|20101012|20121013|GLD|Sam|CA||03051985|A",
                "|D|Extra|300014|20101012|20121013|GLD|Sam|CA|USA|03051985|A|surplus",
                "|D|LongTier|300015|20101012|20121013|GOLDXX|Sam|CA|USA|03051985|A",
                "D|NoLead|300016|20101012|20121013|GLD|Sam|CA|USA|03051985|A",
            ]),
            w.write("SKYPOINTS_REDEMPTION_20240117_09000000.json", [
                '{"member_id": "223457", broken',
                '{"member_id": "223458", "feed_date": "20240117", "redemptions": ['
                '{"txn_id": "RX30001", "txn_date": "20240116", "partner": "AeroLink", "miles_redeemed": -5, "status": "COMPLETED"},'
                '{"txn_id": "RX30002", "txn_date": "20240118", "partner": "AeroLink", "miles_redeemed": 100, "status": "COMPLETED"},'
                '{"txn_id": "RX30003", "txn_date": "20240116", "partner": "AeroLink", "miles_redeemed": 100, "status": "LOST"},'
                '{"txn_id": "RX30004", "txn_date": "20240116", "miles_redeemed": 250, "status": "pending"}]}',
                '{"member_id": "223458", "feed_date": "20240117", "redemptions": "oops"}',
            ]),
        )
    finally:
        w.set_config("MEMBER_REJECT_THRESHOLD", "0.05")
        w.set_config("REDEMPTION_REJECT_THRESHOLD", "0.05")

    # Files rejected whole: a name outside the spec, and a header missing a column.
    w.run(
        "bad_files",
        w.write("members_jan.dat", [HEADER, "|D|Name|300020|20101012|20121013|GLD|Sam|CA|USA|03051985|A"]),
        w.write("SKYPOINTS_MEMBER_20240120_09000000.dat", [
            HEADER.replace("|Country", ""),
            "|D|Name|300021|20101012|20121013|GLD|Sam|CA|03051985|A",
        ]),
    )

    # Nothing new arrives: a run must change nothing.
    w.run("idle")
    return w
