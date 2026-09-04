# MiddleShot

macOS menu-bar utility that adds two missing features to Magic Mouse and MacBook trackpads:

1. **Middle click** — bound to a finger-count gesture
2. **Area screenshot** (equivalent of `Cmd+Shift+4`) — bound to a different gesture

## Status

Personal-use project. **Not destined for the Mac App Store** — depends on the private `MultitouchSupport` framework. Build, sign with Developer ID, notarize, sideload.

## Tech Stack

- **Language:** Swift 5.9+
- **UI:** AppKit (no SwiftUI — needs low-level `CGEvent` + private framework access)
- **Min OS:** macOS 13 (Ventura)
- **Build:** Xcode 15+, **zero external dependencies**
- **Status bar app:** `LSUIElement = YES`, no dock icon

## Feature Spec

### Gesture Map (final — decided)

| Action          | Magic Mouse              | MacBook Trackpad      |
| --------------- | ------------------------ | --------------------- |
| Middle click    | 3-finger **click**       | 4-finger **tap**      |
| Area screenshot | 3-finger **double tap**  | 4-finger **double tap** |

**Rationale (do not relitigate without strong reason):**

- **Middle click uses a physical click on Magic Mouse** so the system can distinguish a deliberate trigger from accidentally resting 3 fingers on the surface. On trackpad, 4-finger tap is chosen because 4-finger *swipes* are reserved by macOS for Mission Control / Launchpad, but 4-finger *tap* is free.
- **Screenshot uses double-tap (static, no motion).** This is the critical constraint: macOS routes Magic Mouse finger movement to scroll input in parallel with the MultitouchSupport stream we observe. We can *see* finger frames but cannot *consume* them at the MT layer. Any swipe gesture on Magic Mouse would fire our screenshot **and** scroll the underlying window simultaneously. Static gestures (tap, double-tap, hold) are the only safe options on Magic Mouse. Same gesture used on trackpad for consistency.

### Screenshot Mode

Area selection saved to the system screenshot location (Desktop by default). Two menu bar toggles, persisted in `UserDefaults` via `Settings.swift`, and the first of them picks between two genuinely different `screencapture` invocations:

| `Show Screenshot Thumbnail` | Command | Clipboard |
| --- | --- | --- |
| **off (default)** | `screencapture -i <path>` | copied by us, if `Copy Screenshot to Clipboard` is on (**default on**) |
| on | `screencapture -i -u -p` | not available — drag the thumbnail instead |

Silent mode is the default because waiting out the thumbnail is pure latency when the file is going to the screenshot folder regardless. Thumbnail mode is exactly Cmd+Shift+4.

**A path is what suppresses the thumbnail — that is the whole mechanism, in both directions.**

- `-i` alone (and `-i -u`) refuses to start with `no file specified`; it needs *either* a path *or* `-p`.
- `-p` means "use the default settings for capture", and **those settings include the Screenshot app's own `show-thumbnail` preference**. So `-i -p` presents the thumbnail whenever the user has it enabled, *with no `-u` anywhere*. Measured 2026-09-05 on macOS 15 with `show-thumbnail = 1`: `screencapture -R 0,0,200,200 -p` spawned `screencaptureui` and the file did not appear on disk until the thumbnail expired ~7s later. An earlier note here claimed `-i -p` "saves silently — verified"; it does not, and that wrong line is what made the first cut of the toggle a no-op.
- `-u` therefore cannot be the toggle. It only *adds* the UI on top of a capture that would already have shown it; it can never take it away.

**Thumbnail mode: never pass a file path.** The man page's promise that `-u` makes files "passed to the command line be ignored" only holds while the post-capture UI handoff succeeds. When it loses, `screencapture` silently falls back to writing the capture to that path itself, with no thumbnail — and spawned from this app that fallback is what nearly always happened (the "screenshot taken but no thumbnail" bug). The tell was the filename: our own path stamped a Gregorian year (`Screenshot 2026-…`) while the system UI names files in the user's locale (Buddhist era, `Screenshot 2569-…`). With `-p` there is no path to fall back to.

**Silent mode: always pass a file path**, and drop `-p` — a path means nothing is left to consult `show-thumbnail`. Dropping `-p` also drops the system defaults it was applying for us, so `ScreenshotFile.swift` reads the three that matter back out of the same `com.apple.screencapture` domain (`location`, `name`, `type`) and rebuilds the filename with `Locale.autoupdatingCurrent` — which is what reproduces the Buddhist-era stamp instead of the Gregorian one that gave the old bug away. Cross-domain `UserDefaults(suiteName:)` reads work because the app is not sandboxed.

The clipboard copy is ours, not screencapture's: on a clean exit `ActionHandler` reads the file it named and puts one `NSPasteboardItem` carrying both the image data and its `fileURL`, so editors paste the picture and Finder pastes the file (macOS derives TIFF/JPEG/etc. from the PNG automatically). This is only possible in silent mode — thumbnail mode never learns the path.

**Rejected alternatives (don't relitigate without strong reason):**

- `-i -c` (clipboard-only) as the way to get a clipboard copy: no thumbnail appears *and no file is saved*, so it can serve neither mode. We save a file and copy it ourselves instead.
- Synthesizing Cmd+Shift+Ctrl+4 via `CGEvent` to get clipboard + thumbnail in one shot: WindowServer's symbolic-hotkey handler ignores synthesized modifier+key events on recent macOS. Tested, never fired.
- Flipping the user's `com.apple.screencapture show-thumbnail` off around each capture so `-p` could stay: races with the Screenshot app, and mutates a system setting the user owns. Naming the file is the honest way to opt out.

Remaining knobs (drift threshold, timing windows) are still compile-time constants; a real Settings window can come later if the menu outgrows itself.

## Architecture

```
MiddleShot/
├── AppDelegate.swift          # bootstrap, wire components, request permissions
├── StatusBarController.swift  # menu bar icon + Quit/About menu
├── ActionHandler.swift        # CGEvent middle-click synthesis + screencapture shell-out
├── MagicMouseListener.swift   # MultitouchSupport bridge — enumerates Magic Mouse + trackpad
├── GestureDetector.swift      # state machines: N-finger click / tap / double-tap
├── PermissionHelper.swift     # prompts + status checks for Accessibility / Input / Screen
├── ScreenshotFile.swift       # names the silent capture's destination from com.apple.screencapture
├── Settings.swift             # UserDefaults-backed prefs (thumbnail, clipboard copy)
├── Info.plist
└── MiddleShot-Bridging-Header.h
```

## Private Framework Usage

`/System/Library/PrivateFrameworks/MultitouchSupport.framework`

Linked manually in Xcode (Build Phases → Link Binary With Libraries → Add Other → navigate to that path). Symbols can break on each macOS major release — keep a compatibility note in `MagicMouseListener.swift`.

Key symbols used:

- `MTDeviceCreateList()` → CFArray of active touch devices
- `MTDeviceIsBuiltIn(device)` → 0 = Magic Mouse, 1 = built-in trackpad (use this to differentiate)
- `MTRegisterContactFrameCallback(device, cb)` → register C callback
- `MTDeviceStart(device, runMode)` → begin streaming touch frames
- `MTDeviceStop(device)` → cleanup on shutdown

**The MT callback runs on MultitouchSupport's own thread — always dispatch back to main before posting CGEvents or doing UI work.**

## Gesture Detection Logic

All detection lives in `GestureDetector.swift` as small state machines fed by `MagicMouseListener`.

### Magic Mouse — 3-finger click → middle click
- Maintain `currentFingerCount` from MT frames.
- Install a `CGEventTap` at `.cgSessionEventTap` to observe `leftMouseDown`.
- When `leftMouseDown` arrives AND `currentFingerCount >= 3` → **swallow** the original event (return nil from tap), then post `otherMouseDown` + `otherMouseUp` at the cursor position.

### Trackpad — 4-finger tap → middle click
- Detect finger-count transition `0 → 4 → 0` within ~200ms.
- Require positional stability: max drift < ~15 normalized units (MT coords are 0–1).
- Fire middle click on the `4 → 0` transition.

### Magic Mouse — 3-finger double tap → screenshot
- State machine: `idle → down(3) → up → down(3) → up`, full sequence within ~350ms, fingers roughly stationary throughout (drift < ~15 normalized units, no scroll-like motion).
- Reset on any unexpected count transition, on motion exceeding drift threshold, or on timeout.

### Trackpad — 4-finger double tap → screenshot
- Same state machine with finger count = 4.

Tuning constants live as `static let` at the top of `GestureDetector.swift`. Expect to tune after wearing the gestures for a few days.

## Permissions

Required at runtime, surfaced by `PermissionHelper`:

1. **Accessibility** — to post `CGEvent` clicks and to install a `CGEventTap`.
2. **Input Monitoring** — to receive multitouch frames (macOS 10.15+).
3. **Screen Recording** — required for `screencapture` on macOS 10.15+.

Info.plist usage strings:

- `NSAccessibilityUsageDescription`
- `NSScreenCaptureUsageDescription`

On first launch, open the relevant Settings panes directly:

```swift
NSWorkspace.shared.open(URL(string:
  "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
```

## Build & Run

No Xcode project — `build.sh` drives `swiftc` directly. There are too few sources to justify a `.xcodeproj`, and a hand-written one is more fragile than a 30-line script.

```bash
./build.sh              # debug build
./build.sh release      # optimized
open build/MiddleShot.app
```

The script ad-hoc signs the bundle. macOS *will* remember Accessibility / Input Monitoring grants across rebuilds with ad-hoc signing as long as the bundle identifier stays stable.

For distribution, swap the `codesign --sign -` line for:

```bash
codesign --force --deep --sign "Developer ID Application: <YOUR NAME>" \
  build/MiddleShot.app
```

## Code Conventions

- **Naming:** Apple-style; no Hungarian, no prefixes.
- **Concurrency:** all `CGEvent` posting and AppKit calls on main. MT callbacks immediately `DispatchQueue.main.async` for any user-visible effect.
- **Logging:** `os_log` with subsystem `app.middleshot`, categories `mouse`, `action`, `permission`.
- **Error handling:** `Result` for permission checks; `precondition` for programmer errors; no silent catches.
- **No third-party dependencies.** No SPM, no CocoaPods.

## Known Issues / TBD

- [ ] Tune 3-finger / 4-finger double-tap timing window (starting at 350ms total)
- [ ] Multi-display: `screencapture -i` lets user pick; revisit if annoying
- [ ] Handle Magic Mouse disconnect / reconnect — re-enumerate on `IOHID` device notifications
- [ ] Verify MT symbols on next macOS major (Tahoe, etc.) before upgrading
- [ ] Settings UI for customizing thresholds and screenshot mode (later)

## Don'ts (load-bearing — these have been considered and rejected)

- **Don't suggest SwiftUI.** Needs low-level event APIs that AppKit handles cleanly.
- **Don't suggest App Store.** Private framework dependency is a deal-breaker.
- **Don't suggest `NSEvent.addGlobalMonitorForEvents` for finger counting.** It surfaces clicks/scrolls, not raw multitouch frames.
- **Don't suggest swipe gestures on Magic Mouse.** macOS will scroll the underlying window in parallel — we can observe but not consume MT events.
- **Don't make the MT callback `async`.** It is a C function pointer and must remain a synchronous `@convention(c)` closure.
- **Don't store device references with `Unmanaged.passRetained`** if you don't have a clear release path — leaks add up.
