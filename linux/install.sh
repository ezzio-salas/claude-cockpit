#!/bin/bash
# Installs Claude Cockpit for the current user.
set -euo pipefail
cd "$(dirname "$0")"

if ! python3 -c 'import gi; gi.require_version("Gtk", "4.0"); from gi.repository import Gtk' 2>/dev/null; then
  echo "GTK 4 and its Python bindings are missing. Install them first:" >&2
  echo "  Arch     sudo pacman -S gtk4 python-gobject" >&2
  echo "  Debian   sudo apt install gir1.2-gtk-4.0 python3-gi" >&2
  echo "  Fedora   sudo dnf install gtk4 python3-gobject" >&2
  exit 1
fi

python3 -m pip install --user --upgrade .

applications="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$applications"
cp packaging/claude-cockpit.desktop "$applications/"

units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$units"
cp packaging/claude-cockpit.service "$units/"

echo "Installed. Start it with:  claude-cockpit"
echo "Start it at login with:    systemctl --user enable --now claude-cockpit.service"
