import time
from datetime import datetime, timezone

import pytest

from claude_cockpit.periods import start_of_today


@pytest.fixture
def new_york(monkeypatch):
    monkeypatch.setenv("TZ", "America/New_York")
    time.tzset()
    yield
    monkeypatch.undo()
    time.tzset()


def utc(*when):
    return datetime(*when, tzinfo=timezone.utc)


def test_an_ordinary_day(new_york):
    assert start_of_today(utc(2026, 10, 5, 18, 0)) == utc(2026, 10, 5, 4, 0)


def test_the_day_the_clocks_go_back(new_york):
    """Midnight was at UTC-4; by the afternoon the offset is UTC-5."""
    assert start_of_today(utc(2026, 11, 1, 20, 0)) == utc(2026, 11, 1, 4, 0)


def test_the_day_the_clocks_go_forward(new_york):
    """Midnight was at UTC-5; by the afternoon the offset is UTC-4."""
    assert start_of_today(utc(2026, 3, 8, 20, 0)) == utc(2026, 3, 8, 5, 0)
