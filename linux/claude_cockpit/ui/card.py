"""The glass card: everything the widget shows at one moment.

A port of `ClaudeCockpit/CockpitView.swift` and `MeterRowView.swift`. The structure is the
same; the drawing is GTK CSS rather than Core Animation layers.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Pango", "1.0")
from gi.repository import Gtk, Pango  # noqa: E402

from ..config import Appearance  # noqa: E402
from ..cost import ClaudeCost  # noqa: E402
from ..cursor_db import CursorActivity  # noqa: E402
from ..pricing import cost_text  # noqa: E402
from ..usage import Severity, UsageMeter, reset_countdown  # noqa: E402

CARD_WIDTH = 260
#: Warning colors, fixed whatever accent is chosen.
AMBER = "#FFB83D"
RED = "#FF5461"

_SEVERITY_CLASS = {
    Severity.NORMAL: None,
    Severity.ELEVATED: "elevated",
    Severity.CRITICAL: "critical",
}


@dataclass(frozen=True)
class Snapshot:
    """What the widget shows at one moment."""

    #: The meters to draw, or None when `message` takes their place.
    meters: list[UsageMeter] | None
    #: Shown instead of meters when there is no reading yet.
    message: str
    #: Short header note such as `SYNC` or `STALE · 2m`; empty when there is nothing to report.
    status: str
    is_stale: bool
    #: Two rows under the meters; None hides them.
    claude_cost: ClaudeCost | None
    #: Its own section below the Claude rows; None hides the section.
    cursor: CursorActivity | None


def structural_css() -> bytes:
    return (Path(__file__).resolve().parent / "style.css").read_bytes()


def palette_css(appearance: Appearance) -> bytes:
    """The colors a person can change, as GTK color definitions `style.css` refers to."""
    return (
        f"@define-color cockpit_accent {appearance.accent};\n"
        f"@define-color cockpit_border {appearance.border};\n"
        f"@define-color cockpit_glow {appearance.glow};\n"
        f"@define-color cockpit_amber {AMBER};\n"
        f"@define-color cockpit_red {RED};\n"
    ).encode("utf-8")


class CockpitCard(Gtk.Box):
    """The card's content. Rebuilt from a `Snapshot` on every render."""

    def __init__(self) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.add_css_class("cockpit-root")

        self._card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self._card.add_css_class("cockpit-card")
        self._card.set_size_request(CARD_WIDTH, -1)
        self.append(self._card)

        self._title = _label("", "cockpit-section-title")
        self._status = _label("", "cockpit-status")
        self._status.set_halign(Gtk.Align.END)
        self._status.set_hexpand(True)

        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        header.append(self._title)
        header.append(self._status)
        self._card.append(header)

        self._body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self._cost = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=9)
        self._cursor = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=9)
        self._cursor.set_margin_top(6)
        for section in (self._body, self._cost, self._cursor):
            self._card.append(section)

    def apply(self, appearance: Appearance) -> None:
        """Only the title lives in the widget tree; the colors come from the palette provider."""
        self._title.set_text(appearance.title)

    def render(self, snapshot: Snapshot, now: datetime) -> None:
        self._status.set_text(snapshot.status)
        self._status.set_visible(bool(snapshot.status))
        _set_class(self._status, "stale", snapshot.is_stale)

        _clear(self._body)
        if snapshot.meters is None:
            self._body.append(_label(snapshot.message, "cockpit-message", ellipsize=True))
        else:
            for meter in snapshot.meters:
                self._body.append(_meter_row(meter, now))
        _set_class(self._body, "cockpit-stale", snapshot.is_stale)

        _clear(self._cost)
        self._cost.set_visible(snapshot.claude_cost is not None)
        if snapshot.claude_cost is not None:
            for name, window in (
                ("TODAY", snapshot.claude_cost.today),
                ("7 DAYS", snapshot.claude_cost.last_7_days),
            ):
                figure = cost_text(window.dollars, window.is_partial)
                self._cost.append(_stat_row(name, figure, "API EQ"))

        _clear(self._cursor)
        self._cursor.set_visible(snapshot.cursor is not None)
        if snapshot.cursor is not None:
            self._cursor.append(_label("CURSOR", "cockpit-section-title"))
            self._cursor.append(_stat_row("TODAY", *_requests(snapshot.cursor.requests_today)))
            self._cursor.append(
                _stat_row("7 DAYS", *_requests(snapshot.cursor.requests_last_7_days))
            )
            if snapshot.cursor.top_model:
                self._cursor.append(
                    _stat_row("TOP MODEL", snapshot.cursor.top_model.upper(), None, accent=False)
                )


def _meter_row(meter: UsageMeter, now: datetime) -> Gtk.Widget:
    severity = _SEVERITY_CLASS[meter.severity]

    label = _label(meter.label, "cockpit-meter-label")
    percent = _label(f"{meter.percent_used}%", "cockpit-meter-percent")
    percent.set_halign(Gtk.Align.END)
    percent.set_hexpand(True)
    if severity:
        percent.add_css_class(severity)

    head = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
    head.set_valign(Gtk.Align.BASELINE)
    head.append(label)
    head.append(percent)

    bar = Gtk.ProgressBar()
    bar.add_css_class("cockpit-bar")
    bar.set_fraction(min(max(meter.percent_used / 100, 0.0), 1.0))
    if severity:
        bar.add_css_class(severity)

    row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    row.append(head)
    row.append(bar)
    row.append(_label(reset_countdown(meter, now).upper(), "cockpit-meter-reset", ellipsize=True))
    return row


def _stat_row(name: str, figure: str, unit: str | None, accent: bool = True) -> Gtk.Widget:
    value = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
    value.set_halign(Gtk.Align.END)
    value.set_hexpand(True)
    value.set_valign(Gtk.Align.BASELINE)
    value.append(
        _label(figure, "cockpit-stat-figure" if accent else "cockpit-stat-plain", ellipsize=not accent)
    )
    if unit:
        value.append(_label(unit, "cockpit-stat-unit"))

    row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
    row.set_valign(Gtk.Align.BASELINE)
    row.append(_label(name, "cockpit-stat-label"))
    row.append(value)
    return row


def _requests(count: int) -> tuple[str, str]:
    return str(count), "REQUEST" if count == 1 else "REQUESTS"


def _label(text: str, css_class: str, ellipsize: bool = False) -> Gtk.Label:
    """Labels size to their text. Only the few that can run past the card -- a model name,
    an unrecognized reset string -- are allowed to ellipsize, so the card keeps its width."""
    label = Gtk.Label(label=text)
    label.set_xalign(0)
    label.set_single_line_mode(True)
    if ellipsize:
        label.set_ellipsize(Pango.EllipsizeMode.END)
    label.add_css_class(css_class)
    return label


def _set_class(widget: Gtk.Widget, css_class: str, present: bool) -> None:
    if present:
        widget.add_css_class(css_class)
    else:
        widget.remove_css_class(css_class)


def _clear(box: Gtk.Box) -> None:
    child = box.get_first_child()
    while child is not None:
        following = child.get_next_sibling()
        box.remove(child)
        child = following
