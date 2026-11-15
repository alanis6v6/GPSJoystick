#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
bundle="${1:-"$source_dir/GPSJoystick.app"}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/gpsjoystick-build.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT

/usr/bin/xcrun --sdk macosx swiftc \
    -O -swift-version 5 -target "$(/usr/bin/uname -m)-apple-macos14.0" \
    -module-cache-path "$scratch" \
    "$source_dir"/Sources/*.swift "$source_dir"/Shared/*.swift -o "$scratch/GPSJoystick"

/bin/mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
/bin/cp "$scratch/GPSJoystick" "$bundle/Contents/MacOS/"
/bin/cp "$source_dir/Resources/Info.plist" "$bundle/Contents/"
/bin/cp "$source_dir/Resources/iphone_bridge.py" "$bundle/Contents/Resources/"
/usr/bin/install -m 755 "$source_dir/Resources/Setup-iPhone.command" "$bundle/Contents/Resources/"
/usr/bin/codesign --force --sign - "$bundle"
printf 'Built %s\n' "$bundle"
