"""Synthetic feed files for demos and volume tests.

Output is deterministic for a given seed. Rows are written as they are made, so
memory stays flat whatever the row count. Optional fractions add the defects the
pipeline must catch: rejects (unmapped country, missing Member ID, bad
Enrollment Date) and warnings (a DOB that lost its leading zero, a short
Member ID).
"""

from __future__ import annotations

import json
import random
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path

from skypoints.filenames import Feed, build_file_name

MEMBER_HEADER = (
    "|H|Member_Name|Member_Id|Enrollment_Date|Last_Flight_Date|Tier_Code|Agent_Name"
    "|State|Country|DOB|Is_Active"
)

# Source spellings, deliberately mixed like the sample: ISO-3, ISO-2, nonstandard.
_COUNTRIES = {
    "USA": ["CA", "NY", "TX", "WA"],
    "IND": ["TN", "KA", "MH", "DL"],
    "PHIL": ["NCR", "CEB"],
    "CAN": ["ONT", "BC", "QC"],
    "AU": ["VIC", "NSW", "QLD"],
}
_FIRST_NAMES = ["Elena", "Ravi", "Mateo", "Nora", "Jacob", "Priya", "Liam", "Aiko", "Omar", "Sofia"]
_TIERS = ["SLV", "GLD", "PLT"]
_AGENTS = ["Sam", "Asha", "Lee", "Maria"]
_PARTNERS = ["AeroLink", "SkyPoints", "OceanAir", "NorthJet"]
_STATUSES = ["COMPLETED", "PENDING", "CANCELLED"]


@dataclass(frozen=True)
class Defects:
    reject_fraction: float = 0.0
    warning_fraction: float = 0.0


NO_DEFECTS = Defects()


def member_lines(
    rows: int, business_date: date, *, seed: int = 0, first_member_id: int = 100_000,
    defects: Defects = NO_DEFECTS,
) -> Iterator[str]:
    rng = random.Random(seed)
    yield MEMBER_HEADER
    for i in range(rows):
        member_id = str(first_member_id + i)
        country = rng.choice(list(_COUNTRIES))
        enrolled = business_date - timedelta(days=rng.randint(30, 6000))
        last_flight = business_date - timedelta(days=rng.randint(0, 400))
        dob = business_date - timedelta(days=rng.randint(18 * 365, 80 * 365))
        fields = {
            "name": rng.choice(_FIRST_NAMES),
            "id": member_id,
            "enrolled": f"{enrolled:%Y%m%d}",
            "flight": f"{max(last_flight, enrolled):%Y%m%d}",
            "tier": rng.choice(_TIERS),
            "agent": rng.choice(_AGENTS),
            "state": rng.choice(_COUNTRIES[country]),
            "country": country,
            "dob": f"{dob:%m%d%Y}",
            "active": rng.choice("AAAAI"),
        }

        roll = rng.random()
        if roll < defects.reject_fraction:
            defect = rng.choice(["country", "id", "enrolled"])
            fields[defect] = {"country": "XX", "id": "", "enrolled": "2024-13-01"}[defect]
        elif roll < defects.reject_fraction + defects.warning_fraction:
            if fields["dob"].startswith("0") and rng.random() < 0.5:
                fields["dob"] = fields["dob"][1:]
            else:
                fields["id"] = fields["id"][:4]

        yield "|D|" + "|".join(fields.values())


def redemption_lines(
    members: int, business_date: date, *, seed: int = 0, first_member_id: int = 100_000,
    max_per_member: int = 3,
) -> Iterator[str]:
    rng = random.Random(seed)
    txn = 0
    for i in range(members):
        redemptions = []
        for _ in range(rng.randint(0, max_per_member)):
            txn += 1
            redemptions.append({
                "txn_id": f"RX{seed:03d}{txn:09d}",
                "txn_date": f"{business_date - timedelta(days=rng.randint(0, 10)):%Y%m%d}",
                "partner": rng.choice(_PARTNERS),
                "miles_redeemed": rng.randrange(500, 50_000, 500),
                "status": rng.choice(_STATUSES),
            })
        yield json.dumps({
            "member_id": str(first_member_id + i),
            "feed_date": f"{business_date:%Y%m%d}",
            "redemptions": redemptions,
        })


def write_feed_files(
    out_dir: Path, members: int, file_ts: datetime, *, seed: int = 0, defects: Defects = NO_DEFECTS,
) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    member_path = out_dir / build_file_name(Feed.MEMBER, file_ts)
    redemption_path = out_dir / build_file_name(Feed.REDEMPTION, file_ts)
    _write_lines(member_path, member_lines(members, file_ts.date(), seed=seed, defects=defects))
    _write_lines(redemption_path, redemption_lines(members, file_ts.date(), seed=seed))
    return member_path, redemption_path


def _write_lines(path: Path, lines: Iterator[str]) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as f:
        for line in lines:
            f.write(line)
            f.write("\n")
