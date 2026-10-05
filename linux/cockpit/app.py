"""Polls Claude for usage and cost and Cursor for activity, and keeps the card showing
the latest good readings.

A port of `ClaudeCockpit/AppDelegate.swift`. The state machine is identical: a reading is
kept until a better one arrives, failures dim it rather than replacing it, and the widget
never shows a number it did not read.
"""

from __future__ import annotations

import logging
import threading
from datetime import datetime, timezone

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gio, GLib, Gtk  # noqa: E402

from .config import Settings, SettingsStore  # noqa: E402
from .cost import ClaudeCost, ClaudeCostEstimator  # noqa: E402
from .cursor_db import CursorActivity, CursorActivityReader  # noqa: E402
from .fetcher import FetchError, UsageFetcher, message_for  # noqa: E402
from .ui.card import Snapshot  # noqa: E402
from .ui.customize import CustomizeWindow  # noqa: E402
from .ui.window import CockpitWindow  # noqa: E402
from .usage import compact_duration, parse_usage  # noqa: E402

log = logging.getLogger("cockpit.app")

APP_ID = "dev.ezzio.ClaudeCockpit"
REFRESH_INTERVAL = 60
#: Countdowns and the stale age move on without a fetch.
REDRAW_INTERVAL = 30


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

        self._window: CockpitWindow | None = None
        self._customize: CustomizeWindow | None = None

        #: The last good reading and when it was taken; None until the first success.
        self._reading: tuple[list, datetime] | None = None
        #: Why the most recent fetch failed; None after a success.
        self._failure: str | None = None
        self._claude_cost: ClaudeCost | None = None
        self._cursor: CursorActivity | None = None
        self._is_fetching = False

    # MARK: - Lifecycle

    def do_startup(self) -> None:
        Gtk.Application.do_startup(self)
        for name, handler in (
            ("refresh", lambda *_: self.refresh()),
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
                on_click=self.refresh,
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
        self._settings = Settings(
            appearance=self._settings.appearance,
            cli_command=self._settings.cli_command,
            transcripts_directory=self._settings.transcripts_directory,
            has_offered_customization=True,
        )
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

    def refresh(self) -> None:
        """Starts a poll unless one is already running. Returns immediately."""
        if self._is_fetching:
            return
        self._is_fetching = True
        self.render()
        threading.Thread(target=self._poll, name="cockpit-poll", daemon=True).start()

    def _poll(self) -> None:
        """Runs off the UI thread. Every result goes back through `GLib.idle_add`."""
        now = datetime.now(timezone.utc)

        usage: str | None = None
        failure: str | None = None
        try:
            usage = self._fetcher.fetch()
        except FetchError as error:
            failure = message_for(error)
            log.error("Usage fetch failed: %s %s", error.kind.value, error.detail.strip()[:400])

        try:
            cost = self._estimator.estimate(now)
        except OSError as error:
            log.error("Cost estimate failed: %s", error)
            cost = None

        try:
            cursor = self._cursor_reader.read(now)
        except Exception as error:  # sqlite3 raises several unrelated types.
            log.error("Cursor activity read failed: %s", error)
            cursor = None

        GLib.idle_add(self._finish_poll, usage, failure, cost, cursor, now)

    def _finish_poll(
        self,
        usage: str | None,
        failure: str | None,
        cost: ClaudeCost | None,
        cursor: CursorActivity | None,
        now: datetime,
    ) -> bool:
        self._log_unpriced(cost)
        self._claude_cost = cost
        self._cursor = cursor
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

        self._window.render(
            Snapshot(
                meters=self._reading[0] if self._reading else None,
                message=self._failure or "READING USAGE",
                status=status,
                is_stale=is_stale,
                claude_cost=self._claude_cost,
                cursor=self._cursor,
            ),
            now,
        )
