"""The two periods the cost rows and the Cursor rows are counted over."""

from __future__ import annotations

from datetime import datetime, time, timedelta

WEEK = timedelta(days=7)


def start_of_today(now: datetime) -> datetime:
    """Local midnight of the day `now` falls in.

    Built from the local date rather than by zeroing the clock of `now`, so it carries the
    UTC offset in force at midnight. On the day the clocks change that is not the offset
    in force at `now`, and zeroing the clock lands an hour off.
    """
    return datetime.combine(now.astimezone().date(), time.min).astimezone()
