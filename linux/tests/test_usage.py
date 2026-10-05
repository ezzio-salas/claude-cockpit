from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

from claude_cockpit.usage import Severity, compact_duration, parse_usage, reset_countdown

NY = ZoneInfo("America/New_York")

# Claude Code separates the date and the time by a comma here and by ` at ` elsewhere;
# both wordings are in use.
SAMPLE = """You are currently using your subscription to power your Claude Code usage

Current session: 12% used · resets Oct 5, 2:45pm (America/New_York)
Current week (all models): 34% used · resets Oct 8, 9am (America/New_York)
Current week (Fable): 5% used · resets Oct 8, 9am (America/New_York)

What's contributing to your limits usage?
"""

NOW = datetime(2026, 10, 5, 12, 0, tzinfo=NY)


def test_parses_the_real_sample():
    meters = parse_usage(SAMPLE, NOW)
    assert [m.label for m in meters] == ["SESSION", "WEEK", "WEEK · FABLE"]
    assert [m.percent_used for m in meters] == [12, 34, 5]
    assert meters[0].reset_at == datetime(2026, 10, 5, 14, 45, tzinfo=NY)
    assert meters[1].reset_at == datetime(2026, 10, 8, 9, 0, tzinfo=NY)


def test_accepts_the_at_separator_too():
    """The other wording in use, which needs its countdown just as much."""
    meters = parse_usage(
        "Current session: 12% used · resets Oct 5 at 2:45pm (America/New_York)", NOW
    )
    assert meters[0].reset_at == datetime(2026, 10, 5, 14, 45, tzinfo=NY)


def test_time_without_minutes():
    meters = parse_usage(
        "Current session: 1% used · resets Oct 8, 9am (America/New_York)", NOW
    )
    assert meters[0].reset_at == datetime(2026, 10, 8, 9, 0, tzinfo=NY)


def test_midnight_and_noon():
    meters = parse_usage(
        "Current session: 1% used · resets Oct 8, 12am (America/New_York)\n"
        "Current week (all models): 1% used · resets Oct 8, 12pm (America/New_York)",
        NOW,
    )
    assert meters[0].reset_at == datetime(2026, 10, 8, 0, 0, tzinfo=NY)
    assert meters[1].reset_at == datetime(2026, 10, 8, 12, 0, tzinfo=NY)


def test_unparseable_reset_is_kept_verbatim():
    meters = parse_usage("Current session: 12% used · resets soonish", NOW)
    assert meters[0].reset_at is None
    assert meters[0].reset_text == "soonish"
    assert reset_countdown(meters[0], NOW) == "resets soonish"


def test_unknown_zone_is_not_guessed():
    meters = parse_usage(
        "Current session: 12% used · resets Oct 8, 9am (Mars/Olympus)", NOW
    )
    assert meters[0].reset_at is None


def test_a_new_row_appears_without_a_code_change():
    meters = parse_usage(
        "Current month (opus): 7% used · resets Nov 1, 9am (America/New_York)", NOW
    )
    assert meters[0].label == "MONTH (OPUS)"
    assert meters[0].percent_used == 7


def test_output_with_no_usage_lines():
    assert parse_usage("Signed out. Run /login.", NOW) == []


def test_year_rollover():
    """A January reset read in December belongs to next year, not this one."""
    december = datetime(2026, 12, 28, 10, 0, tzinfo=NY)
    meters = parse_usage(
        "Current week (all models): 50% used · resets Jan 2, 9am (America/New_York)",
        december,
    )
    assert meters[0].reset_at == datetime(2027, 1, 2, 9, 0, tzinfo=NY)


def test_percent_is_clamped():
    meters = parse_usage("Current session: 140% used · resets Oct 8, 9am (America/New_York)", NOW)
    assert meters[0].percent_used == 100


@pytest.mark.parametrize(
    "percent,expected",
    [(0, Severity.NORMAL), (69, Severity.NORMAL), (70, Severity.ELEVATED),
     (89, Severity.ELEVATED), (90, Severity.CRITICAL), (100, Severity.CRITICAL)],
)
def test_severity_boundaries(percent, expected):
    meters = parse_usage(
        f"Current session: {percent}% used · resets Oct 8, 9am (America/New_York)", NOW
    )
    assert meters[0].severity is expected


@pytest.mark.parametrize(
    "delta,expected",
    [
        (timedelta(days=2, hours=5), "2d 5h"),
        (timedelta(hours=3, minutes=12), "3h 12m"),
        (timedelta(minutes=12), "12m"),
        (timedelta(seconds=30), "<1m"),
        (timedelta(0), "<1m"),
    ],
)
def test_compact_duration(delta, expected):
    assert compact_duration(delta) == expected


def test_countdown_past_reset():
    meters = parse_usage(
        "Current session: 12% used · resets Oct 5, 2:45pm (America/New_York)", NOW
    )
    after = datetime(2026, 10, 5, 15, 0, tzinfo=NY)
    assert reset_countdown(meters[0], after) == "resets now"


def test_countdown_is_timezone_independent():
    """The meter's zone is the CLI's; the countdown is just a difference."""
    meters = parse_usage(
        "Current session: 12% used · resets Oct 5, 2:45pm (America/New_York)", NOW
    )
    in_utc = datetime(2026, 10, 5, 16, 45, tzinfo=timezone.utc)  # 12:45 in New York
    assert reset_countdown(meters[0], in_utc) == "resets in 2h 0m"
