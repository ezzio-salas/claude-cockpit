"""The fetcher is exercised against stand-in shell scripts, as the Swift tests are."""

import os
import stat
import subprocess
import textwrap
import time

import pytest

from cockpit.fetcher import (
    USAGE_ARGUMENTS,
    FetchError,
    FetchErrorKind,
    UsageFetcher,
    message_for,
    resolve,
)


def stub(directory, name, body, executable=True):
    path = directory / name
    path.write_text(textwrap.dedent(body).lstrip())
    if executable:
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def test_reads_normal_output(tmp_path):
    cli = stub(tmp_path, "claude", """
        #!/bin/sh
        echo "Current session: 12% used · resets Oct 5, 2:45pm (America/New_York)"
    """)
    assert "Current session: 12%" in UsageFetcher(command=str(cli)).fetch()


def test_passes_the_exact_arguments(tmp_path):
    recorded = tmp_path / "args.txt"
    cli = stub(tmp_path, "claude", f"""
        #!/bin/sh
        for a in "$@"; do printf '%s\\n' "$a" >> {recorded}; done
        echo ok
    """)
    UsageFetcher(command=str(cli)).fetch()
    # One line per argument, including the empty `--setting-sources` value.
    assert recorded.read_text().split("\n")[:-1] == USAGE_ARGUMENTS


def test_non_zero_exit_reports_the_output(tmp_path):
    cli = stub(tmp_path, "claude", """
        #!/bin/sh
        echo "Invalid API key"
        exit 1
    """)
    with pytest.raises(FetchError) as caught:
        UsageFetcher(command=str(cli)).fetch()
    assert caught.value.kind is FetchErrorKind.FAILED
    assert caught.value.exit_code == 1
    assert "Invalid API key" in caught.value.detail


def test_a_cli_that_outlives_the_timeout_is_killed(tmp_path):
    cli = stub(tmp_path, "claude", """
        #!/bin/sh
        sleep 30
    """)
    started = time.monotonic()
    with pytest.raises(FetchError) as caught:
        UsageFetcher(command=str(cli), timeout=1).fetch()
    assert caught.value.kind is FetchErrorKind.TIMED_OUT
    assert time.monotonic() - started < 10


def test_a_cli_that_ignores_sigterm_is_still_killed(tmp_path):
    cli = stub(tmp_path, "claude", """
        #!/bin/sh
        trap '' TERM
        sleep 30
    """)
    with pytest.raises(FetchError) as caught:
        UsageFetcher(command=str(cli), timeout=1).fetch()
    assert caught.value.kind is FetchErrorKind.TIMED_OUT


def test_output_survives_a_lingering_child(tmp_path):
    """A pipe would make the read wait on the grandchild; a file does not."""
    cli = stub(tmp_path, "claude", """
        #!/bin/sh
        sleep 20 &
        echo "Current session: 3% used · resets Oct 5, 2:45pm (America/New_York)"
    """)
    assert "3%" in UsageFetcher(command=str(cli), timeout=5).fetch()


def test_missing_executable(tmp_path):
    with pytest.raises(FetchError) as caught:
        UsageFetcher(command=str(tmp_path / "nope")).fetch()
    assert caught.value.kind is FetchErrorKind.CLI_NOT_FOUND


def test_a_non_executable_file_is_not_the_cli(tmp_path):
    path = stub(tmp_path, "claude", "#!/bin/sh\necho hi\n", executable=False)
    assert resolve(str(path)) is None


def test_resolve_prefers_an_earlier_search_directory(tmp_path, monkeypatch):
    # PATH is searched first, so it has to be emptied for the fallback order to show.
    monkeypatch.setenv("PATH", str(tmp_path / "empty"))
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.mkdir()
    second.mkdir()
    stub(second, "claude", "#!/bin/sh\n")
    wanted = stub(first, "claude", "#!/bin/sh\n")
    assert resolve("claude", [first, second]) == wanted


def test_resolve_prefers_path_over_the_search_directories(tmp_path, monkeypatch):
    """A `claude` the person's shell would run wins over one merely installed somewhere."""
    on_path = tmp_path / "on-path"
    elsewhere = tmp_path / "elsewhere"
    on_path.mkdir()
    elsewhere.mkdir()
    wanted = stub(on_path, "claude", "#!/bin/sh\n")
    stub(elsewhere, "claude", "#!/bin/sh\n")
    monkeypatch.setenv("PATH", str(on_path))
    assert resolve("claude", [elsewhere]) == wanted


def test_resolve_expands_a_tilde_path(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    cli = stub(tmp_path, "claude-work", "#!/bin/sh\n")
    assert resolve("~/claude-work") == cli


def test_resolve_finds_nothing_for_an_unknown_name(tmp_path, monkeypatch):
    # An empty PATH and no search directories leaves only the login-shell lookup,
    # which will not find this name either.
    monkeypatch.setenv("PATH", str(tmp_path))
    assert resolve("definitely-not-a-real-command-xyz", []) is None


@pytest.mark.parametrize(
    "kind,expected",
    [
        (FetchErrorKind.CLI_NOT_FOUND, "CLAUDE CLI NOT FOUND"),
        (FetchErrorKind.TIMED_OUT, "TIMED OUT"),
        (FetchErrorKind.LAUNCH_FAILED, "COULD NOT READ USAGE"),
        (FetchErrorKind.FAILED, "COULD NOT READ USAGE"),
    ],
)
def test_messages(kind, expected):
    assert message_for(FetchError(kind)) == expected
