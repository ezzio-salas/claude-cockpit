"""The XDG base directories this app reads."""

from __future__ import annotations

import os
from pathlib import Path


def config_home() -> Path:
    return _base_directory("XDG_CONFIG_HOME", Path.home() / ".config")


def data_home() -> Path:
    return _base_directory("XDG_DATA_HOME", Path.home() / ".local/share")


def _base_directory(variable: str, fallback: Path) -> Path:
    """The directory `variable` names. The specification says a value that is unset, empty
    or relative is to be ignored, so those give `fallback`."""
    value = os.environ.get(variable, "")
    return Path(value) if os.path.isabs(value) else fallback
