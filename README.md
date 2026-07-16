# MiddleShot

macOS menu-bar utility that adds two missing inputs to Magic Mouse and MacBook trackpads:

1. **Middle click** — bound to a finger-count gesture
2. **Area screenshot** (equivalent of `Cmd+Shift+4`) — bound to a different gesture

Personal project. Not on the App Store: depends on the private `MultitouchSupport` framework, so it must be built and sideloaded.

## Gestures

| Action          | Magic Mouse              | MacBook Trackpad        |
| --------------- | ------------------------ | ----------------------- |
| Middle click    | 3-finger **click**       | 4-finger **tap**        |
| Area screenshot | 3-finger **double tap**  | 4-finger **double tap** |

Screenshot shells out to `screencapture -i -u` — area selection saved to wherever macOS is configured to put screenshots (Desktop by default), with the floating thumbnail you can drag straight into a text field. Clipboard-only (`-i -c`) is deliberately not used: it silently drops the thumbnail.

## Requirements

- macOS 13 (Ventura) or later
- Xcode command-line tools (for `swiftc`)

## Build

```bash
./scripts/setup-signing.sh   # one-time: create stable self-signed cert
./build.sh                   # debug build
./build.sh release           # release build
./dist.sh                    # universal release + zip in dist/
open build/MiddleShot.app
```

`setup-signing.sh` creates a self-signed code-signing identity in the login keychain. This gives the bundle a stable Designated Requirement, which means macOS remembers Accessibility / Input Monitoring grants across rebuilds.

## Versioning

`CFBundleShortVersionString` in `MiddleShot/Info.plist` is the marketing version and is bumped by hand. Everything else is stamped automatically by `build.sh` into the built bundle — never into the source plist, so building never dirties the repo:

- `CFBundleVersion` — `git rev-list --count HEAD`, so it increases with every commit
- `MSGitCommit` — short SHA, suffixed `-dirty` when the tree has uncommitted changes

The menu bar header shows all three (`MiddleShot 0.2.0 (18 · efde0e6)`), which is how you tell what a given machine is actually running. `dist.sh` puts the build number in the zip name (`MiddleShot-0.2.0-b18.zip`) so two builds of different code can never collide on one filename.

A `-dirty` suffix means the binary does not correspond to the commit it names — commit before cutting a build you intend to install anywhere.

## Permissions

On first launch, grant in System Settings → Privacy & Security:

- **Accessibility** — synthesize middle-click events
- **Input Monitoring** — read multi-touch frames
- **Screen Recording** — for `screencapture`

The menu has shortcuts to each settings pane.

## Status bar

The icon is the `cursorarrow.click.2` SF Symbol plus the text label `MS`. The label exists so it stays findable when the menu bar is full and items get clipped behind the notch on MacBook Pro / Air. Even with the label, severe notch overflow can hide the icon entirely — hold `Cmd` and drag other menu bar items to make room.

## Caveats

- Uses the private `MultitouchSupport` framework. Symbols can change between macOS major releases.
- Self-signed, so Gatekeeper blocks the first launch on any machine that has not seen the app before. Clear it once with `xattr -dr com.apple.quarantine /Applications/MiddleShot.app`, or go to System Settings → Privacy & Security → "Open Anyway" after the block. Control-click → Open does **not** work: Apple removed that bypass in macOS 15 Sequoia.
- Not notarized, and for our own machines it does not need to be. The Designated Requirement is `identifier "app.middleshot" and certificate leaf = H"<cert hash>"` — pinned to the cert, not to the binary — so TCC keeps Accessibility / Input Monitoring / Screen Recording grants across updates on every machine, exactly as it does here. Developer ID + notarization would only remove the one-time quarantine step. It would matter if the app were ever handed to someone outside the household.
