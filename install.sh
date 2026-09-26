#!/usr/bin/env bash
# Builds a release and installs it as /Applications/MiddleShot.app, the copy
# Launch at Login and System Settings › Login Items pick up.
#
# Usage:
#   ./install.sh             build release, install, relaunch
#   ./install.sh --no-build  install whatever is in build/ now
set -euo pipefail

cd "$(dirname "$0")"

APP="build/MiddleShot.app"
DEST="/Applications/MiddleShot.app"

if [[ "${1:-}" != "--no-build" ]]; then
  ./build.sh release
fi
[[ -d "$APP" ]] || { echo "No $APP — build first."; exit 1; }

# Quit every running copy (build/ or /Applications) and wait for it to go:
# replacing a bundle under a running app, or running two at once, both end
# with two event taps answering the same gesture.
for pid in $(pgrep -x MiddleShot || true); do
  kill "$pid" 2>/dev/null || true
done
for _ in $(seq 1 50); do
  pgrep -x MiddleShot >/dev/null || break
  sleep 0.1
done
if pgrep -x MiddleShot >/dev/null; then
  echo "MiddleShot didn't quit — close it and run again."
  exit 1
fi

# Replace, not merge: ditto into an existing bundle would keep files the new
# build no longer has.
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "Installed $DEST (build $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$DEST/Contents/Info.plist"))"

# LaunchServices refuses to open an app it was just told had quit, for a
# moment (-600) — give it a beat.
sleep 1
open "$DEST"
