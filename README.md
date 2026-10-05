# Claude Cockpit

A small frameless widget that floats above your windows and shows how much of your Claude
plan you have used, what that usage would cost at API prices, and how much you have been
using Cursor's agent.

<img src="docs/preview.png" alt="Claude Cockpit showing Claude usage meters, estimated cost and Cursor activity" width="288">

It shows one meter for each limit that Claude Code's `/usage` command reports — the current
session, the week, and any per-model weekly limit — with the percentage used and the time
left until it resets. Under the meters it estimates the API-equivalent cost of your recent
Claude Code usage. If you use [Cursor](https://cursor.com), a second section shows your
agent activity there.

## Pick your platform

| | |
| --- | --- |
| **[macOS](macos/)** | Swift and AppKit. macOS 14 or later. Floats above every Space on its own. |
| **[Linux](linux/)** | Python and GTK 4. Any desktop. Placement is a one-line compositor rule. |

Each has its own README with setup, personalization and troubleshooting. They read the
same numbers in the same way; [the Linux README lists what differs](linux/README.md#differences-from-the-macos-build).

## What it reads

Nothing leaves your machine, and the app never touches your credentials.

| Source | Used for |
| --- | --- |
| `claude -p "/usage"` | The meters. Signing in is the CLI's job, not the widget's. |
| `~/.claude/projects` | The API-equivalent cost, from the token counts in Claude Code's transcripts. |
| `cursor-agent`, its `/usage` screen | The Cursor plan meters. Signing in is the CLI's job too. |
| `~/.cursor/ai-tracking/ai-code-tracking.db` | Cursor agent activity, read-only. |

The widget only ever shows numbers it actually read. When a read fails it keeps the last
good one, dimmed and marked `STALE`, rather than guessing.

## Layout

```
claude-cockpit/
  macos/      Swift package: Sources/CockpitCore (logic) + Sources/ClaudeCockpit (AppKit)
  linux/      Python package: claude_cockpit/ (logic) + claude_cockpit/ui/ (GTK 4)
  assets/     Orbitron, shared by both builds
  docs/       design.md, preview.png
```

Both builds keep the logic — parsing `/usage`, pricing tokens, reading Cursor's database —
apart from the UI, and the two logic layers are deliberate one-to-one ports of each other.
A rule that changes in one, such as a price or a parser, changes in both.

## Credits

Labels are set in [Orbitron](https://fonts.google.com/specimen/Orbitron), used under the
SIL Open Font License (`assets/Orbitron-OFL.txt`).
