"""The feed file-name specification.

``SKYPOINTS_<FEED>_YYYYMMDD_HHMMSSTT.<ext>`` where TT is hundredths of a second.
The date part is the file's Business Date; date + time order files within a feed.
The same rule is implemented in SQL (``sql/40_proc_member_load.sql``) so that
badly named files that still reach the stage are rejected, not silently loaded.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from enum import StrEnum


class Feed(StrEnum):
    MEMBER = "MEMBER"
    REDEMPTION = "REDEMPTION"

    @property
    def extension(self) -> str:
        return {Feed.MEMBER: "dat", Feed.REDEMPTION: "json"}[self]

    @property
    def stage_prefix(self) -> str:
        return self.value.lower()


class InvalidFileName(ValueError):
    pass


@dataclass(frozen=True)
class FeedFileName:
    feed: Feed
    business_date: date
    file_ts: datetime


_PATTERN = re.compile(
    r"^SKYPOINTS_(?P<feed>MEMBER|REDEMPTION)_(?P<date>\d{8})_(?P<time>\d{6})(?P<hundredths>\d{2})"
    r"\.(?P<ext>dat|json)$"
)


def parse_file_name(name: str) -> FeedFileName:
    """Parse a feed file name, ignoring any stage path and compression suffix."""
    base = name.rsplit("/", 1)[-1].removesuffix(".gz")
    match = _PATTERN.match(base)
    if not match:
        raise InvalidFileName(f"{name!r} does not match SKYPOINTS_<FEED>_YYYYMMDD_HHMMSSTT.<ext>")

    feed = Feed(match["feed"])
    if match["ext"] != feed.extension:
        raise InvalidFileName(f"{name!r}: {feed} files must end in .{feed.extension}")

    try:
        whole_seconds = datetime.strptime(match["date"] + match["time"], "%Y%m%d%H%M%S")
    except ValueError as exc:
        raise InvalidFileName(f"{name!r}: {exc}") from exc

    file_ts = whole_seconds + timedelta(milliseconds=int(match["hundredths"]) * 10)
    return FeedFileName(feed=feed, business_date=file_ts.date(), file_ts=file_ts)


def build_file_name(feed: Feed, file_ts: datetime) -> str:
    hundredths = file_ts.microsecond // 10_000
    return f"SKYPOINTS_{feed}_{file_ts:%Y%m%d_%H%M%S}{hundredths:02d}.{feed.extension}"
