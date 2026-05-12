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

Screenshot uses `screencapture -i -c` — area selection, copied to clipboard.

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
- Self-signed: Gatekeeper warns on first launch on a different Mac. Right-click → Open → Open Anyway.
- No notarization. For a frictionless install, swap in a Developer ID identity and notarize.
