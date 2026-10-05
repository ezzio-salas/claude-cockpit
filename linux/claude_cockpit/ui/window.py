"""The frameless window the card sits in.

A port of `ClaudeCockpit/CockpitPanel.swift`, as far as a portable Linux app can go.

The macOS panel pins itself above every window on every Space and remembers where it was
dragged to. No Wayland protocol lets an ordinary client do either: a client cannot place
its own surface, and only `wlr-layer-shell` -- which not every desktop implements -- grants
an overlay layer. Rather than branch per compositor, this window is an ordinary undecorated
one and leaves placement and stacking to a compositor rule. The README gives the rule for
each desktop.
"""

from __future__ import annotations

from datetime import datetime

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, Gio, Gtk  # noqa: E402

from ..config import Appearance  # noqa: E402
from .card import CockpitCard, Snapshot, palette_css, structural_css  # noqa: E402

#: Matches the macOS window's `CFBundleIdentifier`-derived role, and is what a compositor
#: rule matches on.
WINDOW_TITLE = "Claude Cockpit"


class CockpitWindow(Gtk.ApplicationWindow):
    def __init__(self, application: Gtk.Application, on_click) -> None:
        super().__init__(application=application, title=WINDOW_TITLE)
        self._on_click = on_click

        self.set_decorated(False)
        self.set_resizable(False)
        self.add_css_class("cockpit")

        self._card = CockpitCard()
        self.set_child(self._card)

        self._structural = Gtk.CssProvider()
        self._structural.load_from_data(structural_css())
        self._palette = Gtk.CssProvider()

        display = self.get_display()
        for provider in (self._palette, self._structural):
            Gtk.StyleContext.add_provider_for_display(
                display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )

        self._install_gestures()

    def apply(self, appearance: Appearance) -> None:
        self._palette.load_from_data(palette_css(appearance))
        self._card.apply(appearance)

    def render(self, snapshot: Snapshot, now: datetime) -> None:
        self._card.render(snapshot, now)

    # MARK: - Mouse

    def _install_gestures(self) -> None:
        # Left click anywhere on the card refreshes.
        click = Gtk.GestureClick.new()
        click.set_button(Gdk.BUTTON_PRIMARY)
        click.connect("released", self._on_primary_released)
        self.add_controller(click)

        # Right click opens the menu.
        secondary = Gtk.GestureClick.new()
        secondary.set_button(Gdk.BUTTON_SECONDARY)
        secondary.connect("pressed", self._on_secondary_pressed)
        self.add_controller(secondary)

        self._menu = Gtk.PopoverMenu.new_from_model(_menu_model())
        self._menu.set_parent(self._card)
        self._menu.set_has_arrow(False)
        self._menu.set_halign(Gtk.Align.START)

    def _on_primary_released(self, gesture: Gtk.GestureClick, n_press: int, x, y) -> None:
        if n_press == 1:
            self._on_click()

    def _on_secondary_pressed(self, gesture: Gtk.GestureClick, n_press: int, x, y) -> None:
        self._menu.set_pointing_to(Gdk.Rectangle(x=int(x), y=int(y), width=1, height=1))
        self._menu.popup()


def _menu_model() -> Gio.Menu:
    menu = Gio.Menu()
    menu.append("Refresh", "app.refresh")
    menu.append("Customize…", "app.customize")
    section = Gio.Menu()
    section.append("Quit Claude Cockpit", "app.quit")
    menu.append_section(None, section)
    return menu
