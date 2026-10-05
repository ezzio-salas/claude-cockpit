#!/bin/bash
# Builds ClaudeCockpit.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"

app="ClaudeCockpit.app"

swift build -c release

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/ClaudeCockpit "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/"
cp ../assets/Orbitron.ttf ../assets/Orbitron-OFL.txt "$app/Contents/Resources/"
codesign --force --sign - "$app"

echo "Built $(pwd)/$app"
