"""Registers the bundled Orbitron font for this process only.

The macOS app calls `CTFontManagerRegisterFontsForURL` with `.process` scope. The
equivalent here is fontconfig's application font list, which Pango reads through the same
`FcConfig`. If that fails -- an unusual fontconfig build, a missing file -- the card falls
back to a monospace font, exactly as the macOS app does.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import logging
from pathlib import Path

log = logging.getLogger(__name__)

#: What the card falls back to when Orbitron could not be registered.
FALLBACK_FAMILY = "monospace"


def bundled_font() -> Path | None:
    """The Orbitron file to register, or None if neither copy is there.

    Installed, it sits beside this module -- in the repository that path is a symlink to
    `assets/Orbitron.ttf`, the one copy the macOS build uses too, which the wheel resolves
    into a real file. The repository path is tried as well so a source checkout works even
    where symlinks do not.
    """
    here = Path(__file__).resolve()
    for candidate in (here.parent / "Orbitron.ttf", here.parents[3] / "assets/Orbitron.ttf"):
        if candidate.is_file():
            return candidate
    return None


def register_bundled_font(path: Path | None = None) -> bool:
    """Makes Orbitron available to this process. Returns whether it worked."""
    font = path or bundled_font()
    if font is None or not font.is_file():
        log.warning("Orbitron not found; falling back to %s", FALLBACK_FAMILY)
        return False

    library = ctypes.util.find_library("fontconfig")
    if library is None:
        log.warning("fontconfig not found; falling back to %s", FALLBACK_FAMILY)
        return False

    try:
        fontconfig = ctypes.CDLL(library)
        fontconfig.FcConfigAppFontAddFile.restype = ctypes.c_int
        fontconfig.FcConfigAppFontAddFile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        # A NULL config means the current one, which Pango is already using.
        added = fontconfig.FcConfigAppFontAddFile(None, str(font).encode("utf-8"))
    except (OSError, AttributeError) as error:
        log.warning("Could not register %s: %s; falling back to %s", font, error, FALLBACK_FAMILY)
        return False

    if not added:
        log.warning("fontconfig rejected %s; falling back to %s", font, FALLBACK_FAMILY)
        return False
    return True
