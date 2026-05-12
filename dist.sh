#!/usr/bin/env bash
# Builds a universal release and packages it for sharing to other Macs.
#
# Output: dist/MiddleShot-<ver>.zip containing MiddleShot.app + INSTALL.txt.
#
# Note: the bundle is signed with our self-signed cert, which is NOT trusted
# by Gatekeeper on other Macs. Recipients must right-click → Open → Open
# Anyway on first launch. For a frictionless install, sign with a paid
# Developer ID Application cert and notarize.
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
2. Right-click MiddleShot.app → Open → Open Anyway
   (Gatekeeper warns once because the app uses a self-signed certificate.)
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
