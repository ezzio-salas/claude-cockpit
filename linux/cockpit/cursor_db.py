"""How much the Cursor agent has been used on this machine.

A port of `CockpitCore/CursorActivity.swift`. Cursor keeps the same database at the same
path on Linux, so only the SQLite binding differs.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

WEEK = timedelta(days=7)

#: Rows with source `human` are code the user typed, tracked for comparison.
_REQUEST_COUNT = """
SELECT count(DISTINCT requestId) FROM ai_code_hashes
WHERE source != 'human' AND createdAt >= ?
"""
_TOP_MODEL = """
SELECT model FROM ai_code_hashes
WHERE source != 'human' AND model IS NOT NULL AND createdAt >= ?
GROUP BY model ORDER BY count(DISTINCT requestId) DESC, model LIMIT 1
"""


def default_database() -> Path:
    return Path.home() / ".cursor/ai-tracking/ai-code-tracking.db"


@dataclass(frozen=True)
class CursorActivity:
    #: Agent requests since local midnight that produced code.
    requests_today: int
    requests_last_7_days: int
    #: The model behind the most requests in the last 7 days; None when there were none.
    top_model: str | None


class CursorActivityReader:
    """Reads `CursorActivity` from the database Cursor keeps for attributing code to AI.

    The database is opened read-only; nothing is sent anywhere. `read` blocks, so callers
    run it off the UI thread.
    """

    def __init__(self, database: Path | None = None) -> None:
        self._database = database or default_database()

    def read(self, now: datetime) -> CursorActivity | None:
        """Returns None when the database does not exist, which means Cursor is not in use here."""
        path = self._database.expanduser()
        if not path.is_file():
            return None

        start_of_today = now.astimezone().replace(
            hour=0, minute=0, second=0, microsecond=0
        )
        week_ago = now - WEEK

        uri = f"file:{path}?mode=ro"
        # Cursor writes to this database while it runs; wait briefly rather than fail on
        # a momentary lock.
        connection = sqlite3.connect(uri, uri=True, timeout=1.0)
        try:
            return CursorActivity(
                requests_today=self._first(connection, _REQUEST_COUNT, start_of_today) or 0,
                requests_last_7_days=self._first(connection, _REQUEST_COUNT, week_ago) or 0,
                top_model=self._first(connection, _TOP_MODEL, week_ago),
            )
        finally:
            connection.close()

    @staticmethod
    def _first(connection: sqlite3.Connection, sql: str, since: datetime):
        """Runs `sql` with `since` bound as its one parameter, in the database's milliseconds."""
        cursor = connection.execute(sql, (int(since.timestamp() * 1000),))
        try:
            row = cursor.fetchone()
        finally:
            cursor.close()
        return row[0] if row else None
