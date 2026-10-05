"""The parts of the widget's look a person can make their own, and where they are kept.

A port of `CockpitCore/CockpitAppearance.swift`. macOS keeps these in user defaults, which
`defaults write` can also reach; the equivalent here is a small TOML file a person can edit
by hand, at `$XDG_CONFIG_HOME/claude-cockpit/config.toml`.
"""

from __future__ import annotations

import logging
import re
import tomllib
from dataclasses import dataclass, replace
from pathlib import Path

from .xdg import config_home

log = logging.getLogger(__name__)

DEFAULT_TITLE = "CLAUDE"
#: The longest title that leaves room for the status note beside it.
MAXIMUM_TITLE_LENGTH = 14
#: The widget's standard accent.
COCKPIT_CYAN = "#4FE8FF"

_HEX = re.compile(r"#?([0-9A-Fa-f]{6})")


def config_path() -> Path:
    return config_home() / "claude-cockpit/config.toml"


def normalize_hex(raw: object, fallback: str = COCKPIT_CYAN) -> str:
    """`#RRGGBB` in capitals; the fallback for anything unreadable."""
    if not isinstance(raw, str):
        return fallback
    match = _HEX.fullmatch(raw.strip())
    return f"#{match.group(1).upper()}" if match else fallback


def normalize_title(raw: object) -> str:
    """Titles are shown like every other label: trimmed and in capitals. Blank means the default."""
    if not isinstance(raw, str):
        return DEFAULT_TITLE
    trimmed = raw.strip()
    if not trimmed:
        return DEFAULT_TITLE
    return trimmed.upper()[:MAXIMUM_TITLE_LENGTH].strip()


@dataclass(frozen=True)
class Appearance:
    title: str = DEFAULT_TITLE
    #: Colors the section titles, the figures, and meters below the warning levels.
    accent: str = COCKPIT_CYAN
    border: str = COCKPIT_CYAN
    glow: str = COCKPIT_CYAN

    @staticmethod
    def from_mapping(values: dict) -> "Appearance":
        return Appearance(
            title=normalize_title(values.get("title")),
            accent=normalize_hex(values.get("accent_color")),
            border=normalize_hex(values.get("border_color")),
            glow=normalize_hex(values.get("glow_color")),
        )


@dataclass(frozen=True)
class Settings:
    """Everything the config file can carry."""

    appearance: Appearance = Appearance()
    #: The CLI to run: a command name such as `claude`, or a path to an executable.
    cli_command: str = "claude"
    #: Where Claude Code keeps its transcripts, for a profile with its own config directory.
    transcripts_directory: Path | None = None
    #: The Cursor CLI to read plan usage from: a command name or a path to an executable.
    cursor_command: str = "cursor-agent"
    #: Whether the person has already been shown the personalize window once.
    has_offered_customization: bool = False


class SettingsStore:
    """Reads and writes the TOML config, falling back to defaults for anything unreadable."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or config_path()

    def load(self) -> Settings:
        values = self._read()

        command = _command(values.get("cli_command"), Settings.cli_command)

        transcripts = values.get("transcripts_directory")
        transcripts = (
            Path(transcripts).expanduser()
            if isinstance(transcripts, str) and transcripts.strip()
            else None
        )

        return Settings(
            appearance=Appearance.from_mapping(values),
            cli_command=command,
            transcripts_directory=transcripts,
            cursor_command=_command(values.get("cursor_command"), Settings.cursor_command),
            has_offered_customization=bool(values.get("has_offered_customization")),
        )

    def save(self, settings: Settings) -> None:
        """Rewrites the whole file. It only ever holds these keys, so nothing is lost."""
        appearance = settings.appearance
        lines = [
            "# Claude Cockpit — edit by hand or through right-click → Customize…",
            "",
            f"title = {_quote(appearance.title)}",
            f"accent_color = {_quote(appearance.accent)}",
            f"border_color = {_quote(appearance.border)}",
            f"glow_color = {_quote(appearance.glow)}",
            "",
            f"cli_command = {_quote(settings.cli_command)}",
        ]
        if settings.transcripts_directory is not None:
            lines.append(f"transcripts_directory = {_quote(str(settings.transcripts_directory))}")
        lines.append(f"cursor_command = {_quote(settings.cursor_command)}")
        lines.append("")
        lines.append(f"has_offered_customization = {str(settings.has_offered_customization).lower()}")
        lines.append("")

        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            # Write beside the target and rename, so a crash never leaves a half-written config.
            temporary = self.path.with_suffix(".toml.tmp")
            temporary.write_text("\n".join(lines), encoding="utf-8")
            temporary.replace(self.path)
        except OSError as error:
            log.error("Could not save settings to %s: %s", self.path, error)

    def reset_appearance(self, settings: Settings) -> Settings:
        restored = replace(settings, appearance=Appearance())
        self.save(restored)
        return restored

    def _read(self) -> dict:
        try:
            with self.path.open("rb") as handle:
                return tomllib.load(handle)
        except FileNotFoundError:
            return {}
        except (OSError, tomllib.TOMLDecodeError) as error:
            log.error("Could not read %s, using defaults: %s", self.path, error)
            return {}


def _command(raw: object, fallback: str) -> str:
    return raw.strip() if isinstance(raw, str) and raw.strip() else fallback


#: The characters a TOML basic string cannot hold as they are.
_ESCAPES = {
    **{chr(code): f"\\u{code:04X}" for code in (*range(0x20), 0x7F)},
    '"': '\\"',
    "\\": "\\\\",
}


def _quote(value: str) -> str:
    """`value` as a TOML basic string."""
    return '"' + "".join(_ESCAPES.get(character, character) for character in value) + '"'
