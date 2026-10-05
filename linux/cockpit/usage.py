"""The usage limits Claude's `/usage` command reports, and the parser that reads them.

A port of `CockpitCore/UsageMeter.swift` and `CockpitCore/UsageParser.swift`.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import Enum
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

MONTH_ABBREVIATIONS = [
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
]


class Severity(Enum):
    NORMAL = "normal"
    ELEVATED = "elevated"
    CRITICAL = "critical"


@dataclass(frozen=True)
class UsageMeter:
    """One usage limit as reported by Claude's `/usage` command."""

    label: str
    percent_used: int
    #: When the limit resets, or None when the reset text could not be parsed.
    reset_at: datetime | None
    #: Reset text in a form the parser does not recognize, kept verbatim for display.
    reset_text: str

    @property
    def severity(self) -> Severity:
        if self.percent_used < 70:
            return Severity.NORMAL
        if self.percent_used < 90:
            return Severity.ELEVATED
        return Severity.CRITICAL


_LINE = re.compile(r"Current (.+?): (\d+)% used · resets (.+)")
_WEEK_OF = re.compile(r"week \((.+)\)", re.IGNORECASE)
# Claude Code has written the date and the time separated both by ` at ` and by `, `.
# Both are accepted, so a change of wording on that one separator does not cost the countdown.
_RESET = re.compile(
    r"([A-Za-z]{3}) (\d{1,2})(?:,)?(?: at)? (\d{1,2})(?::(\d{2}))?(am|pm) \((.+)\)"
)


def parse_usage(text: str, now: datetime) -> list[UsageMeter]:
    """One meter per `Current <name>: <N>% used · resets <when>` line, in output order."""
    meters = []
    for line in text.splitlines():
        match = _LINE.fullmatch(line.strip())
        if match is None:
            continue
        reset_at = _parse_reset(match.group(3), now)
        meters.append(
            UsageMeter(
                label=_label(match.group(1)),
                percent_used=min(int(match.group(2)), 100),
                reset_at=reset_at,
                reset_text=match.group(3),
            )
        )
    return meters


def _label(name: str) -> str:
    """`session` -> SESSION, `week (all models)` -> WEEK, `week (X)` -> WEEK · X.

    Anything else is shown as-is in capitals, so a new limit appears without a code change.
    """
    lowered = name.lower()
    if lowered == "session":
        return "SESSION"
    if lowered == "week (all models)":
        return "WEEK"
    match = _WEEK_OF.fullmatch(name)
    if match is not None:
        return f"WEEK · {match.group(1).upper()}"
    return name.upper()


def _parse_reset(text: str, now: datetime) -> datetime | None:
    """Parses `<Mon> <d> at <h>[:mm]<am|pm> (<IANA zone>)`, or None if it does not match."""
    match = _RESET.fullmatch(text)
    if match is None:
        return None

    month_name, day, hour12, minute, meridiem, zone_name = match.groups()
    try:
        month = MONTH_ABBREVIATIONS.index(month_name.lower()) + 1
    except ValueError:
        return None
    hour12 = int(hour12)
    if not 1 <= hour12 <= 12:
        return None
    try:
        zone = ZoneInfo(zone_name)
    except (ZoneInfoNotFoundError, ValueError):
        return None

    hour = hour12 % 12 + (12 if meridiem == "pm" else 0)
    minute = int(minute) if minute else 0

    # The year is not printed, so take the one that lands closest to now.
    candidates = []
    for year in (now.year - 1, now.year, now.year + 1):
        try:
            candidates.append(
                datetime(year, month, int(day), hour, minute, tzinfo=zone)
            )
        except ValueError:
            continue  # Feb 29 in a common year.
    if not candidates:
        return None
    return min(candidates, key=lambda when: abs(when - now))


def compact_duration(delta: timedelta) -> str:
    """`2d 5h`, `3h 12m`, `12m`, or `<1m` for anything under a minute."""
    total_minutes = int(delta.total_seconds()) // 60
    days, remainder = divmod(total_minutes, 1440)
    hours, minutes = divmod(remainder, 60)

    if days > 0:
        return f"{days}d {hours}h"
    if hours > 0:
        return f"{hours}h {minutes}m"
    if minutes > 0:
        return f"{minutes}m"
    return "<1m"


def reset_countdown(meter: UsageMeter, now: datetime) -> str:
    """`resets in 3h 12m`, `resets now`, or the unrecognized reset text verbatim."""
    if meter.reset_at is None:
        return f"resets {meter.reset_text}"
    remaining = meter.reset_at - now
    if remaining.total_seconds() <= 0:
        return "resets now"
    return f"resets in {compact_duration(remaining)}"
