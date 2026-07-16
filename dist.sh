#!/usr/bin/env bash
# Builds a universal release and packages it for sharing to other Macs.
#
# Output: dist/MiddleShot-<ver>.zip containing MiddleShot.app + INSTALL.txt.
#
# Note: the bundle is signed with our self-signed cert, which is NOT trusted
# by Gatekeeper on other Macs, so recipients must clear the quarantine flag on
# first launch (INSTALL.txt walks through it). Control-click → Open is NOT a
# way around it — Apple removed that bypass in macOS 15 Sequoia. For a
# frictionless install, sign with a paid Developer ID Application cert and
# notarize.
set -euo pipefail

cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' MiddleShot/Info.plist)"
DIST_DIR="dist"
STAGING="$DIST_DIR/MiddleShot-$VERSION"
ZIP_PATH="$DIST_DIR/MiddleShot-$VERSION.zip"

echo "Building universal release…"
./build.sh release universal

rm -rf "$STAGING" "$ZIP_PATH"
mkdir -p "$STAGING"
cp -R build/MiddleShot.app "$STAGING/"

cat > "$STAGING/INSTALL.txt" <<EOF
MiddleShot $VERSION — install on macOS 13 (Ventura) or later

1. Drag MiddleShot.app into /Applications
2. Clear the download quarantine flag, then open it:

       xattr -dr com.apple.quarantine /Applications/MiddleShot.app
       open /Applications/MiddleShot.app

   Gatekeeper blocks the app on first launch because it is signed with a
   self-signed certificate rather than a Developer ID. The command above is
   the one path that works on every macOS 13+ release. If you would rather
   click through it:
     • macOS 15 (Sequoia) and later — double-click, let it be blocked, then
       System Settings → Privacy & Security → scroll down → "Open Anyway".
       Control-clicking → Open does NOT work; Apple removed that bypass.
     • macOS 13–14 — Control-click MiddleShot.app → Open → Open Anyway.
3. Grant the three permissions when prompted:
   • Accessibility       — to synthesize middle-click events
   • Input Monitoring    — to read multi-touch frames
   • Screen Recording    — for the area screenshot
   (System Settings → Privacy & Security → each section, toggle MiddleShot on)
4. Click the cursor icon in the menu bar → "Launch at Login" to auto-start.

Gestures:
   • Magic Mouse, 3-finger CLICK       → middle click
   • Magic Mouse, 3-finger double TAP  → area screenshot
   • Trackpad, 4-finger TAP            → middle click
   • Trackpad, 4-finger double TAP     → area screenshot

To uninstall: quit from the menu, drag MiddleShot.app to Trash, then remove
the entries under System Settings → Privacy & Security.
EOF

echo "Zipping…"
(cd "$DIST_DIR" && zip -qr "MiddleShot-$VERSION.zip" "MiddleShot-$VERSION")
rm -rf "$STAGING"

SIZE=$(du -h "$ZIP_PATH" | awk '{print $1}')
echo
echo "✓ $ZIP_PATH  ($SIZE)"
echo
echo "Share that zip. Recipient follows INSTALL.txt inside it."
