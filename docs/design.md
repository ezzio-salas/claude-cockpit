# Claude Cockpit — Design

Date: 2026-10-05

## Purpose

A small, frameless, always-on-top macOS widget that shows the user's Claude plan usage
(the numbers `/usage` reports) at a glance, without opening a terminal.

Success: the widget floats above other windows, shows current session and weekly usage
percentages with time until reset, keeps itself up to date, and never shows numbers it
did not read from Claude.

## Scope

In scope:

- One floating panel showing one meter per usage line Claude reports.
- Automatic refresh, manual refresh, quit.
- Remembered window position.

Out of scope: launch at login, settings UI, usage history or charts, the
"what's contributing to your limits" breakdown, an embedded or launched terminal,
single-instance enforcement.

## Data source

The app runs the Claude Code CLI non-interactively:

```
claude -p "/usage" --no-session-persistence --setting-sources "" --strict-mcp-config
```

- stdin is `/dev/null`; working directory is the user's temporary directory.
- The flags skip user hooks, plugins and MCP servers and save no session, so a poll
  takes about 1.4s and leaves nothing behind.
- Authentication is whatever the CLI already has; the app never touches credentials.

Example output:

```
You are currently using your subscription to power your Claude Code usage

Current session: 12% used · resets Oct 5 at 2:45pm (America/New_York)
Current week (all models): 34% used · resets Oct 8 at 9am (America/New_York)
Current week (Fable): 5% used · resets Oct 8 at 9am (America/New_York)

What's contributing to your limits usage?
...
```

Everything after the `Current …` lines is ignored.

## Structure

Swift package in `claude_cockpit/`, AppKit only, no third-party dependencies,
minimum macOS 14.

```
claude_cockpit/
  Package.swift
  Info.plist
  build.sh                      # swift build -c release, then assemble ClaudeCockpit.app
  Resources/Orbitron.ttf, Orbitron-OFL.txt
  Sources/
    CockpitCore/                # pure logic, unit-tested
      UsageMeter.swift
      UsageParser.swift
      ResetCountdown.swift
      UsageFetcher.swift
    ClaudeCockpit/              # executable: window and drawing
      main.swift
      AppDelegate.swift
      CockpitPanel.swift
      CockpitView.swift
      MeterRowView.swift
      Theme.swift
      Layout.swift
  Tests/CockpitCoreTests/
```

### CockpitCore

**`UsageMeter`** — value type: `label: String`, `percentUsed: Int` (0–100),
`reset: Reset`, where `Reset` is `.at(Date)` or `.unparsed(String)`.

**`UsageParser`** — `parse(_ text: String, now: Date) -> [UsageMeter]`.

- Matches each line of the form `Current <name>: <N>% used · resets <when>`.
- Label from `<name>`: `session` → `SESSION`; `week (all models)` → `WEEK`;
  `week (<X>)` → `WEEK · <X>` uppercased; anything else → `<name>` uppercased.
  New rows therefore appear without code changes.
- `<when>` has the form `<Mon> <d> at <h>[:mm]<am|pm> (<IANA zone>)`. It is parsed in
  the named zone. The year is not printed, so the parser picks the year that puts the
  date closest to `now`. If `<when>` does not match, the meter carries
  `.unparsed(<when>)` and the widget shows that text verbatim instead of a countdown.
- Returns an empty array when no line matches; the caller treats that as a failure.

**`ResetCountdown`** — `text(until: Date, now: Date) -> String`:
`resets in 2d 5h`, `resets in 3h 12m`, `resets in 12m`, `resets in <1m`,
and `resets now` once the time has passed.

**`UsageFetcher`** — `fetch() async -> Result<String, FetchError>`.

- Locates `claude` once: first existing of `~/.local/bin/claude`,
  `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`; otherwise asks a login shell
  (`/bin/zsh -lc 'command -v claude'`). GUI apps do not inherit the shell `PATH`,
  hence the explicit search.
- Runs the command off the main thread with a 20s timeout. On timeout the process is
  killed with SIGKILL, because a CLI blocked in a system call (for example behind a
  macOS privacy prompt) does not act on SIGTERM.
- Output is captured in a temporary file rather than a pipe, so waiting never depends
  on a descendant process closing its end.
- `FetchError`: `.cliNotFound`, `.timedOut`, `.launchFailed(String)`,
  `.failed(exitCode:output:)`. Failures are logged under the `local.claude-cockpit`
  subsystem.

### ClaudeCockpit (UI)

**Window** — `NSPanel`, style `[.borderless, .nonactivatingPanel]`, level `.floating`,
collection behavior `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`,
transparent background with shadow. The app is an accessory app (`LSUIElement`):
no Dock icon, no menu bar. Position persists through the frame autosave name;
first launch places it near the top-right of the main screen.

**Appearance**

- About 260pt wide; height fits the number of meters.
- Dark translucent glass (`NSVisualEffectView`, HUD material), 16pt corner radius,
  1pt cyan edge with a soft outer glow.
- Header: `CLAUDE` in Orbitron, small and letter-spaced, with the status marker on
  the right.
- One row per meter: label (Orbitron), percentage (monospaced digits), a thin
  rounded bar, and the reset text beneath in a dimmer tone.
- Bar and percentage color: cyan below 70%, amber from 70%, red from 90%.
- Orbitron is registered from the bundled file at launch; if that fails the app
  falls back to the system monospaced font.

**Interaction**

- Drag anywhere to move.
- Click (without dragging) refreshes immediately.
- Right-click menu: Refresh, Quit.

## Refresh and state

- Fetch on launch, then every 60 seconds. A fetch never overlaps another; a manual
  refresh during a fetch is ignored.
- Countdown text is recomputed every 30 seconds from the stored reset dates, without
  fetching.
- State held by the app: last good meters, time of last success, last error.

## Failure handling

A fetch counts as failed if the fetcher returns an error or the parser returns no
meters.

- With previous good values: keep showing them dimmed, with `STALE · <age>` in the
  header (for example `STALE · 2m`). The next successful fetch clears it.
- With no good values yet: show one line in place of the meters —
  `CLAUDE CLI NOT FOUND`, `TIMED OUT`, `COULD NOT READ USAGE`, or
  `UNRECOGNIZED OUTPUT`.
- The widget never displays placeholder or estimated numbers.

## Testing

Unit tests for `CockpitCore`:

- Parser: the real sample above (three meters, labels, percents, reset dates in the
  right zone); times with and without minutes; unparseable reset text; a new unknown
  row name; output with no usage lines; year rollover (a January reset read in
  December).
- Countdown: each format boundary and the past case.

Unit tests for `UsageFetcher` run it against stand-in shell scripts: normal output,
the exact arguments passed, non-zero exit, a CLI that outlives the timeout, a CLI that
ignores SIGTERM, and a missing executable.

The UI is verified manually: build the app, launch it, and compare the widget against
`claude -p "/usage"`.
