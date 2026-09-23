import Foundation

/// User-facing preferences, backed by UserDefaults so they survive relaunch.
///
/// Kept as a plain namespace rather than an observable object: there is exactly
/// one reader (ActionHandler, on main) and one writer (the status bar menu, on
/// main), so nothing needs to observe anything.
enum Settings {
    private static let showsScreenshotThumbnailKey = "showsScreenshotThumbnail"
    private static let copiesScreenshotToClipboardKey = "copiesScreenshotToClipboard"
    private static let screenshotFolderKey = "screenshotFolder"
    private static let dashboardTabKey = "dashboardTab"
    private static let diskScanScopeKey = "diskScanScope"
    private static let showsAllProcessesKey = "showsAllProcesses"
    private static let diskShowsCleanupKey = "diskShowsCleanup"
    private static let diskScanInclusionsKey = "diskScanInclusions"
    private static let menuBarModuleOrderKey = "menuBarModuleOrder"
    private static let menuBarModulesEnabledKey = "menuBarModulesEnabled"
    private static let menuBarStatsStyleKey = "menuBarStatsStyle"
    private static let menuBarColorGraphsKey = "menuBarColorGraphs"
    private static let menuBarUpdateIntervalKey = "menuBarUpdateInterval"
    private static let cpuAlertEnabledKey = "cpuAlertEnabled"
    private static let cpuAlertThresholdKey = "cpuAlertThreshold"
    private static let cpuAlertIgnoredKey = "cpuAlertIgnored"

    /// Whether an area screenshot presents the floating thumbnail (`-u`) or
    /// saves straight to the screenshot folder with no UI.
    ///
    /// Defaults to **false** — a silent save is the point of the app for most
    /// captures, and the thumbnail's only real advantage (drag it into a text
    /// field) costs a few seconds of waiting for it to fade otherwise. An
    /// unset key reads as false, so no `register(defaults:)` is needed.
    static var showsScreenshotThumbnail: Bool {
        get { UserDefaults.standard.bool(forKey: showsScreenshotThumbnailKey) }
        set { UserDefaults.standard.set(newValue, forKey: showsScreenshotThumbnailKey) }
    }

    /// Whether a silent capture also lands on the clipboard, ready to paste.
    ///
    /// Defaults to **true**, so an unset key has to be told apart from a stored
    /// `false` — `bool(forKey:)` alone would read both as off.
    ///
    /// Has no effect in thumbnail mode: there the file's location is
    /// screencapture's secret, and the thumbnail can be dragged instead.
    static var copiesScreenshotToClipboard: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: copiesScreenshotToClipboardKey) != nil else {
                return true
            }
            return defaults.bool(forKey: copiesScreenshotToClipboardKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: copiesScreenshotToClipboardKey) }
    }

    /// MiddleShot's own save folder for silent captures, or nil to follow the
    /// system's (⌘⇧4's) `com.apple.screencapture location`. Kept here rather
    /// than written to that domain so choosing it never moves ⌘⇧4's captures.
    ///
    /// Thumbnail mode can't honour it: `-p` reads only the system location,
    /// and passing a path instead is what loses the thumbnail.
    static var screenshotFolder: URL? {
        get {
            UserDefaults.standard.string(forKey: screenshotFolderKey)
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: screenshotFolderKey) }
    }

    /// The dashboard tab that was showing when the window last closed:
    /// 0 is Disk, 1 is CPU & Memory.
    static var dashboardTab: Int {
        get { UserDefaults.standard.integer(forKey: dashboardTabKey) }
        set { UserDefaults.standard.set(newValue, forKey: dashboardTabKey) }
    }

    /// What the Disk tab scans. Defaults to the home folder — fast, and needs
    /// no Full Disk Access to be mostly complete.
    static var diskScanScope: DiskScanScope {
        get {
            UserDefaults.standard.string(forKey: diskScanScopeKey)
                .flatMap(DiskScanScope.init(rawValue:)) ?? .home
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: diskScanScopeKey) }
    }

    /// Whether the CPU & Memory tab lists every process instead of apps with
    /// their helpers folded in. Defaults to false (apps).
    static var showsAllProcesses: Bool {
        get { UserDefaults.standard.bool(forKey: showsAllProcessesKey) }
        set { UserDefaults.standard.set(newValue, forKey: showsAllProcessesKey) }
    }

    /// Whether the Disk tab shows Safe to Clean instead of Largest Items.
    static var diskShowsCleanup: Bool {
        get { UserDefaults.standard.bool(forKey: diskShowsCleanupKey) }
        set { UserDefaults.standard.set(newValue, forKey: diskShowsCleanupKey) }
    }

    /// What a disk scan also walks. Defaults to nothing — Photos and iCloud
    /// Drive aren't cleaned from here, and Photos alone slows a scan down.
    static var diskScanInclusions: DiskScanInclusions {
        get { DiskScanInclusions(rawValue: UserDefaults.standard.integer(forKey: diskScanInclusionsKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: diskScanInclusionsKey) }
    }

    // MARK: - Menu bar stats

    /// Module ids, left to right in the menu bar (top to bottom in its menu).
    /// Modules missing from the list — new ones — go after the listed ones.
    static var menuBarModuleOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: menuBarModuleOrderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: menuBarModuleOrderKey) }
    }

    static func isMenuBarModuleEnabled(_ id: String, default fallback: Bool) -> Bool {
        let stored = UserDefaults.standard.dictionary(forKey: menuBarModulesEnabledKey) as? [String: Bool] ?? [:]
        if let enabled = stored[id] { return enabled }
        // Before modules were reorderable each had its own on/off key.
        if let legacy = legacyShowKeys[id], UserDefaults.standard.object(forKey: legacy) != nil {
            return UserDefaults.standard.bool(forKey: legacy)
        }
        return fallback
    }

    static func setMenuBarModule(_ id: String, enabled: Bool) {
        var stored = UserDefaults.standard.dictionary(forKey: menuBarModulesEnabledKey) as? [String: Bool] ?? [:]
        stored[id] = enabled
        UserDefaults.standard.set(stored, forKey: menuBarModulesEnabledKey)
    }

    private static let legacyShowKeys = [
        "cpu": "menuBarShowsCPU", "memory": "menuBarShowsMemory",
        "network": "menuBarShowsNetwork", "disk": "menuBarShowsDisk",
    ]

    static var menuBarStatsStyle: MenuBarStatsStyle {
        get {
            UserDefaults.standard.string(forKey: menuBarStatsStyleKey)
                .flatMap(MenuBarStatsStyle.init(rawValue:)) ?? .graphsAndNumbers
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: menuBarStatsStyleKey) }
    }

    /// Colored graphs by default; off draws everything in the menu bar's own
    /// ink, like system icons.
    static var menuBarColorGraphs: Bool {
        get { bool(menuBarColorGraphsKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: menuBarColorGraphsKey) }
    }

    /// Seconds between readings. 1 s by default — what menu bar monitors such as
    /// Stats ship with; 2 and 5 trade smoothness for a little less work.
    static var menuBarUpdateInterval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: menuBarUpdateIntervalKey)
            return [1, 2, 5].contains(stored) ? stored : 1
        }
        set { UserDefaults.standard.set(newValue, forKey: menuBarUpdateIntervalKey) }
    }

    /// Warn under the CPU graph when an app stays busy (see CPUAlertMonitor).
    static var cpuAlertEnabled: Bool {
        get { bool(cpuAlertEnabledKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: cpuAlertEnabledKey) }
    }

    static let cpuAlertThresholds: [Double] = [80, 100, 150, 200]

    /// Percent of one core an app must stay above for a minute. 100 — a full
    /// core — by default: on a many-core Mac 80 % is everyday browsing.
    static var cpuAlertThreshold: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: cpuAlertThresholdKey)
            return cpuAlertThresholds.contains(stored) ? stored : 100
        }
        set { UserDefaults.standard.set(newValue, forKey: cpuAlertThresholdKey) }
    }

    /// Bundle ids (or executable names) never to warn about — Xcode building
    /// for ten minutes is not news.
    static var cpuAlertIgnored: [String] {
        get { UserDefaults.standard.stringArray(forKey: cpuAlertIgnoredKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: cpuAlertIgnoredKey) }
    }

    /// An unset key reads as `fallback` rather than false.
    private static func bool(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.bool(forKey: key)
    }
}
