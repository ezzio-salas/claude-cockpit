"""Polls Claude for usage and cost and Cursor for activity, and keeps the card showing
the latest good readings.

A port of `ClaudeCockpit/AppDelegate.swift`. The state machine is identical: a reading is
kept until a better one arrives, failures dim it rather than replacing it, and the widget
never shows a number it did not read.
"""

from __future__ import annotations

import logging
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import datetime, timezone

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gio, GLib, Gtk  # noqa: E402

from .config import Settings, SettingsStore  # noqa: E402
from .cost import ClaudeCost, ClaudeCostEstimator  # noqa: E402
from .cursor_db import CursorActivity, CursorActivityReader  # noqa: E402
from .cursor_usage import CursorUsage, CursorUsageFetcher  # noqa: E402
from .fetcher import FetchError, FetchErrorKind, UsageFetcher, message_for  # noqa: E402
from .ui.card import Snapshot  # noqa: E402
from .ui.customize import CustomizeWindow  # noqa: E402
from .ui.window import CockpitWindow  # noqa: E402
from .usage import compact_duration, parse_usage  # noqa: E402

log = logging.getLogger(__name__)

APP_ID = "dev.ezzio.ClaudeCockpit"
REFRESH_INTERVAL = 60
#: Countdowns and the stale age move on without a fetch.
REDRAW_INTERVAL = 30
#: Cursor's plan usage moves slowly and costs a start of its CLI to read, so the timer
#: reads it less often than Claude's. A click reads it at once.
CURSOR_USAGE_INTERVAL = 300


class CockpitApplication(Gtk.Application):
    """Owns the state and the timers. A second launch raises the first window instead of
    starting another poller, which the macOS app leaves to the user."""

    def __init__(self, store: SettingsStore | None = None) -> None:
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)
        self._store = store or SettingsStore()
        self._settings: Settings = self._store.load()

        self._fetcher = UsageFetcher(command=self._settings.cli_command)
        self._estimator = ClaudeCostEstimator(self._settings.transcripts_directory)
        self._cursor_reader = CursorActivityReader()
        self._cursor_usage_fetcher = CursorUsageFetcher(command=self._settings.cursor_command)

        self._window: CockpitWindow | None = None
        self._customize: CustomizeWindow | None = None

        #: The last good reading and when it was taken; None until the first success.
        self._reading: tuple[list, datetime] | None = None
        #: Why the most recent fetch failed; None after a success.
        self._failure: str | None = None
        self._claude_cost: ClaudeCost | None = None
        self._cursor: CursorActivity | None = None
        #: The last good reading of Cursor's plan usage and when it was taken.
        self._cursor_usage: tuple[CursorUsage, datetime] | None = None
        #: Whether the most recent read of it failed, which marks the reading stale.
        self._cursor_usage_failed = False
        #: When the timer next reads it, on the monotonic clock.
        self._cursor_usage_due = 0.0
        self._is_fetching = False

    # MARK: - Lifecycle

    def do_startup(self) -> None:
        Gtk.Application.do_startup(self)
        for name, handler in (
            ("refresh", lambda *_: self.refresh_everything()),
            ("customize", lambda *_: self.show_customize()),
            ("quit", lambda *_: self.quit()),
        ):
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", handler)
            self.add_action(action)

    def do_activate(self) -> None:
        if self._window is None:
            self._window = CockpitWindow(
                application=self,
                on_click=self.refresh_everything,
            )
            self._window.apply(self._settings.appearance)
            self.refresh()
            GLib.timeout_add_seconds(REFRESH_INTERVAL, self._on_refresh_tick)
            GLib.timeout_add_seconds(REDRAW_INTERVAL, self._on_redraw_tick)
            self._offer_customize_on_first_launch()
        self._window.present()

    def _on_refresh_tick(self) -> bool:
        self.refresh()
        return GLib.SOURCE_CONTINUE

    def _on_redraw_tick(self) -> bool:
        self.render()
        return GLib.SOURCE_CONTINUE

    # MARK: - Personalization

    def _offer_customize_on_first_launch(self) -> None:
        """The first launch offers personalization once; afterwards it is reached from the menu."""
        if self._settings.has_offered_customization:
            return
        self._settings = replace(self._settings, has_offered_customization=True)
        self._store.save(self._settings)
        self.show_customize()

    def show_customize(self) -> None:
        if self._customize is None:
            self._customize = CustomizeWindow(
                application=self,
                settings=self._settings,
                store=self._store,
                on_change=self._apply_appearance,
            )
            self._customize.connect("close-request", self._on_customize_closed)
        self._customize.present()

    def _on_customize_closed(self, *_args) -> bool:
        self._customize = None
        return False

    def _apply_appearance(self, settings: Settings) -> None:
        self._settings = settings
        if self._window is not None:
            self._window.apply(settings.appearance)
        self.render()

    # MARK: - Refresh

    def refresh_everything(self) -> None:
        """A refresh the person asked for, which reads Cursor's plan usage too."""
        self._cursor_usage_due = 0.0
        self.refresh()

    def refresh(self) -> None:
        """Starts a poll unless one is already running. Returns immediately."""
        if self._is_fetching:
            return
        self._is_fetching = True
        self.render()

        reads_cursor_usage = time.monotonic() >= self._cursor_usage_due
        if reads_cursor_usage:
            self._cursor_usage_due = time.monotonic() + CURSOR_USAGE_INTERVAL
        threading.Thread(
            target=self._poll, args=(reads_cursor_usage,), name="cockpit-poll", daemon=True
        ).start()

    def _poll(self, reads_cursor_usage: bool) -> None:
        """Runs off the UI thread. Every result goes back through `GLib.idle_add`.

        The reads run side by side, as they do on macOS, and none of them can raise:
        a poll that died here would never reach `_finish_poll`, and the card would show
        SYNC and refuse every later refresh.
        """
        now = datetime.now(timezone.utc)
        with ThreadPoolExecutor(max_workers=3, thread_name_prefix="cockpit-read") as pool:
            cost = pool.submit(self._estimate_cost, now)
            cursor = pool.submit(self._read_cursor, now)
            cursor_usage = pool.submit(self._fetch_cursor_usage, reads_cursor_usage)
            usage, failure = self._fetch_usage()
        GLib.idle_add(
            self._finish_poll,
            usage,
            failure,
            cost.result(),
            cursor.result(),
            cursor_usage.result(),
            now,
        )

    def _fetch_usage(self) -> tuple[str | None, str | None]:
        """The CLI's output, or the message to show in its place."""
        try:
            return self._fetcher.fetch(), None
        except FetchError as error:
            log.error("Usage fetch failed: %s %s", error.kind.value, error.detail.strip()[:400])
            return None, message_for(error)
        except Exception:
            log.exception("Usage fetch failed unexpectedly")
            return None, "COULD NOT READ USAGE"

    def _estimate_cost(self, now: datetime) -> ClaudeCost | None:
        try:
            return self._estimator.estimate(now)
        except Exception as error:
            log.error("Cost estimate failed: %r", error)
            return None

    def _read_cursor(self, now: datetime) -> CursorActivity | None:
        try:
            return self._cursor_reader.read(now)
        except Exception as error:  # sqlite3 raises several unrelated types.
            log.error("Cursor activity read failed: %r", error)
            return None

    def _fetch_cursor_usage(self, is_due: bool) -> CursorUsage | FetchError | None:
        """The plan usage, why it could not be read, or None when this poll does not read it."""
        if not is_due:
            return None
        try:
            return self._cursor_usage_fetcher.fetch()
        except FetchError as error:
            # No Cursor CLI is the ordinary case of a machine without Cursor, not a fault.
            if error.kind is not FetchErrorKind.CLI_NOT_FOUND:
                log.error(
                    "Cursor usage fetch failed: %s %s", error.kind.value, error.detail.strip()[-400:]
                )
            return error
        except Exception as error:
            log.exception("Cursor usage fetch failed unexpectedly")
            return FetchError(FetchErrorKind.FAILED, repr(error))

    def _finish_poll(
        self,
        usage: str | None,
        failure: str | None,
        cost: ClaudeCost | None,
        cursor: CursorActivity | None,
        cursor_usage: CursorUsage | FetchError | None,
        now: datetime,
    ) -> bool:
        self._log_unpriced(cost)
        self._claude_cost = cost
        self._cursor = cursor
        self._record_cursor_usage(cursor_usage, now)
        self._is_fetching = False

        if usage is None:
            self._failure = failure
        else:
            meters = parse_usage(usage, now)
            if meters:
                self._reading = (meters, now)
                self._failure = None
            else:
                self._failure = "UNRECOGNIZED OUTPUT"
                log.error("No usage lines in CLI output: %s", usage.strip()[:400])

        self.render()
        return GLib.SOURCE_REMOVE

    def _record_cursor_usage(
        self, result: CursorUsage | FetchError | None, now: datetime
    ) -> None:
        if isinstance(result, CursorUsage):
            self._cursor_usage = (result, now)
            self._cursor_usage_failed = False
        elif result is not None and result.kind is FetchErrorKind.CLI_NOT_FOUND:
            self._cursor_usage = None
            self._cursor_usage_failed = False
        elif result is not None:
            self._cursor_usage_failed = True

    def _log_unpriced(self, cost: ClaudeCost | None) -> None:
        if cost is None:
            return
        unpriced = cost.last_7_days.unpriced_models
        known = self._claude_cost.last_7_days.unpriced_models if self._claude_cost else ()
        if unpriced and unpriced != known:
            log.warning(
                "Cost estimate omits models with no known price: %s", ", ".join(unpriced)
            )

    # MARK: - Render

    def render(self) -> None:
        if self._window is None:
            return
        now = datetime.now(timezone.utc)
        is_stale = self._reading is not None and self._failure is not None

        if self._is_fetching:
            status = "SYNC"
        elif is_stale and self._reading is not None:
            status = f"STALE · {compact_duration(now - self._reading[1])}"
        else:
            status = ""

        is_cursor_stale = self._cursor_usage is not None and self._cursor_usage_failed
        if self._cursor_usage is None:
            cursor_note = ""
        elif is_cursor_stale:
            cursor_note = f"STALE · {compact_duration(now - self._cursor_usage[1])}"
        elif self._cursor_usage[0].resets:
            cursor_note = f"RESETS {self._cursor_usage[0].resets.upper()}"
        else:
            cursor_note = ""

        self._window.render(
            Snapshot(
                meters=self._reading[0] if self._reading else None,
                message=self._failure or "READING USAGE",
                status=status,
                is_stale=is_stale,
                claude_cost=self._claude_cost,
                cursor_usage=self._cursor_usage[0] if self._cursor_usage else None,
                cursor_note=cursor_note,
                is_cursor_stale=is_cursor_stale,
                cursor=self._cursor,
            ),
            now,
        )
