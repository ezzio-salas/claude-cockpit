"""How much of the Cursor plan has been used, read from the Cursor CLI.

A port of `CockpitCore/CursorUsage.swift`. The CLI prints plan usage nowhere but on the
`/usage` screen of its interactive mode, so the fetcher runs it on a pseudo-terminal,
types `/usage` as a person would, and reads what is drawn.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import logging
import os
import pty
import re
import select
import signal
import stat
import struct
import subprocess
import termios
import time
from dataclasses import dataclass
from pathlib import Path

from .fetcher import FetchError, FetchErrorKind, resolve
from .xdg import cache_home

log = logging.getLogger(__name__)

#: Wide enough that the CLI draws each row of its table on one line.
_COLUMNS = 120
_ROWS = 40
#: How long the screen has to stay still to count as fully drawn.
_SETTLE = 0.5
#: The CLI is given this long to start before `/usage` is typed anyway.
_STARTUP_LIMIT = 8.0
_ECHO_LIMIT = 3.0

# CSI, OSC, character-set and two-character escape sequences.
_ESCAPE = re.compile(
    r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[()][0-9A-Za-z]|[@-Z\\-_=>])"
)
_ALLOWANCE = re.compile(r"([A-Za-z][A-Za-z-]*)\s+(\d{1,3})% used")
_ON_DEMAND = re.compile(r"On-Demand\s+(\$[\d,]+(?:\.\d+)?)")
_RESETS = re.compile(r"Resets\s+([A-Z][a-z]{2} \d{1,2})\b")


@dataclass(frozen=True)
class CursorAllowance:
    """One share of the plan, such as `Included` or `Auto`."""

    label: str
    percent_used: int


@dataclass(frozen=True)
class CursorUsage:
    allowances: tuple[CursorAllowance, ...]
    #: The day the plan renews, in the CLI's words (`Oct 17`); None when it names none.
    resets: str | None
    #: Spend beyond the plan, in the CLI's words (`$482.19`); None when it shows none.
    on_demand: str | None


def plain_text(screen: str) -> str:
    """`screen` with its terminal escape sequences replaced by spaces."""
    return _ESCAPE.sub(" ", screen)


def parse_cursor_usage(screen: str) -> CursorUsage | None:
    """Reads the `/usage` table out of what the CLI drew, or None if it is not there.

    The screen is a stream of redraws rather than lines, so a row can appear more than
    once; the last drawing of each wins, in the order the rows first appeared.
    """
    text = plain_text(screen)
    percents: dict[str, int] = {}
    for label, percent in _ALLOWANCE.findall(text):
        percents[label.upper()] = min(int(percent), 100)
    on_demand = _ON_DEMAND.findall(text)
    if not percents and not on_demand:
        return None

    resets = _RESETS.findall(text)
    return CursorUsage(
        allowances=tuple(CursorAllowance(label, used) for label, used in percents.items()),
        resets=resets[-1] if resets else None,
        on_demand=on_demand[-1] if on_demand else None,
    )


class CursorUsageFetcher:
    """Reads `CursorUsage` from the Cursor CLI.

    `fetch` blocks for several seconds, so callers run it off the UI thread.
    """

    def __init__(self, command: str = "cursor-agent", timeout: float = 20.0) -> None:
        #: Resolved on each fetch, so a CLI installed while the app runs is picked up.
        self.command = command
        self.timeout = timeout

    def fetch(self) -> CursorUsage:
        """Returns the usage the CLI shows, or raises `FetchError`."""
        cli = resolve(self.command)
        if cli is None:
            raise FetchError(FetchErrorKind.CLI_NOT_FOUND)

        deadline = time.monotonic() + self.timeout
        try:
            workspace = _workspace()
            # `--trust` answers the question the CLI asks about a directory it has not seen.
            session = _TerminalSession([str(cli), "--trust"], workspace)
        except OSError as error:
            raise FetchError(FetchErrorKind.LAUNCH_FAILED, str(error)) from error
        try:
            return _read_usage(session, deadline)
        except _Ended:
            raise FetchError(FetchErrorKind.FAILED, plain_text(session.text())) from None
        finally:
            session.close()
            discard_empty_sessions(workspace, Path.home() / ".cursor/chats")


def _workspace() -> Path:
    """An empty directory of this user's own for the CLI to start in.

    Empty, so the CLI has no project to index; private, because the CLI is told to trust
    it, and a workspace can carry hooks and rules the CLI would act on. A shared location
    such as `/tmp` would let another account put those there first.
    """
    directory = cache_home() / "claude-cockpit/cursor-workspace"
    directory.parent.mkdir(parents=True, exist_ok=True)
    directory.mkdir(mode=0o700, exist_ok=True)

    status = directory.lstat()
    if stat.S_ISLNK(status.st_mode) or status.st_uid != os.getuid():
        raise OSError(f"{directory} is not a directory of this user's own")
    if status.st_mode & 0o077:
        directory.chmod(0o700)
    if any(directory.iterdir()):
        raise OSError(f"{directory} is not empty")
    return directory.resolve()


def discard_empty_sessions(workspace: Path, chats: Path) -> None:
    """Removes the session records the CLI filed under `chats` for starting in `workspace`.

    Every start leaves one, and a widget that polls would leave hundreds a day. A record
    is removed only if it names this workspace and holds no conversation, and only the
    two files such a record has are deleted, so anything unexpected is left alone.
    """
    sessions = chats / hashlib.md5(str(workspace).encode(), usedforsecurity=False).hexdigest()
    for meta in sessions.glob("*/meta.json"):
        try:
            record = json.loads(meta.read_text(encoding="utf-8"))
            if not isinstance(record, dict):
                continue
            if record.get("cwd") != str(workspace) or record.get("hasConversation") is not False:
                continue
            meta.unlink()
            (meta.parent / "prompt_history.json").unlink(missing_ok=True)
            meta.parent.rmdir()
        except (OSError, ValueError):
            continue


def _read_usage(session: _TerminalSession, deadline: float) -> CursorUsage:
    _wait_until_drawn(session, min(deadline, time.monotonic() + _STARTUP_LIMIT))

    # Enter is pressed only once the CLI shows it took the command, so a screen that is
    # asking something else -- to sign in, say -- is never answered blind.
    typed = session.mark()
    session.type("/usage")
    echo_deadline = min(deadline, time.monotonic() + _ECHO_LIMIT)
    while "/usage" not in plain_text(session.text(typed)):
        if time.monotonic() >= echo_deadline:
            raise FetchError(FetchErrorKind.FAILED, plain_text(session.text()))
        session.read(_SETTLE)

    entered = session.mark()
    session.type("\r")
    usage = None
    while time.monotonic() < deadline:
        if session.read(_SETTLE):
            usage = parse_cursor_usage(session.text(entered))
        elif usage is not None:
            return usage
    if usage is None:
        raise FetchError(FetchErrorKind.TIMED_OUT)
    return usage


def _wait_until_drawn(session: _TerminalSession, deadline: float) -> None:
    """Returns once the CLI has drawn something and then gone still."""
    has_drawn = False
    while time.monotonic() < deadline:
        if session.read(_SETTLE):
            has_drawn = True
        elif has_drawn:
            return


class _Ended(Exception):
    """The program closed its terminal."""


class _TerminalSession:
    """A program running on a pseudo-terminal, and everything it has drawn so far."""

    def __init__(self, arguments: list[str], directory: Path) -> None:
        self._master, terminal = pty.openpty()
        try:
            fcntl.ioctl(self._master, termios.TIOCSWINSZ, struct.pack("HHHH", _ROWS, _COLUMNS, 0, 0))
            self._process = subprocess.Popen(
                arguments,
                stdin=terminal,
                stdout=terminal,
                stderr=terminal,
                cwd=directory,
                env={**os.environ, "TERM": "xterm-256color"},
                start_new_session=True,
            )
        except OSError:
            os.close(self._master)
            raise
        finally:
            os.close(terminal)
        self._drawn = b""

    def type(self, keys: str) -> None:
        try:
            os.write(self._master, keys.encode("utf-8"))
        except OSError:
            raise _Ended from None

    def read(self, seconds: float) -> bool:
        """Waits up to `seconds` for output. Returns whether any arrived."""
        ready, _, _ = select.select([self._master], [], [], seconds)
        if not ready:
            return False
        try:
            chunk = os.read(self._master, 65536)
        except OSError:  # Linux reports the far end closing as EIO.
            chunk = b""
        if not chunk:
            raise _Ended
        self._drawn += chunk
        return True

    def mark(self) -> int:
        """A position `text` can later start from."""
        return len(self._drawn)

    def text(self, since: int = 0) -> str:
        return self._drawn[since:].decode("utf-8", errors="replace")

    def close(self) -> None:
        # The CLI is a wrapper script around its runtime; the whole group goes.
        try:
            os.killpg(self._process.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            self._process.kill()
        try:
            self._process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            log.warning("Cursor CLI did not exit after SIGKILL")
        os.close(self._master)
