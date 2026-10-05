"""The Cursor CLI is stood in for by shell scripts on a real pseudo-terminal."""

import hashlib
import json
import stat
import textwrap
import time

import pytest

from claude_cockpit.cursor_usage import (
    CursorAllowance,
    CursorUsage,
    CursorUsageFetcher,
    discard_empty_sessions,
    parse_cursor_usage,
)
from claude_cockpit.fetcher import FetchError, FetchErrorKind

BAR = "█" * 40

# What the CLI draws for `/usage`, escape sequences included, with the bars shortened.
SCREEN = (
    "Loading usage data...\x1b[39m\r\n\x1b[2K\x1b[1A\x1b[2K\x1b[G"
    "\x1b[38;2;244;231;161m────────\x1b[39m\r\n"
    " \x1b[1m\x1b[38;2;244;231;161mUsage\x1b[39m\x1b[22m\x1b[2m • \x1b[22mTeam"
    "          \x1b[2mResets Oct 17\x1b[22m\r\n"
    " \x1b[2mMonthly plan and on-demand usage\x1b[22m\r\n\r\n"
    " \x1b[2mCategory\x1b[22m        \x1b[2mCurrent\x1b[22m             \x1b[2mUsage\x1b[22m\r\n"
    f" Included        100% used           \x1b[36m{BAR}\x1b[39m\r\n"
    " \x1b[2m  Auto\x1b[22m          \x1b[2m0% used\x1b[22m             \x1b[2m░░░░\x1b[22m\r\n"
    f" \x1b[2m  API\x1b[22m           \x1b[2m100% used\x1b[22m           \x1b[35m{BAR}\x1b[39m\r\n"
    " On-Demand       $482.19             \x1b[2m————\x1b[22m\r\n\r\n"
    " \x1b[2mNo personal limit\x1b[22m\r\n\r\n"
    " \x1b[2mView in dashboard: \x1b[22m\x1b]8;;https://cursor.com/dashboard?tab=usage\x07"
    "\x1b[4m\x1b[34mcursor.com/dashboard?tab=usage\x1b[39m\x1b[24m\x1b]8;;\x07\r\n\r\n"
    " \x1b[2mEsc to close\x1b[22m\r\n\x1b[?2004l"
)


@pytest.fixture(autouse=True)
def home(tmp_path, monkeypatch):
    """Keeps the fetcher's tidying of `~/.cursor/chats` away from the real one."""
    monkeypatch.setenv("HOME", str(tmp_path))


def stub(directory, body):
    path = directory / "cursor-agent"
    path.write_text(textwrap.dedent(body).lstrip())
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


# --- parser --------------------------------------------------------------


def test_parses_the_real_screen():
    assert parse_cursor_usage(SCREEN) == CursorUsage(
        allowances=(
            CursorAllowance("INCLUDED", 100),
            CursorAllowance("AUTO", 0),
            CursorAllowance("API", 100),
        ),
        resets="Oct 17",
        on_demand="$482.19",
    )


def test_a_redrawn_row_keeps_its_place_and_its_latest_figure():
    screen = " Included 10% used\r\n Auto 5% used\r\n\x1b[2A Included 12% used\r\n"
    assert parse_cursor_usage(screen).allowances == (
        CursorAllowance("INCLUDED", 12),
        CursorAllowance("AUTO", 5),
    )


def test_a_plan_without_on_demand_spend_or_a_reset_date():
    usage = parse_cursor_usage(" Included        42% used\r\n")
    assert usage == CursorUsage((CursorAllowance("INCLUDED", 42),), resets=None, on_demand=None)


def test_a_percentage_above_one_hundred_is_capped():
    assert parse_cursor_usage("Included 250% used").allowances[0].percent_used == 100


def test_on_demand_spend_with_a_thousands_separator():
    assert parse_cursor_usage("On-Demand       $1,482.19").on_demand == "$1,482.19"


@pytest.mark.parametrize("screen", ["", "Loading usage data...", "\x1b[2K\x1b[1A Plan, search, build"])
def test_a_screen_without_the_table_is_not_usage(screen):
    assert parse_cursor_usage(screen) is None


# --- fetcher -------------------------------------------------------------


def test_types_the_command_and_reads_the_table(tmp_path):
    recorded = tmp_path / "invocation.txt"
    cli = stub(tmp_path, f"""
        #!/bin/sh
        printf '%s\\n' "$@" > {recorded}
        echo "Cursor Agent"
        read command
        [ "$command" = "/usage" ] || exit 3
        echo ' Included        42% used'
        echo ' On-Demand       $1.50      Resets Oct 17'
        sleep 30
    """)
    started = time.monotonic()
    usage = CursorUsageFetcher(command=str(cli), timeout=10).fetch()
    assert usage == CursorUsage((CursorAllowance("INCLUDED", 42),), "Oct 17", "$1.50")
    assert recorded.read_text() == "--trust\n"
    # It does not wait for the CLI to exit, which an interactive one never does.
    assert time.monotonic() - started < 8


def test_missing_cli(tmp_path):
    with pytest.raises(FetchError) as caught:
        CursorUsageFetcher(command=str(tmp_path / "nope")).fetch()
    assert caught.value.kind is FetchErrorKind.CLI_NOT_FOUND


def test_a_cli_that_exits_reports_what_it_printed(tmp_path):
    cli = stub(tmp_path, """
        #!/bin/sh
        echo "Not logged in"
        exit 1
    """)
    with pytest.raises(FetchError) as caught:
        CursorUsageFetcher(command=str(cli), timeout=10).fetch()
    assert caught.value.kind is FetchErrorKind.FAILED
    assert "Not logged in" in caught.value.detail


def test_a_cli_that_never_shows_usage_times_out_and_is_killed(tmp_path):
    cli = stub(tmp_path, """
        #!/bin/sh
        echo "Cursor Agent"
        sleep 30
    """)
    started = time.monotonic()
    with pytest.raises(FetchError) as caught:
        CursorUsageFetcher(command=str(cli), timeout=2).fetch()
    assert caught.value.kind is FetchErrorKind.TIMED_OUT
    assert time.monotonic() - started < 10


def test_enter_is_not_pressed_on_a_screen_that_did_not_take_the_command(tmp_path):
    """A CLI asking something else -- here with echo off -- must not be answered blind."""
    answered = tmp_path / "answered.txt"
    cli = stub(tmp_path, f"""
        #!/bin/sh
        stty -echo
        echo "Sign in to continue? [Y/n]"
        read answer
        echo "$answer" > {answered}
        sleep 30
    """)
    with pytest.raises(FetchError) as caught:
        CursorUsageFetcher(command=str(cli), timeout=10).fetch()
    assert caught.value.kind is FetchErrorKind.FAILED
    assert not answered.exists()


# --- session records -----------------------------------------------------


def session(chats, workspace, name, cwd=None, has_conversation=False, extra=None):
    directory = chats / hashlib.md5(str(workspace).encode()).hexdigest() / name
    directory.mkdir(parents=True)
    meta = {"cwd": str(cwd or workspace), "hasConversation": has_conversation}
    (directory / "meta.json").write_text(json.dumps(meta))
    (directory / "prompt_history.json").write_text('["/usage"]')
    if extra:
        (directory / extra).write_text("kept")
    return directory


def test_empty_sessions_of_the_workspace_are_removed(tmp_path):
    chats, workspace = tmp_path / "chats", tmp_path / "workspace"
    empty = session(chats, workspace, "empty")
    discard_empty_sessions(workspace, chats)
    assert not empty.exists()


def test_sessions_that_are_not_plainly_ours_are_kept(tmp_path):
    chats, workspace = tmp_path / "chats", tmp_path / "workspace"
    kept = [
        session(chats, workspace, "conversation", has_conversation=True),
        session(chats, workspace, "elsewhere", cwd=tmp_path / "another-project"),
        session(chats, tmp_path / "another-project", "other-workspace"),
    ]
    unexpected = session(chats, workspace, "unexpected", extra="store.db")
    unreadable = chats / hashlib.md5(str(workspace).encode()).hexdigest() / "unreadable"
    unreadable.mkdir()
    (unreadable / "meta.json").write_text("not json")

    discard_empty_sessions(workspace, chats)

    assert all((directory / "meta.json").exists() for directory in kept)
    assert (unexpected / "store.db").exists()
    assert (unreadable / "meta.json").exists()


def test_no_chats_directory_at_all(tmp_path):
    discard_empty_sessions(tmp_path / "workspace", tmp_path / "absent")


def test_a_workspace_that_is_not_empty_is_not_trusted(tmp_path):
    """Whatever is in the workspace would run with the CLI's trust, so it is not started."""
    workspace = tmp_path / ".cache/claude-cockpit/cursor-workspace"
    workspace.mkdir(parents=True)
    (workspace / ".cursor").mkdir()
    cli = stub(tmp_path, "#!/bin/sh\necho 'Cursor Agent'\nsleep 30\n")
    with pytest.raises(FetchError) as caught:
        CursorUsageFetcher(command=str(cli), timeout=5).fetch()
    assert caught.value.kind is FetchErrorKind.LAUNCH_FAILED
    assert "not empty" in caught.value.detail


def test_the_workspace_is_private_to_the_user(tmp_path):
    cli = stub(tmp_path, "#!/bin/sh\necho 'Cursor Agent'\nexit 0\n")
    with pytest.raises(FetchError):
        CursorUsageFetcher(command=str(cli), timeout=5).fetch()
    workspace = tmp_path / ".cache/claude-cockpit/cursor-workspace"
    assert workspace.is_dir()
    assert workspace.stat().st_mode & 0o777 == 0o700
