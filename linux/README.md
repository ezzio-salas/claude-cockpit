# Claude Cockpit for Linux

A small frameless widget that shows how much of your Claude plan you have used, what that
usage would cost at API prices, and how much you have been using Cursor's agent.

It is the Linux build of [Claude Cockpit](../README.md); the macOS build is in
[`../macos`](../macos). Both read the same numbers the same way, and the differences are
listed under [Differences from the macOS build](#differences-from-the-macos-build).

## Requirements

- Python 3.11 or later
- GTK 4 and its Python bindings

  | Distribution | Command |
  | --- | --- |
  | Arch | `sudo pacman -S gtk4 python-gobject` |
  | Debian / Ubuntu | `sudo apt install gir1.2-gtk-4.0 python3-gi` |
  | Fedora | `sudo dnf install gtk4 python3-gobject` |
  | openSUSE | `sudo zypper install gtk4 python3-gobject` |

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
cd claude-cockpit/linux
./install.sh
claude-cockpit
```

`install.sh` puts the app in a virtual environment of its own under
`~/.local/share/claude-cockpit`, links the `claude-cockpit` command into `~/.local/bin`,
and adds a desktop entry and a systemd user unit. On Debian and Ubuntu the virtual
environment needs `sudo apt install python3-venv` first. To start it with your graphical
session:

```sh
systemctl --user enable --now claude-cockpit.service
```

To run it from the source tree without installing anything:

```sh
python3 -m claude_cockpit
```

## Using it

The card is the whole interface. There is no tray icon and no menu bar entry.

| Action | Result |
| --- | --- |
| Click the card | Refreshes now. `SYNC` shows in the header while it reads. |
| Right-click the card | Menu with **Refresh**, **Customize…** and **Quit Claude Cockpit**. |

Launching it a second time raises the window you already have rather than starting a
second poller.

Usage is re-read every 60 seconds. Bar colors follow the percentage used:

| Used | Color |
| --- | --- |
| below 70% | cyan, or your [text color](#personalizing) |
| 70% to 89% | amber |
| 90% and above | red |

### Keeping it in place

A Wayland client cannot position its own window or pin itself above others, so the
compositor decides where the card goes. One rule does it, and the window is matched by the
application id `dev.ezzio.ClaudeCockpit`.

**Hyprland** — the rule syntax depends on the version (`hyprctl version`). From 0.53, in
`~/.config/hypr/hyprland.conf`:

```conf
windowrule {
    name = claude-cockpit
    match:class = ^(dev\.ezzio\.ClaudeCockpit)$
    float = yes
    pin = yes
    move = monitor_w-306 60
    no_blur = yes
}
```

From 0.55, if you have moved to `~/.config/hypr/hyprland.lua`:

```lua
hl.window_rule({
  name    = "claude-cockpit",
  match   = { class = "dev.ezzio.ClaudeCockpit" },
  float   = true,
  pin     = true,
  move    = { "monitor_w-306", "60" },
  no_blur = true,
})
```

Before 0.53:

```conf
windowrulev2 = float, class:^(dev\.ezzio\.ClaudeCockpit)$
windowrulev2 = pin, class:^(dev\.ezzio\.ClaudeCockpit)$
windowrulev2 = move 100%-306 60, class:^(dev\.ezzio\.ClaudeCockpit)$
windowrulev2 = noblur, class:^(dev\.ezzio\.ClaudeCockpit)$
```

Leave out `no_focus` (`nofocus`): the card is used by clicking it.

The card draws its own border and glow. If your theme also draws them — Omarchy's
Tron Legacy theme puts a cyan bloom around the focused window, for example — you get two.
Turn the compositor's off for this window by adding `no_shadow`, `border_size = 0` and
`rounding = 0` to the rule — or, before 0.53:

```conf
windowrulev2 = noshadow, class:^(dev\.ezzio\.ClaudeCockpit)$
windowrulev2 = noborder, class:^(dev\.ezzio\.ClaudeCockpit)$
windowrulev2 = norounding, class:^(dev\.ezzio\.ClaudeCockpit)$
```

**Sway** — in `~/.config/sway/config`:

```
for_window [app_id="dev.ezzio.ClaudeCockpit"] floating enable, sticky enable, border none
```

**KDE Plasma** — System Settings → Window Management → Window Rules → New, match the
window class `dev.ezzio.ClaudeCockpit`, then set *Keep above other windows* to Yes and
*No titlebar and frame* to Yes.

**GNOME** — GNOME has no built-in window rules. The extension
[Always on Top (Window)](https://extensions.gnome.org) adds a keep-above toggle, or run
the widget on a workspace of its own.

**X11, any desktop** — `wmctrl -r "Claude Cockpit" -b add,above,sticky`.

### When a read fails

The widget only ever shows numbers it actually read from Claude.

- If it has an earlier reading, it keeps showing it dimmed, with `STALE · 2m` (time since
  the last good read) in the header. The next successful read clears it.
- If it has no reading yet, it shows one of these instead of meters:

| Message | Meaning |
| --- | --- |
| `READING USAGE` | The first read is in progress. |
| `CLAUDE CLI NOT FOUND` | The CLI executable was not found. See [Troubleshooting](#troubleshooting). |
| `TIMED OUT` | The CLI did not answer within 20 seconds. |
| `COULD NOT READ USAGE` | The CLI exited with an error, for example when signed out. |
| `UNRECOGNIZED OUTPUT` | The CLI answered, but without any usage lines. |

## Personalizing

The first time the app opens, a **Personalize Claude Cockpit** window offers four
settings. Close it to keep the defaults; open it again any time with right-click →
**Customize…**.

| Setting | Default | Notes |
| --- | --- | --- |
| Title | `CLAUDE` | Shown in capitals, up to 14 characters. Leave it blank for the default. |
| Text color | cyan (`#4FE8FF`) | The titles, the cost and request figures, and meters below 70%. |
| Border color | cyan (`#4FE8FF`) | The thin outline of the card. |
| Glow color | cyan (`#4FE8FF`) | The soft halo around the card. |

Changes show on the card as you make them and are saved immediately. **Reset to Defaults**
restores all four. Meters at 70% and above stay amber and red whatever text color you
pick, because there the color is the warning.

Everything lives in one file you can also edit by hand, at
`~/.config/claude-cockpit/config.toml`. Relaunch the app after editing it:

```toml
title = "WORK"
accent_color = "#B6FF5C"
border_color = "#FF4FD8"
glow_color = "#FF9A3D"
```

## Estimated cost

Two rows under the meters show what your Claude Code usage would have cost at Anthropic's
API list prices:

| Row | Meaning |
| --- | --- |
| `TODAY` | Usage since midnight, for example `~$8.40 API EQ`. |
| `7 DAYS` | Usage over the last seven days. |

`API EQ` stands for API equivalent. **It is not a charge.** A subscription is not billed
per token, so this figure only tells you how much usage you are getting out of your plan.

The estimate comes from the token counts Claude Code records in its transcripts
(`~/.claude/projects`), multiplied by the price of the model that produced each reply.
Keep in mind:

- It covers Claude Code on this machine only, not other devices or claude.ai.
- If several Claude profiles share one transcripts folder, their usage is added together.
- Prices are built into the app (`claude_cockpit/pricing.py`, as published in September 2026) and
  need updating when Anthropic changes them. Fast mode is priced at the standard rate.
- A trailing `+`, as in `~$12+`, means some usage in *that row's* period came from a model
  the app has no price for, so the true figure is higher. The model's name is logged.

The rows are hidden when the transcripts folder does not exist.

## Cursor activity

When Cursor is installed, the card gains a **CURSOR** section:

| Row | Meaning |
| --- | --- |
| `TODAY` | Agent requests since midnight that produced code. |
| `7 DAYS` | The same count over the last seven days. |
| `TOP MODEL` | The model behind the most of those requests in the last seven days. |

These numbers are activity, not a quota. Cursor has no local equivalent of Claude's
`/usage`, so the widget counts requests from the database Cursor keeps on your machine for
attributing code to AI (`~/.cursor/ai-tracking/ai-code-tracking.db`). That has two
consequences:

- Only requests that wrote code are counted. Questions the agent answered without editing
  a file do not appear.
- Only this machine is counted, not other devices or Cursor's web agents.

The section needs no setup and is hidden when that database does not exist.

## Using another Claude profile

By default the widget runs `claude`. To read usage for a different account or config
directory, point it at another command in `~/.config/claude-cockpit/config.toml` and
relaunch:

```toml
cli_command = "claude-work"
```

The value is either a command name, found the same way `claude` is (see
[Troubleshooting](#troubleshooting)), or a path to an executable such as
`~/bin/claude-work`.

It has to be an executable file. A shell alias or function will not work, because those
exist only inside an interactive shell. A small wrapper script does the job:

```sh
#!/bin/bash
# ~/.local/bin/claude-work — Claude Code with a separate config directory
export CLAUDE_CONFIG_DIR="$HOME/.claude-work"
exec "$HOME/.local/bin/claude" "$@"
```

Call `claude` by its full path inside the script (`command -v claude` shows it). Make the
script executable with `chmod +x ~/.local/bin/claude-work`.

The cost estimate reads transcripts from `~/.claude/projects`. If your other profile keeps
its own, point the estimate at them as well:

```toml
transcripts_directory = "~/.claude-work/projects"
```

## How it works

Every refresh runs the Claude Code CLI without a terminal:

```sh
claude -p "/usage" --no-session-persistence --setting-sources "" --strict-mcp-config
```

The extra flags keep the call light: no session is saved, and your hooks, plugins and MCP
servers are not loaded. The widget parses the `Current …: N% used · resets …` lines from
the output and ignores the rest.

The cost estimate reads only the token counts and model names from Claude Code's local
transcripts. Cursor activity comes from a read-only query of Cursor's local SQLite
database.

The app never reads your credentials and makes no network requests of its own; signing in
to Claude is handled entirely by the CLI, and the cost and Cursor numbers never leave your
machine.

## Differences from the macOS build

| | macOS | Linux |
| --- | --- | --- |
| Always on top, on every workspace | Built in (`NSPanel`) | A [compositor rule](#keeping-it-in-place) |
| Position | Drag the card; remembered | Set by the compositor |
| Background blur | `NSVisualEffectView` | A translucent card; blur is the compositor's to add |
| Settings | `defaults write local.claude-cockpit …` | `~/.config/claude-cockpit/config.toml` |
| Logs | `log show --predicate 'subsystem == "local.claude-cockpit"'` | stderr, so `journalctl --user -u claude-cockpit` under systemd |
| Second launch | Starts a second widget | Raises the first |

Wayland is the reason for the first three: a client cannot place its own surface or raise
itself above others, and only `wlr-layer-shell` — which not every desktop implements —
grants an overlay layer. Rather than behave differently on each compositor, the widget is
an ordinary window and leaves placement to a rule you write once.

## Troubleshooting

**`CLAUDE CLI NOT FOUND`** — A desktop launcher or a systemd unit starts with a minimal
`PATH`, so the widget looks for the command on `PATH`, then in `~/.local/bin`, mise, asdf,
volta and bun shim directories, nvm's Node versions, `~/bin`, `/usr/local/bin`, `/usr/bin`
and the Flatpak exports, and finally on the `PATH` your login shell reports. If `claude`
lives somewhere else, give its full path as `cli_command`.

**Seeing why a read failed** — Failures are logged to stderr:

```sh
journalctl --user -u claude-cockpit -n 50     # when started by systemd
python3 -m claude_cockpit                     # or just run it in a terminal
```

**The meters disappeared after a Claude Code update** — The widget depends on the wording
of the `/usage` output. If that changes, it shows `UNRECOGNIZED OUTPUT` and
`claude_cockpit/usage.py` needs updating.

**The card has two borders or two glows** — Your compositor is drawing its own. See
[Keeping it in place](#keeping-it-in-place).

**Labels show in a plain monospace font** — Orbitron is loaded through fontconfig, from the
copy installed with the package (`../assets/Orbitron.ttf` in a source checkout). If that file is missing, or fontconfig is unavailable, the card falls
back to your monospace font. Run in a terminal to see the warning.

## Development

```sh
python3 -m venv --system-site-packages .venv   # GTK comes from the system
.venv/bin/pip install -e '.[dev]'
.venv/bin/python -m pytest                     # unit tests for everything outside claude_cockpit/ui
python3 -m claude_cockpit                      # run it
```

| Path | Contents |
| --- | --- |
| `claude_cockpit/` | Usage parsing, the CLI runner, the cost estimator, the Cursor reader and the config. No UI, fully unit-tested. Mirrors `macos/Sources/CockpitCore`. |
| `claude_cockpit/ui/` | The GTK4 window, card and Personalize window. Mirrors `macos/Sources/ClaudeCockpit`. |
| `tests/` | Unit tests. |
| `packaging/` | Desktop entry and systemd user unit. |

The modules under `claude_cockpit/` are deliberate one-to-one ports of the Swift files in
`macos/Sources/CockpitCore`. When you change a rule in one — a price, a parser, a
threshold — change it in both.
