#!/usr/bin/env bash
# Builds a universal release and packages it for installing on our other Macs.
#
# Output: dist/MiddleShot-<ver>-b<build>.zip with MiddleShot.app + INSTALL.txt,
# copied to ~/Dropbox/Apps so the other Macs can just pull it out of Dropbox.
# Override that destination with MIDDLESHOT_PUBLISH_DIR=/somewhere ./dist.sh.
#
# Note: the bundle is signed with our self-signed cert, which is NOT trusted by
# Gatekeeper on a machine that has never seen it, so first launch there needs
# the quarantine flag cleared (INSTALL.txt walks through it). Control-click →
# Open is NOT a way around it — Apple removed that bypass in macOS 15 Sequoia.
# Developer ID + notarization would drop that one-time step, but it buys
# nothing else for machines we own: the Designated Requirement is pinned to
# this cert's hash, so TCC grants already survive updates on every machine.
set -euo pipefail

cd "$(dirname "$0")"

DIST_DIR="dist"
PUBLISH_DIR="${MIDDLESHOT_PUBLISH_DIR:-$HOME/Dropbox/Apps}"

echo "Building universal release…"
./build.sh release universal

# Read the version back out of the BUILT bundle, not the source plist: build.sh
# stamps CFBundleVersion from git, and the zip name has to carry it so two
# builds of different code can't land on the same filename (they did before —
# every build was "MiddleShot-0.1.0.zip" no matter what changed).
BUILT_PLIST="build/MiddleShot.app/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_PLIST")"
GIT_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :MSGitCommit' "$BUILT_PLIST")"

case "$GIT_COMMIT" in
  *-dirty)
    echo "WARNING: building from a dirty tree — this zip will not match any commit." >&2
    ;;
esac

NAME="MiddleShot-$VERSION-b$BUILD_NUMBER"
STAGING="$DIST_DIR/$NAME"
ZIP_PATH="$DIST_DIR/$NAME.zip"

rm -rf "$STAGING" "$ZIP_PATH"
mkdir -p "$STAGING"
cp -R build/MiddleShot.app "$STAGING/"

cat > "$STAGING/INSTALL.txt" <<EOF
MiddleShot $VERSION (build $BUILD_NUMBER, $GIT_COMMIT) — macOS 13 (Ventura) or later

Verify what a machine ended up with: menu bar icon → the header line shows
this same version, build number and commit.

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
(cd "$DIST_DIR" && zip -qr "$NAME.zip" "$NAME")
rm -rf "$STAGING"

SIZE=$(du -h "$ZIP_PATH" | awk '{print $1}')
echo
echo "✓ $ZIP_PATH  ($SIZE)"

# Drop a copy where the other Macs can reach it. The zip name carries the build
# number, so older builds stay put rather than being overwritten — delete the
# stale ones by hand when you no longer want to be able to roll back to them.
if [ -d "$PUBLISH_DIR" ]; then
  cp "$ZIP_PATH" "$PUBLISH_DIR/"
  echo "✓ published to $PUBLISH_DIR/$NAME.zip"
else
  echo "! $PUBLISH_DIR not found — zip is in $DIST_DIR only" >&2
fi

echo
echo "Share that zip. Recipient follows INSTALL.txt inside it."
