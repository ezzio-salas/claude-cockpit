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
      CursorActivity.swift
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
- `<when>` has the form `<Mon> <d> at <h>[:mm]<am|pm> (<IANA zone>)`. It is parsed in
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
- Below that, when Cursor activity is available: a `CURSOR` title and three
  label/value rows (`TODAY`, `7 DAYS`, `TOP MODEL`). This section is not dimmed when the
  Claude reading is stale.

**Personalization** (added after the first version)

- `CockpitAppearance` holds the title, the border color and the glow color. The title is
  trimmed, shown in capitals and cut to 14 characters so the status note still fits beside
  it; a blank title means the default `CLAUDE`. Both colors default to the cyan accent.
- `AppearanceStore` keeps the three values in user defaults as plain strings (`title`,
  `borderColor` and `glowColor` as `#RRGGBB`), so they can also be set with `defaults
  write`. An unreadable color falls back to the default.
- The first launch shows the Personalize window once (`hasOfferedCustomization`); later
  it is opened from the card's right-click menu. The window is not modal, so the card
  keeps refreshing behind it, and every change is saved and applied immediately.
- Meter, cost and section-title colors are not configurable; bar colors carry meaning.

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
