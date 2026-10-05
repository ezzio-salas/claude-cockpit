# Claude Cockpit — Design

Date: 2026-10-05 (macOS), 2026-10-05 (Linux build added)

## Purpose

A small, frameless, always-on-top widget that shows the user's Claude plan usage (the
numbers `/usage` reports) at a glance, without opening a terminal. There are two builds —
macOS (Swift, AppKit) and Linux (Python, GTK 4) — sharing one design and one set of rules.

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

Current session: 12% used · resets Oct 5, 2:45pm (America/New_York)
Current week (all models): 34% used · resets Oct 8, 9am (America/New_York)
Current week (Fable): 5% used · resets Oct 8, 9am (America/New_York)

What's contributing to your limits usage?
...
```

Everything after the `Current …` lines is ignored.

## Structure

Two builds in one repository, each with its logic apart from its UI, and the two logic
layers deliberate one-to-one ports of each other:

```
claude-cockpit/
  macos/      Swift package, AppKit only, no third-party dependencies, minimum macOS 14
  linux/      Python package, GTK 4 through PyGObject, no PyPI dependencies, Python 3.11+
  assets/     Orbitron, shared
  docs/
```

### macOS

```
macos/
  Package.swift
  Info.plist
  build.sh                      # swift build -c release, then assemble ClaudeCockpit.app
  Sources/
    CockpitCore/                # pure logic, unit-tested
      UsageMeter.swift
      UsageParser.swift
      ResetCountdown.swift
      UsageFetcher.swift
      CursorActivity.swift
      CursorUsage.swift
      CursorUsageFetcher.swift
      TerminalSession.swift
      ModelPricing.swift
      TranscriptParser.swift
      ClaudeCostEstimator.swift
      CockpitAppearance.swift
    ClaudeCockpit/              # executable: window and drawing
      main.swift
      AppDelegate.swift
      CockpitPanel.swift
      CockpitView.swift
      CustomizationWindowController.swift
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
- `<when>` has the form `<Mon> <d>[,][ at] <h>[:mm]<am|pm> (<IANA zone>)`. Claude Code has
  writes that separator as ` at ` on some installs and as `, ` on others, so both are
  accepted; a build that takes only one of them silently loses every countdown. It is parsed in
  the named zone. The year is not printed, so the parser picks the year that puts the
  date closest to `now`. If `<when>` does not match, the meter carries
  `.unparsed(<when>)` and the widget shows that text verbatim instead of a countdown.
- Returns an empty array when no line matches; the caller treats that as a failure.

**`ResetCountdown`** — `text(until: Date, now: Date) -> String`:
`resets in 2d 5h`, `resets in 3h 12m`, `resets in 12m`, `resets in <1m`,
and `resets now` once the time has passed.

**`UsageFetcher`** — `fetch() async -> Result<String, FetchError>`.

- The command to run is `claude` by default and can be changed with the `cliCommand`
  user default (a command name or a path to an executable), for example to a wrapper
  that selects another config directory.
- Resolves the command on each fetch. A value containing `/` is used as a path. A bare
  name is looked up in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`, then
  by a login shell (`command -v`). GUI apps do not inherit the shell `PATH`, hence the
  explicit search.
- Runs the command off the main thread with a 20s timeout. On timeout the process is
  killed with SIGKILL, because a CLI blocked in a system call (for example behind a
  macOS privacy prompt) does not act on SIGTERM.
- Output is captured in a temporary file rather than a pipe, so waiting never depends
  on a descendant process closing its end.
- `FetchError`: `.cliNotFound`, `.timedOut`, `.launchFailed(String)`,
  `.failed(exitCode:output:)`. Failures are logged under the `local.claude-cockpit`
  subsystem.

**`CursorActivityReader`** — `read(now:calendar:) throws -> CursorActivity?`.

- Added after the first version, for people who also use Cursor. Cursor has no local
  command that reports plan usage, and reading it from Cursor's servers would mean
  handling the user's access token, so the widget shows local activity instead.
- Source: `~/.cursor/ai-tracking/ai-code-tracking.db`, the SQLite database Cursor keeps
  for attributing code to AI. It is opened read-only with a one-second busy timeout.
- `CursorActivity` holds agent requests today (since local midnight), requests in the
  last seven days, and the model behind the most requests in that week. A request is a
  distinct `requestId` in `ai_code_hashes`, excluding rows whose `source` is `human`.
- Returns nil when the database does not exist; the widget then hides the Cursor
  section. Any other failure throws, is logged, and also hides the section.

**`CursorUsageFetcher`** — `fetch() async -> Result<CursorUsage, FetchError>`.

- Added after the Linux port, when the Cursor CLI gained a `/usage` screen. The CLI has no
  command that prints it (`cursor-agent -p "/usage"` sends the text to a model as a prompt),
  so the fetcher runs the CLI on a pseudo-terminal, as `TerminalSession`, types `/usage`
  and reads what is drawn. The CLI is started with `--trust` in an empty directory of the
  user's own (`~/Library/Caches/local.claude-cockpit/cursor-workspace`;
  `$XDG_CACHE_HOME/claude-cockpit/cursor-workspace` on Linux), so it has no project to
  index and no trust question to ask. The directory is checked before every start: it must
  be a real directory owned by the user, mode 0700, and empty, because a trusted workspace
  can carry hooks and rules the CLI would act on, and a shared location such as `/tmp`
  would let another account put them there first.
- The protocol is in three waits: for the screen to draw and go still (0.5s of quiet,
  at most 8s), for the typed `/usage` to be echoed before Enter is pressed (so a screen
  asking something else, such as to sign in, is never answered blind), and for the table
  to appear and the screen to go still again. The whole fetch has a 20s deadline, after
  which the process group is killed; it is killed after a success too.
- `CursorUsageParser` strips escape sequences and reads every `<Label> N% used` row (the
  last drawing of a repeated row wins), `On-Demand $N`, and `Resets <Mon> <d>`.
  `CursorUsage` holds the rows as `Allowance(label:percentUsed:)`, the reset wording
  verbatim (the CLI prints a date without a time or zone, so no countdown is made of it)
  and the on-demand figure verbatim.
- Every start of the CLI files an empty session record under `~/.cursor/chats/<md5 of
  the workspace path>/<id>/`. A widget polling all day would leave hundreds, so after
  each fetch the records of that workspace whose `meta.json` names it and has
  `hasConversation: false` are removed -- only their two known files, and the directory
  only if that empties it.
- Read every five minutes by the timer and at once on a click, because each read starts
  the CLI, about three seconds. Failures after a success keep the reading and mark it
  stale, as the Claude meters are; `cliNotFound` clears it, which hides the rows.
- Command: `cursor-agent` by default, `cursorCommand` user default to change it. Found the
  same way as `claude`.

**`ClaudeCostEstimator`** — `estimate(now:calendar:) -> ClaudeCost?` (an actor).

- Added after the first version. A subscription has no per-token bill and `/cost` prints
  no amounts there, so the widget shows what the usage would cost at API list prices,
  labeled `API EQ`.
- Source: the JSON Lines transcripts under `~/.claude/projects` (overridable with the
  `transcriptsDirectory` user default). Each assistant line carries the model and its
  token counts: input, output, cache read, and cache writes split into five-minute and
  one-hour kinds.
- `TranscriptParser` extracts those lines. A reply is written once per content block and
  again in transcripts that resume its session, so replies are merged by message id plus
  request id, keeping the line with the most output tokens.
- `ModelPricing` maps a model id to its prices per million tokens; a dated snapshot id is
  priced as its base model. A model with no entry is not guessed at: its usage is left
  out and its name is reported in `ClaudeCost.unpricedModels`, which the widget shows as
  a trailing `+`.
- `ClaudeCost` holds dollars since local midnight and over the last seven days.
- Only transcripts modified in the last seven days are read, and parsed files are cached
  by modification date and size, so a refresh re-reads only the sessions that changed.
- Returns nil when the transcripts directory does not exist; the widget then hides the
  cost rows.

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

- Under the meters, when a cost estimate is available: `TODAY` and `7 DAYS` rows such as
  `~$8.40 API EQ`. These are not dimmed when the Claude reading is stale.
- Below that, the `CURSOR` section, shown when either part of it is available. When plan
  usage is: a note beside the title (`RESETS OCT 17`, or `STALE · 12m` in amber), one
  meter per allowance without a reset line, and an `ON-DEMAND` row; the meters are dimmed
  when that reading is stale. When activity is: three label/value rows (`TODAY`, `7 DAYS`,
  `TOP MODEL`), never dimmed.

**Personalization** (added after the first version)

- `CockpitAppearance` holds the title and three colors: the accent (shown to the user as
  "Text color"), the border and the glow. The title is trimmed, shown in capitals and cut
  to 14 characters so the status note still fits beside it; a blank title means the
  default `CLAUDE`. All three colors default to cyan.
- The accent colors the section titles, the status note, the cost and request figures,
  and meters below the warning levels.
- `AppearanceStore` keeps the values in user defaults as plain strings (`title`, and
  `accentColor`, `borderColor` and `glowColor` as `#RRGGBB`), so they can also be set with
  `defaults write`. A missing or unreadable color falls back to the default.
- The first launch shows the Personalize window once (`hasOfferedCustomization`); later
  it is opened from the card's right-click menu. The window is not modal, so the card
  keeps refreshing behind it, and every change is saved and applied immediately.
- The amber and red of meters at 70% and 90% are not configurable, because there the
  color is the warning. Label and secondary text stay white and grey.

**Interaction**

- Drag anywhere to move.
- Click (without dragging) refreshes immediately.
- Right-click menu: Refresh, Customize…, Quit.

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


## Linux

The Linux build is a port, not a second design: the same meters, the same thresholds, the
same refusal to show a number it did not read. `linux/claude_cockpit/` mirrors `CockpitCore` file
for file, and `linux/claude_cockpit/ui/` replaces AppKit with GTK 4.

```
linux/
  pyproject.toml
  install.sh
  packaging/claude-cockpit.desktop, claude-cockpit.service
  claude_cockpit/
    usage.py          # UsageMeter + UsageParser + ResetCountdown
    fetcher.py        # UsageFetcher
    transcripts.py    # TranscriptParser
    pricing.py        # ModelPricing
    cost.py           # ClaudeCostEstimator
    cursor_db.py      # CursorActivityReader
    cursor_usage.py   # CursorUsage + CursorUsageParser + CursorUsageFetcher + TerminalSession
    periods.py        # the week, and local midnight
    config.py         # CockpitAppearance + AppearanceStore
    xdg.py            # the XDG base directories
    app.py            # AppDelegate
    ui/
      window.py       # CockpitPanel
      card.py         # CockpitView + MeterRowView
      customize.py    # CustomizationWindowController
      style.css       # Theme
      fonts.py        # Orbitron registration, through fontconfig
  tests/
```

### What the platform forces to differ

**Window.** `NSPanel` pins itself above every window on every Space and remembers where it
was dragged. Wayland grants a client neither: it cannot place its own surface, and only
`wlr-layer-shell`, which not every desktop implements, grants an overlay layer. Branching
per compositor would mean a widget that behaves differently on each desktop and is
untestable on most, so the Linux build is an ordinary undecorated window and placement is
a compositor rule the README gives for each desktop. Dragging the card is gone with it.

**Blur.** `NSVisualEffectView` has no portable counterpart. The card is translucent and
leaves blur to the compositor, which is where it is configured on Linux anyway.

**Settings.** User defaults become one TOML file at `$XDG_CONFIG_HOME/claude-cockpit/
config.toml`, hand-editable in the same spirit as `defaults write`, written through a
temporary file and a rename so a crash cannot leave it half-written.

**Finding the CLI.** The macOS search — `~/.local/bin`, Homebrew, then a login `zsh` —
becomes `PATH` first, then `~/.local/bin`, the mise, asdf, volta and bun shim directories,
nvm's Node versions, `~/bin`, `/usr/local/bin`, `/usr/bin` and the Flatpak exports, then
the `PATH` of the login `$SHELL`. Version managers are how Claude Code is usually installed
on Linux, and their shims are exactly what a desktop launcher's minimal `PATH` leaves out.
The login shell is asked only to print its `PATH`, because a lookup written in shell
(`command -v -- "$1"`) fails in fish and nushell. The CLI is then run with its own
directory first on `PATH`, so an npm-installed one finds the `node` beside it.

**Installing.** `install.sh` builds a virtual environment under
`$XDG_DATA_HOME/claude-cockpit/venv` and links the command into `~/.local/bin`. Most
distributions refuse `pip install --user` (PEP 668), and the environment sees the system
site packages because GTK's bindings come from the distribution. The import package is
`claude_cockpit` rather than `cockpit`, a name the Cockpit Project's own Python package
already has.

**Logging.** `os.Logger` becomes the standard library's logging to stderr, which systemd
collects into the journal.

**Fonts.** Orbitron is registered for the process through fontconfig's application font
list — the counterpart of `CTFontManagerRegisterFontsForURL` with `.process` scope — and
the card falls back to the system monospace font if that fails, as on macOS.

**Second launch.** `Gtk.Application` with an application id raises the existing window
instead of starting a second poller. macOS leaves this to the user.

### Two corrections the port made

Both were found by running the Linux build against live data, and both are fixed in the
macOS build too:

- **The reset wording.** The live output had `resets Oct 5, 3:20pm (…)` where the parser
  expected `resets Oct 5 at 3:20pm (…)`, so every countdown fell back to printing the line
  verbatim. Claude Code still prints the ` at ` wording as well, so neither is the old
  one: both parsers accept either separator, and both branches have to stay.
- **The partial-cost marker.** `unpricedModels` is collected over seven days but was shown
  against both rows, so a model used five days ago marked *today's* figure incomplete.
  `ClaudeCost` now carries a window each, with its own set of unpriced models.

### Testing

`linux/tests` covers everything outside `claude_cockpit/ui`, mirroring `Tests/CockpitCoreTests`
and adding: both reset separators, an unknown time zone, the per-window partial-cost rule,
transcript re-reading (an unchanged file is not re-read, an appended one is), local
midnight on the days the clocks change, the login-shell `PATH` lookup, the Cursor `/usage`
screen (parsed from a real capture, and fetched from stand-in CLIs on a real
pseudo-terminal), and the config round trip including a title containing a quote or a
control character. The UI is
verified by running the widget and comparing it against `claude -p "/usage"`.
