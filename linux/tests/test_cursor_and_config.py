import sqlite3
from datetime import datetime, timedelta, timezone

import pytest

from cockpit.config import Appearance, Settings, SettingsStore, normalize_hex, normalize_title
from cockpit.cursor_db import CursorActivityReader

NOW = datetime(2026, 10, 5, 18, 0, tzinfo=timezone.utc)


# --- Cursor --------------------------------------------------------------


def make_database(path, rows):
    connection = sqlite3.connect(path)
    connection.execute(
        "CREATE TABLE ai_code_hashes (requestId TEXT, source TEXT, model TEXT, createdAt INTEGER)"
    )
    connection.executemany("INSERT INTO ai_code_hashes VALUES (?, ?, ?, ?)", rows)
    connection.commit()
    connection.close()
    return path


def millis(when):
    return int(when.timestamp() * 1000)


def test_returns_none_when_cursor_is_not_installed(tmp_path):
    assert CursorActivityReader(tmp_path / "absent.db").read(NOW) is None


def test_counts_distinct_requests_excluding_human_edits(tmp_path):
    two_days_ago = NOW - timedelta(days=2)
    path = make_database(tmp_path / "c.db", [
        ("r1", "agent", "composer-2.5", millis(NOW)),
        ("r1", "agent", "composer-2.5", millis(NOW)),       # same request, two hashes
        ("r2", "agent", "composer-2.5", millis(two_days_ago)),
        ("r3", "human", "composer-2.5", millis(NOW)),        # typed by the user
        ("r4", "agent", "composer-2.5", millis(NOW - timedelta(days=30))),  # outside the week
    ])
    activity = CursorActivityReader(path).read(NOW)
    assert activity.requests_today == 1
    assert activity.requests_last_7_days == 2
    assert activity.top_model == "composer-2.5"


def test_top_model_breaks_ties_by_name(tmp_path):
    path = make_database(tmp_path / "c.db", [
        ("r1", "agent", "beta", millis(NOW)),
        ("r2", "agent", "alpha", millis(NOW)),
    ])
    assert CursorActivityReader(path).read(NOW).top_model == "alpha"


def test_no_activity_at_all(tmp_path):
    path = make_database(tmp_path / "c.db", [])
    activity = CursorActivityReader(path).read(NOW)
    assert (activity.requests_today, activity.requests_last_7_days, activity.top_model) == (0, 0, None)


def test_a_database_without_the_table_raises(tmp_path):
    path = tmp_path / "c.db"
    sqlite3.connect(path).close()
    with pytest.raises(sqlite3.DatabaseError):
        CursorActivityReader(path).read(NOW)


# --- config --------------------------------------------------------------


@pytest.mark.parametrize(
    "raw,expected",
    [("#4FE8FF", "#4FE8FF"), ("4fe8ff", "#4FE8FF"), ("  #b6ff5c  ", "#B6FF5C"),
     ("nonsense", "#4FE8FF"), ("", "#4FE8FF"), (None, "#4FE8FF"), (42, "#4FE8FF")],
)
def test_normalize_hex(raw, expected):
    assert normalize_hex(raw) == expected


@pytest.mark.parametrize(
    "raw,expected",
    [("work", "WORK"), ("  work  ", "WORK"), ("", "CLAUDE"), ("   ", "CLAUDE"),
     (None, "CLAUDE"), ("a very long title indeed", "A VERY LONG TI")],
)
def test_normalize_title(raw, expected):
    assert normalize_title(raw) == expected


def test_defaults_when_there_is_no_config_file(tmp_path):
    settings = SettingsStore(tmp_path / "config.toml").load()
    assert settings.appearance == Appearance()
    assert settings.cli_command == "claude"
    assert settings.transcripts_directory is None
    assert settings.has_offered_customization is False


def test_round_trip(tmp_path):
    store = SettingsStore(tmp_path / "config.toml")
    written = Settings(
        appearance=Appearance(title="WORK", accent="#B6FF5C", border="#FF4FD8", glow="#FF9A3D"),
        cli_command="claude-work",
        transcripts_directory=tmp_path / "projects",
        has_offered_customization=True,
    )
    store.save(written)
    assert store.load() == written


def test_a_malformed_file_falls_back_to_defaults(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text("this is not = valid = toml [[[")
    assert SettingsStore(path).load().appearance == Appearance()


def test_unreadable_colors_fall_back_individually(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text('accent_color = "zzz"\nborder_color = "#112233"\n')
    appearance = SettingsStore(path).load().appearance
    assert appearance.accent == "#4FE8FF"
    assert appearance.border == "#112233"


def test_reset_restores_the_defaults_but_keeps_the_rest(tmp_path):
    store = SettingsStore(tmp_path / "config.toml")
    settings = Settings(
        appearance=Appearance(title="WORK", accent="#B6FF5C", border="#B6FF5C", glow="#B6FF5C"),
        cli_command="claude-work",
        has_offered_customization=True,
    )
    store.save(settings)
    restored = store.reset_appearance(settings)
    assert restored.appearance == Appearance()
    assert restored.cli_command == "claude-work"
    assert store.load().cli_command == "claude-work"


def test_a_title_with_a_quote_survives_the_round_trip(tmp_path):
    store = SettingsStore(tmp_path / "config.toml")
    store.save(Settings(appearance=Appearance(title='SAY "HI"')))
    assert store.load().appearance.title == 'SAY "HI"'
