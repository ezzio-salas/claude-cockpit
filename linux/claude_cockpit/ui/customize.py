"""The Personalize window.

A port of `ClaudeCockpit/CustomizationWindowController.swift`. Not modal, so the card keeps
refreshing behind it, and every change is saved and applied immediately.
"""

from __future__ import annotations

from dataclasses import replace

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, Gtk  # noqa: E402

from ..config import (  # noqa: E402
    MAXIMUM_TITLE_LENGTH,
    Appearance,
    Settings,
    SettingsStore,
    normalize_title,
)


class CustomizeWindow(Gtk.ApplicationWindow):
    def __init__(
        self,
        application: Gtk.Application,
        settings: Settings,
        store: SettingsStore,
        on_change,
    ) -> None:
        super().__init__(application=application, title="Personalize Claude Cockpit")
        self._settings = settings
        self._store = store
        self._on_change = on_change
        #: Set while fields are being repopulated, so programmatic changes do not save.
        self._loading = False

        self.set_default_size(380, -1)
        self.set_resizable(False)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        content.set_margin_top(20)
        content.set_margin_bottom(20)
        content.set_margin_start(20)
        content.set_margin_end(20)
        self.set_child(content)

        grid = Gtk.Grid(column_spacing=14, row_spacing=12)
        content.append(grid)

        self._title_entry = Gtk.Entry()
        self._title_entry.set_max_length(MAXIMUM_TITLE_LENGTH)
        self._title_entry.set_placeholder_text("CLAUDE")
        self._title_entry.set_hexpand(True)
        self._title_entry.connect("changed", self._on_changed)
        _add_row(grid, 0, "Title", self._title_entry)

        self._accent = _color_button(self._on_changed)
        self._border = _color_button(self._on_changed)
        self._glow = _color_button(self._on_changed)
        _add_row(grid, 1, "Text color", self._accent)
        _add_row(grid, 2, "Border color", self._border)
        _add_row(grid, 3, "Glow color", self._glow)

        note = Gtk.Label(
            label="Meters at 70% and above stay amber and red whatever text color "
            "you pick, because there the color is the warning."
        )
        note.set_wrap(True)
        note.set_xalign(0)
        note.add_css_class("dim-label")
        content.append(note)

        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        buttons.set_halign(Gtk.Align.END)
        reset = Gtk.Button(label="Reset to Defaults")
        reset.connect("clicked", self._on_reset)
        done = Gtk.Button(label="Done")
        done.add_css_class("suggested-action")
        done.connect("clicked", lambda *_: self.close())
        buttons.append(reset)
        buttons.append(done)
        content.append(buttons)

        self._load(settings.appearance)

    def _load(self, appearance: Appearance) -> None:
        self._loading = True
        try:
            self._title_entry.set_text(
                "" if appearance.title == Appearance().title else appearance.title
            )
            for button, hex_color in (
                (self._accent, appearance.accent),
                (self._border, appearance.border),
                (self._glow, appearance.glow),
            ):
                rgba = Gdk.RGBA()
                rgba.parse(hex_color)
                button.set_rgba(rgba)
        finally:
            self._loading = False

    def _on_changed(self, *_args) -> None:
        if self._loading:
            return
        appearance = Appearance(
            title=normalize_title(self._title_entry.get_text()),
            accent=_hex(self._accent),
            border=_hex(self._border),
            glow=_hex(self._glow),
        )
        self._settings = replace(self._settings, appearance=appearance)
        self._store.save(self._settings)
        self._on_change(self._settings)

    def _on_reset(self, *_args) -> None:
        self._settings = self._store.reset_appearance(self._settings)
        self._load(self._settings.appearance)
        self._on_change(self._settings)


def _add_row(grid: Gtk.Grid, row: int, name: str, control: Gtk.Widget) -> None:
    label = Gtk.Label(label=name)
    label.set_xalign(1)
    grid.attach(label, 0, row, 1, 1)
    grid.attach(control, 1, row, 1, 1)


def _color_button(on_changed) -> Gtk.ColorButton:
    button = Gtk.ColorButton()
    button.set_use_alpha(False)
    button.set_halign(Gtk.Align.START)
    button.connect("color-set", on_changed)
    return button


def _hex(button: Gtk.ColorButton) -> str:
    rgba = button.get_rgba()
    return "#{:02X}{:02X}{:02X}".format(
        round(rgba.red * 255), round(rgba.green * 255), round(rgba.blue * 255)
    )
