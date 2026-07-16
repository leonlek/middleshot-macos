#!/usr/bin/env bash
# Builds MiddleShot.app with swiftc — no Xcode project needed.
#
# Usage:
#   ./build.sh                 debug, native arch only
#   ./build.sh release         release, native arch only
#   ./build.sh release universal  release, x86_64 + arm64 (for sharing)
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MiddleShot"
SRC_DIR="MiddleShot"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
PRIVATE_FRAMEWORKS="/System/Library/PrivateFrameworks"

MODE="${1:-debug}"
SLICE="${2:-native}"

case "$MODE" in
  debug)   OPT_FLAGS="-Onone -g" ;;
  release) OPT_FLAGS="-O" ;;
  *) echo "usage: $0 [debug|release] [native|universal]"; exit 1 ;;
esac

case "$SLICE" in
  native)
    case "$(uname -m)" in
      arm64)  ARCHES=("arm64") ;;
      x86_64) ARCHES=("x86_64") ;;
      *) echo "unsupported arch: $(uname -m)"; exit 1 ;;
    esac
    ;;
  universal) ARCHES=("arm64" "x86_64") ;;
  *) echo "usage: $0 [debug|release] [native|universal]"; exit 1 ;;
esac

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$SRC_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

# Stamp the build identity into the *bundle's* Info.plist, never the source
# one — deriving it from git keeps the repo clean (no version churn commit per
# build) while guaranteeing every binary built from different code carries a
# different CFBundleVersion. Menu bar → header shows this, so you can tell
# which build a given machine is running without digging through the bundle.
#
# CFBundleVersion must stay a plain integer (macOS parses it), so the commit
# count carries the ordering and the sha lives in MSGitCommit alongside it.
if git -C "$PWD" rev-parse --git-dir >/dev/null 2>&1; then
  BUILD_NUMBER="$(git rev-list --count HEAD)"
  GIT_COMMIT="$(git rev-parse --short HEAD)"
  # A dirty tree means the binary does NOT correspond to the named commit —
  # say so, or you'll chase a "fixed" bug that was never in the build.
  if ! git diff --quiet HEAD -- 2>/dev/null; then
    GIT_COMMIT="$GIT_COMMIT-dirty"
  fi
else
  BUILD_NUMBER="0"
  GIT_COMMIT="nogit"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
  "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MSGitCommit $GIT_COMMIT" \
  "$APP_DIR/Contents/Info.plist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP_DIR/Contents/Info.plist")"
echo "Version $VERSION (build $BUILD_NUMBER, $GIT_COMMIT)"

SOURCES=("$SRC_DIR"/*.swift)
SDK_PATH="$(xcrun --show-sdk-path)"

build_slice() {
  local arch="$1" out="$2"
  swiftc \
    $OPT_FLAGS \
    -target "${arch}-apple-macos13" \
    -sdk "$SDK_PATH" \
    -import-objc-header "$SRC_DIR/MiddleShot-Bridging-Header.h" \
    -F "$PRIVATE_FRAMEWORKS" \
    -framework MultitouchSupport \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework ServiceManagement \
    -framework IOKit \
    -o "$out" \
    "${SOURCES[@]}"
}

if [ "${#ARCHES[@]}" -eq 1 ]; then
  build_slice "${ARCHES[0]}" "$APP_DIR/Contents/MacOS/$APP_NAME"
else
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  for arch in "${ARCHES[@]}"; do
    echo "Compiling $arch slice…"
    build_slice "$arch" "$TMP/$APP_NAME-$arch"
  done
  lipo -create -output "$APP_DIR/Contents/MacOS/$APP_NAME" \
    "$TMP/$APP_NAME-"*
  echo "Lipo'd universal binary: $(lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME")"
fi

# Prefer the stable self-signed identity from scripts/setup-signing.sh — its
# Designated Requirement is stable across rebuilds, so TCC keeps the grant.
# Fall back to ad-hoc signing if the identity isn't installed.
SIGN_IDENTITY="MiddleShot Dev"
if security find-identity -p codesigning -v 2>/dev/null \
   | grep -q "\"$SIGN_IDENTITY\""; then
  codesign --force --deep --sign "$SIGN_IDENTITY" \
    --identifier app.middleshot \
    "$APP_DIR"
  echo "Signed with identity: $SIGN_IDENTITY"
else
  codesign --force --deep --sign - "$APP_DIR"
  echo "Signed ad-hoc (run scripts/setup-signing.sh to stabilize TCC grants)"
fi

echo "Built $APP_DIR"
echo "Run: open $APP_DIR  (or for stdout: ./$APP_DIR/Contents/MacOS/$APP_NAME)"
