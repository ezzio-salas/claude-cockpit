# Claude Cockpit

A small frameless macOS widget that floats above your windows and shows how much of your
Claude plan you have used.

<img src="docs/preview.png" alt="Claude Cockpit showing session and weekly usage meters" width="288">

It shows one meter for each limit that Claude Code's `/usage` command reports — the current
session, the week, and any per-model weekly limit — with the percentage used and the time
left until it resets.

## Requirements

- macOS 14 or later
- Swift 5.9 or later (Xcode, or the Command Line Tools: `xcode-select --install`)
- [Claude Code](https://claude.com/claude-code) installed and signed in with a Claude
  subscription. Check with:

  ```sh
  claude -p "/usage"
  ```

  You should see lines such as `Current session: 18% used · resets …`. If you don't, the
  widget has nothing to show.

## Setup

```sh
git clone https://github.com/ezzio-salas/claude-cockpit.git
cd claude-cockpit
./build.sh
open ClaudeCockpit.app
```

`build.sh` compiles a release build and assembles `ClaudeCockpit.app` in the project folder.
The app is self-contained, so you can move it to `/Applications` afterwards.

To start it when you log in, add `ClaudeCockpit.app` under
**System Settings → General → Login Items & Extensions → Open at Login**.

## Using it

The app has no Dock icon and no menu bar item; the floating card is the whole interface.

| Action | Result |
| --- | --- |
| Drag the card | Moves it. The position is remembered between launches. |
| Click the card | Refreshes now. `SYNC` shows in the header while it reads. |
| Right-click the card | Menu with **Refresh** and **Quit Claude Cockpit**. |

The card stays above other windows on every Space, including full-screen apps, and never
takes keyboard focus.

Usage is re-read every 60 seconds. Bar colors follow the percentage used:

| Used | Color |
| --- | --- |
| below 70% | cyan |
| 70% to 89% | amber |
| 90% and above | red |

### When a read fails

The widget only ever shows numbers it actually read from Claude.

- If it has an earlier reading, it keeps showing it dimmed, with `STALE · 2m` (time since
  the last good read) in the header. The next successful read clears it.
- If it has no reading yet, it shows one of these instead of meters:

| Message | Meaning |
| --- | --- |
| `READING USAGE` | The first read is in progress. |
| `CLAUDE CLI NOT FOUND` | No `claude` executable was found. See [Troubleshooting](#troubleshooting). |
| `TIMED OUT` | The CLI did not answer within 20 seconds. |
| `COULD NOT READ USAGE` | The CLI exited with an error, for example when signed out. |
| `UNRECOGNIZED OUTPUT` | The CLI answered, but without any usage lines. |

## How it works

Every refresh runs the Claude Code CLI without a terminal:

```sh
claude -p "/usage" --no-session-persistence --setting-sources "" --strict-mcp-config
```

The extra flags keep the call light: no session is saved, and your hooks, plugins and MCP
servers are not loaded. The widget parses the `Current …: N% used · resets …` lines from
the output and ignores the rest.

The app never reads your credentials and makes no network requests of its own; signing in
is handled entirely by the CLI.

## Troubleshooting

**`CLAUDE CLI NOT FOUND`** — Apps started from Finder do not inherit your shell's `PATH`.
The widget looks for `claude` in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`,
then asks a login `zsh` (`command -v claude`). Make sure `claude` is in one of those places
or on the `PATH` of your login shell.

**macOS asks for permission at launch** — If the app lives on an external drive, macOS
asks whether Claude Cockpit may access files on a removable volume. The first read waits
behind that prompt and can show `TIMED OUT`; answer it, then click the card to refresh.
The app is signed ad hoc, so macOS asks again after each rebuild.

**Seeing why a read failed** — Failures are logged. In `zsh`, call `log` by its full path,
because `log` is also a shell builtin:

```sh
/usr/bin/log show --last 10m --predicate 'subsystem == "local.claude-cockpit"'
```

**The meters disappeared after a Claude Code update** — The widget depends on the wording
of the `/usage` output. If that changes, the widget shows `UNRECOGNIZED OUTPUT` and
`UsageParser` needs updating.

## Development

```sh
swift test                # unit tests for parsing, countdowns and the CLI runner
swift run ClaudeCockpit   # run without building the .app bundle
./build.sh                # build ClaudeCockpit.app
```

Run with `swift run`, the widget uses the system monospaced font, because Orbitron is only
bundled into the `.app`.

| Path | Contents |
| --- | --- |
| `Sources/CockpitCore` | Parsing, countdown text and the CLI runner. No UI, fully unit-tested. |
| `Sources/ClaudeCockpit` | The AppKit panel and views. |
| `Tests/CockpitCoreTests` | Unit tests. |
| `Resources` | The Orbitron font and its license. |
| `docs/design.md` | The design notes the app was built from. |

## Credits

Labels are set in [Orbitron](https://fonts.google.com/specimen/Orbitron), used under the
SIL Open Font License (`Resources/Orbitron-OFL.txt`).
