"""Entry point: `python -m cockpit` or the `claude-cockpit` console script."""

from __future__ import annotations

import logging
import sys


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    # Registered before any widget is built, so the CSS can name the family.
    from .ui.fonts import register_bundled_font

    register_bundled_font()

    from .app import CockpitApplication

    return CockpitApplication().run(argv if argv is not None else sys.argv)


if __name__ == "__main__":
    raise SystemExit(main())
