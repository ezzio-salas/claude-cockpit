"""Runs the Claude Code CLI to read the raw `/usage` report.

A port of `CockpitCore/UsageFetcher.swift`, with the command search adapted to Linux:
there is no Homebrew, the login shell is whatever `$SHELL` says, and version managers
such as mise, asdf and volta put their shims outside the directories a desktop launcher
inherits on `PATH`.
"""

from __future__ import annotations

import logging
import os
import re
import shutil
import signal
import subprocess
import tempfile
from enum import Enum
from pathlib import Path

from .xdg import data_home

log = logging.getLogger(__name__)

#: Skips user hooks, plugins and MCP servers and saves no session, so a poll is quick
#: and leaves nothing behind.
USAGE_ARGUMENTS = [
    "-p", "/usage", "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config",
]


def install_directories() -> list[Path]:
    """Where a `claude` binary is plausibly installed, most specific first.

    A desktop launcher starts with a minimal `PATH`, so the shims of the version
    managers people actually install Claude Code with have to be named explicitly.
    """
    home = Path.home()
    return [
        home / ".local/bin",
        data_home() / "mise/shims",
        home / ".asdf/shims",
        home / ".volta/bin",
        home / ".bun/bin",
        *_nvm_directories(home),
        home / "bin",
        Path("/usr/local/bin"),
        Path("/usr/bin"),
        Path("/var/lib/flatpak/exports/bin"),
    ]


def _nvm_directories(home: Path) -> list[Path]:
    """The `bin` of each Node version nvm has installed, newest first.

    nvm has no shim directory: it puts one of these on `PATH` from the shell's startup
    file, which a desktop launcher never runs.
    """
    versions = Path(os.environ.get("NVM_DIR") or home / ".nvm") / "versions/node"
    return sorted(
        versions.glob("v*/bin"),
        key=lambda directory: [int(part) for part in re.findall(r"\d+", directory.parent.name)],
        reverse=True,
    )


class FetchErrorKind(Enum):
    CLI_NOT_FOUND = "cli_not_found"
    TIMED_OUT = "timed_out"
    LAUNCH_FAILED = "launch_failed"
    FAILED = "failed"


class FetchError(Exception):
    def __init__(
        self, kind: FetchErrorKind, detail: str = "", exit_code: int | None = None
    ) -> None:
        super().__init__(kind.value, detail, exit_code)
        self.kind = kind
        self.detail = detail
        self.exit_code = exit_code


def resolve(command: str, search_directories: list[Path] | None = None) -> Path | None:
    """Finds the executable for `command`.

    A command containing `/` is taken as a path. A bare name is looked up on `PATH`,
    then in `search_directories`, then by a login shell -- because a window started
    from a desktop launcher or a systemd user unit does not inherit the shell's `PATH`.
    """
    if search_directories is None:
        search_directories = install_directories()

    if "/" in command:
        try:
            path = Path(command).expanduser()
        except RuntimeError:  # `~name` for a user that does not exist.
            return None
        return path if os.access(path, os.X_OK) and path.is_file() else None

    found = shutil.which(command)
    if found:
        return Path(found)

    for directory in search_directories:
        candidate = directory / command
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate

    return _resolve_via_login_shell(command)


def _resolve_via_login_shell(command: str) -> Path | None:
    """Looks `command` up on the `PATH` a login shell ends up with.

    The shell is asked only to print `PATH`. A lookup written in shell would work in the
    POSIX shells and fail in fish and nushell, which spell arguments differently; an
    external `printenv` runs the same in all of them.
    """
    shell = os.environ.get("SHELL") or "/bin/sh"
    if not os.access(shell, os.X_OK):
        shell = "/bin/sh"
    try:
        result = subprocess.run(
            [shell, "-lc", "printenv PATH"],
            capture_output=True,
            text=True,
            timeout=5,
            stdin=subprocess.DEVNULL,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    # A profile may print a greeting first; `PATH` is the last line.
    lines = result.stdout.splitlines()
    if result.returncode != 0 or not lines:
        return None
    found = shutil.which(command, path=lines[-1])
    return Path(found) if found else None


class UsageFetcher:
    """Reads the raw `/usage` report from the Claude Code CLI.

    `fetch` blocks, so callers run it off the UI thread.
    """

    def __init__(self, command: str = "claude", timeout: float = 20.0) -> None:
        #: Resolved on each fetch, so a CLI installed while the app runs is picked up.
        self.command = command
        self.timeout = timeout

    def fetch(self) -> str:
        """Returns the CLI's output, or raises `FetchError`."""
        cli = resolve(self.command)
        if cli is None:
            raise FetchError(FetchErrorKind.CLI_NOT_FOUND)
        return self._run(cli, USAGE_ARGUMENTS, self.timeout)

    @staticmethod
    def _run(executable: Path, arguments: list[str], timeout: float) -> str:
        # Output goes to a file rather than a pipe, so waiting depends only on the
        # process itself and never on a descendant that still holds a pipe open.
        with tempfile.TemporaryFile(mode="w+", encoding="utf-8", errors="replace") as sink:
            try:
                process = subprocess.Popen(
                    [str(executable), *arguments],
                    stdin=subprocess.DEVNULL,
                    stdout=sink,
                    stderr=subprocess.STDOUT,
                    cwd=tempfile.gettempdir(),
                    env=_environment_for(executable),
                    start_new_session=True,
                )
            except OSError as error:
                raise FetchError(FetchErrorKind.LAUNCH_FAILED, str(error)) from error

            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                # SIGKILL rather than SIGTERM: a CLI stuck in a system call never gets
                # to act on a polite request. The whole group goes, so no child outlives it.
                _kill_group(process)
                raise FetchError(FetchErrorKind.TIMED_OUT) from None

            sink.seek(0)
            output = sink.read()

        if process.returncode != 0:
            raise FetchError(
                FetchErrorKind.FAILED, output, exit_code=process.returncode
            )
        return output


def _environment_for(executable: Path) -> dict[str, str]:
    """The environment with the CLI's own directory first on `PATH`.

    A CLI installed through npm is a script that starts `node`, and under nvm `node` sits
    beside it in a directory a desktop launcher's `PATH` does not have.
    """
    path = os.environ.get("PATH", os.defpath)
    return {**os.environ, "PATH": f"{executable.parent}{os.pathsep}{path}"}


def _kill_group(process: subprocess.Popen) -> None:
    try:
        os.killpg(os.getpgid(process.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        process.kill()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        log.warning("CLI did not exit after SIGKILL")


def message_for(error: FetchError) -> str:
    """The single line the card shows when there is no earlier reading to fall back on."""
    return {
        FetchErrorKind.CLI_NOT_FOUND: "CLAUDE CLI NOT FOUND",
        FetchErrorKind.TIMED_OUT: "TIMED OUT",
        FetchErrorKind.LAUNCH_FAILED: "COULD NOT READ USAGE",
        FetchErrorKind.FAILED: "COULD NOT READ USAGE",
    }[error.kind]
