# MiddleShot

macOS menu-bar utility that adds two missing features to Magic Mouse and MacBook trackpads:

1. **Middle click** — bound to a finger-count gesture
2. **Area screenshot** (equivalent of `Cmd+Shift+4`) — bound to a different gesture

Plus a **Dashboard** window (menu → Open Dashboard…) for disk usage and CPU / memory, and **Menu Bar Stats** (CPU, memory, network as a live status item) — see their sections below.

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
├── Settings.swift             # UserDefaults-backed prefs (thumbnail, clipboard, dashboard)
├── DashboardWindowController.swift  # Dashboard window, toolbar, Dock/menu-bar policy switch
├── DashboardViews.swift       # shared dashboard views (bars, chips, placeholder, toast)
├── DiskUsageViewController.swift    # Disk tab — top 10 items, Move to Trash + Undo
├── DiskScanner.swift          # parallel folder walk, "largest items" rule, safety labels
├── ProcessesViewController.swift    # CPU & Memory tab — top 10 apps/processes, Force Quit
├── ProcessSampler.swift       # libproc/mach sampling, app grouping, force quit
├── CleanupFinder.swift        # Safe to Clean groups (caches, simulators, build output) + simctl
├── CleanupListController.swift      # Safe to Clean outline view
├── SystemStats.swift          # whole-machine CPU ticks, memory, network + disk counters, disk space
├── MenuBarStatsController.swift     # stats status item: module order/visibility, timer, dropdown, submenu
├── MenuBarModule.swift        # MenuBarModule protocol + dropdown building blocks + history chart
├── MenuBarModules.swift       # CPU, Memory, Network, Disk modules
├── MenuBarDrawing.swift       # shared menu bar geometry, formatting, drawing primitives
├── MenuBarStatsSettingsWindowController.swift  # drag-to-reorder / show-hide window
├── Info.plist
└── MiddleShot-Bridging-Header.h
```

## Dashboard

Two tabs — **Disk** and **CPU & Memory** — each showing a top-10 list with a destructive action per row. Decisions (from the user, 2026-09-13 — don't relitigate):

- **Never refreshes on its own.** No scan or sample runs until Refresh (⌘R) or the empty state's button is pressed — not even on first open. While working, Refresh becomes **Stop** (⌘.); stopping keeps the previous results. Only the "Updated 14:32 · 3 min ago" text ticks (turns orange at 10 min).
- **Dock / ⌘-Tab while open.** Opening switches `NSApp` to `.regular` (drawn Dock icon + a minimal main menu); closing returns to `.accessory` and stops any running scan. The controller lives for the app's lifetime, so results survive closing the window.
- **Disk scope is selectable:** Home Folder (default) or Entire Disk, each keeping its own last result. Skipped (no-access) folders are counted, with a link to Full Disk Access — the app never requires it.
- **CPU & Memory:** Apps (default — helpers folded into their app by bundle path or parent chain) or All Processes. In Apps mode an app row expands: **VS Code-family editors split into one row per window and per Claude Code session**, each with its own Force Quit (a window's = its extension host subtree + terminal programs working inside its folder; the window itself stays open). A window has no id on its extension host (`… Helper (Plugin)` child of the main process), so it is named after the most common working folder (`PROC_PIDVNODEPATHINFO`) of its processes. Main process / renderers / GPU form a "Shared" group that is never force quit piecemeal. Group Force Quit re-checks every PID's start time and kills children first. Root-owned processes can't be measured without privileges (`proc_pid_rusage` fails), so they are left out and counted in the status line rather than shown as zeros.
- **Removal is Move to Trash** (`FileManager.trashItem`) with an Undo toast — never a permanent delete. Force Quit uses `NSRunningApplication.forceTerminate()` for apps, `SIGKILL` otherwise.
- **Always confirm.** Sheets use `hasDestructiveAction`; macOS then assigns no default button, so **Return does nothing and Escape cancels**. Don't bind Return to Cancel by hand — a button holds one key equivalent, and Escape stops working (tested).
- **Protected rows get no button:** macOS paths, standard home folders (Desktop, Library, …), Homebrew (`/opt/homebrew`, `/usr/local`), MiddleShot's bundle, `CoreSimulator/Devices` as a whole, synced-folder roots (Dropbox, CloudStorage, Mobile Documents), anything the user can't delete, `/System`-path processes that aren't apps, and MiddleShot and its child processes.
- **Removal safety (audited 2026-09-13):** nothing is removed without a click + confirmation. `classify` runs protection rules first, then app/tool data, and only then "Rebuildable" — `node_modules`/`Pods`/`.build` are rebuildable only with their marker file beside them; `*/lib/node_modules` and `~/.gradle` are "Review first". **Every path is re-checked at the moment of trashing** (`DiskScanner.refusalReason`: gone, now a symlink, a parent now a link, now protected, or a running app). An entry with several files (emulator `.avd` + `.ini`) moves all-or-nothing. **Force Quit re-verifies the PID's start time** so a reused PID is never signalled. Permanent groups (simulators, runtimes) never get "Clean All" — only "Clean Recommended" or per-row Delete. Unknown simulator folders are never recommended.

- **Safe to Clean** is a second view of the same scan (`CleanupFinder`): only locations a tool recreates on its own, grouped and expandable, with a "Recommended" reason per item. Simulators and runtimes go through `xcrun simctl delete` / `simctl runtime delete` — **permanent**, and the sheet says so; everything else is Move to Trash with Undo. A project folder (node_modules, Pods, build, …) only counts when its marker file (package.json, Podfile, build.gradle, …) sits next to it, and never under ~/Library or a dot-folder (a node_modules in ~/.vscode belongs to an installed tool).

Disk scan notes (`DiskScanner.swift`):

- "Largest items" = for a threshold S, the deepest items still ≥ S (none of their children is), with S lowered by binary search until 10 qualify — non-overlapping by construction. *Atomic* folders (DerivedData, node_modules, Caches, packages, …) count as one item; *container* folders (Library, Application Support, /Applications, …) never qualify themselves.
- The walk is I/O-bound (`du -sk ~` is as slow as one FileManager enumerator: ~160 s for 2M files here), so the top two levels are listed serially and everything below is walked with `concurrentPerform` → ~25–40 s.
- **Never download from iCloud.** Listing a *dataless* folder (an evicted `.epub` in Books, a package in iCloud Drive, anything under iCloud Desktop & Documents) makes the kernel block in `getattrlistbulk` until the whole thing downloads — a scan hung there indefinitely (2026-09-18), and Stop can't interrupt a thread stuck in a syscall. Every scanning thread runs under `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, …_OFF)` (restored afterwards, since GCD reuses the thread), so those calls fail at once with `EDEADLK` and count as skipped. Don't measure iCloud folders with `find`/`du` from a shell either — they have no such policy and trigger downloads.
- **Photos and iCloud Drive are opt-in** (checkboxes beside the scope popup, both off by default, `Settings.diskScanInclusions`): `*.photoslibrary` and `~/Library/Mobile Documents` + `~/Library/CloudStorage` are skipped otherwise. Neither is cleaned from here, and Photos alone is hundreds of thousands of files. The status line names whatever was left out ("Photos Library and iCloud Drive not included") so the totals aren't mysteriously short. A change takes effect on the next Refresh.
- Entire Disk must skip `/System/Volumes`, `/Volumes`, and the root mirrors `/.nofollow`, `/.resolve`, `/.vol`, plus anything on another volume — otherwise the Data volume is counted two or three times. **FileManager reports `/.nofollow` as `"/.nofollow/"` (trailing slash)**, so compare normalized paths.

## Menu Bar Stats

One status item (left of MiddleShot's own) built from **modules** — Network, Memory, CPU, Disk today; more coming (e.g. Magic Mouse battery). Decisions from the user, 2026-09-13:

- **One combined item**, not one per metric. Modules can be **reordered (drag) and shown/hidden (checkbox)** in "Reorder & Customize…"; order is left→right in the bar and top→bottom in the dropdown. Hiding all removes the item.
- **Adding a stat = one class conforming to `MenuBarModule`** (id, title, symbol, `sample`, `part(style:color:)`, `menuSection`, …) plus one line in `MenuBarStatsController.modules`. Order/visibility live in `Settings.menuBarModuleOrder` / `menuBarModulesEnabled` keyed by module `id` — never rename an id. Only shown modules sample.
- **Disk** shows free space on the startup disk (GB, bar turns orange < 10 % free, red < 5 %; re-read every 30 s and on menu open). External drives appear **only in the dropdown**, along with read/write rates (IOBlockStorageDriver statistics, disk images excluded) and the Dashboard's last Safe to Clean total.
- **All three styles selectable** — Graphs & Numbers (iStat-like), Numbers Only, Icons Only (the same full-size icons without the MEM/CPU labels; network keeps its rates, the user wants to see how much is used) — plus Color Graphs on/off (off = template image, tinted by macOS).
- **Refreshes itself every 1 s by default** (2 / 5 s selectable) — the one deliberate exception to the Dashboard's manual refresh. Each tick is only `host_statistics`, `host_statistics64`, and one `NET_RT_IFLIST2` sysctl; the per-process sample behind "Using the most CPU/memory" runs only while the dropdown is open.
- **Network counts `en*` only** — no VPN (`utun*`), since tunnelled traffic already crosses a physical port. Use `NET_RT_IFLIST2` (`if_msghdr2` / 64-bit `if_data64`); `getifaddrs`' `if_data` is 32-bit and wraps at 4 GB.
- **Every part of the image has a fixed width** measured against its widest value, so changing numbers never shift other menu bar icons.
- **CPU alert** (user-approved design, 2026-09-13): a bubble (`NSPopover`, stays until ✕) under the CPU graph when an app stays over the threshold — **100 % of one core by default (80/150/200 selectable) for a sustained minute**, checked every 5 s from per-process CPU-time deltas (`CPUAlertMonitor`, no 1 s sampling pause). The CPU bars turn orange with a dot (the dot is what shows in monochrome). Only processes inside an app's bundle count toward that app; a stray process (a node server under Terminal) is its own entry, so Force Quit never takes a terminal down with it. ✕ silences that streak until the app calms down; "Ignore <app>" persists (`Settings.cpuAlertIgnored`, clearable in the settings window); "Force Quit…" still confirms and re-verifies the PID's start time. System-path processes and MiddleShot are never flagged.
- **Rendering cost:** measured on this Mac (M-series, release build): stats off 0.2 % of one core / 15 MB; on at 1 s ≈ 2.4 % / 21 MB; at 2 s ≈ 1.6 %. Most of it is macOS re-compositing the status item (vImage blur, CA commit) on every image change, not our readings. The image is drawn once into a bitmap and skipped entirely when every part's `key` is unchanged. **Don't force a redraw from the button's `effectiveAppearance` KVO** — setting the image fires it, and a forced redraw there looped at 56 % CPU.
- **Everything shares one vertical band** (`bandBottom`…`bandTop` in the renderer): icon tops and cap tops meet the top, icon bottoms and the lowest baselines meet the bottom. Text is placed by baseline (`draw(at:)` origin = baseline + descender), never by eyeballed y offsets.
- **Hover bubbles:** resting the pointer on a part for 0.4 s shows that module's dropdown section in an `NSPopover` (the section view is borrowed while the menu is closed and handed back on close/click); it stays while the pointer is inside it and closes 0.3 s after leaving; a click still opens the full menu, and no bubble reappears until the pointer has left the item. **A tracking area on the status button never fires on macOS 26** — status items are hosted by Control Center in another process — so hover uses global + local `mouseMoved` monitors tested against the button's screen frame.
- **Nothing clickable inside the dropdown's custom views** — clicks on views in an `NSMenuItem.view` aren't delivered reliably (tested: a row view never got its click). Actions are real menu items from `MenuBarModule.actionMenuItems()` (e.g. Disk's "Safe to Clean · 84 GB"), inserted above "Open Dashboard…".
- Clicking opens the detail dropdown (60-sample graphs with hover readouts, memory breakdown, top apps, Open Dashboard…, and the same settings submenu as MiddleShot's menu). The timer runs in `.common` mode so it keeps updating while the menu is tracked.

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
