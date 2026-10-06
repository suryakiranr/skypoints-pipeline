from datetime import date, datetime

import pytest

from skypoints.filenames import Feed, FeedFileName, InvalidFileName, build_file_name, parse_file_name


def test_parses_member_file_name():
    parsed = parse_file_name("SKYPOINTS_MEMBER_20240115_09300512.dat")

    assert parsed == FeedFileName(
        feed=Feed.MEMBER,
        business_date=date(2024, 1, 15),
        file_ts=datetime(2024, 1, 15, 9, 30, 5, 120000),
    )


def test_parses_redemption_file_name():
    parsed = parse_file_name("SKYPOINTS_REDEMPTION_20240116_23595999.json")

    assert parsed.feed is Feed.REDEMPTION
    assert parsed.file_ts == datetime(2024, 1, 16, 23, 59, 59, 990000)


def test_ignores_stage_path_prefix():
    parsed = parse_file_name("member/SKYPOINTS_MEMBER_20240115_09300000.dat.gz")

    assert parsed.business_date == date(2024, 1, 15)


@pytest.mark.parametrize(
    "name",
    [
        "members_jan.dat",
        "SKYPOINTS_MEMBER_20240115.dat",  # no time part
        "SKYPOINTS_MEMBER_20240132_09300000.dat",  # impossible date
        "SKYPOINTS_MEMBER_20240115_25000000.dat",  # impossible hour
        "SKYPOINTS_MEMBER_20240115_09300000.json",  # wrong extension for feed
        "SKYPOINTS_REDEMPTION_20240115_09300000.dat",
        "skypoints_member_20240115_09300000.dat",  # case matters
    ],
)
def test_rejects_names_outside_the_spec(name):
    with pytest.raises(InvalidFileName):
        parse_file_name(name)


def test_build_round_trips_through_parse():
    ts = datetime(2024, 3, 5, 7, 8, 9, 450000)

    name = build_file_name(Feed.MEMBER, ts)

    assert name == "SKYPOINTS_MEMBER_20240305_07080945.dat"
    assert parse_file_name(name).file_ts == ts
