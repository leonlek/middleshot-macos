import Cocoa
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "dashboard")

/// One thing in the Safe to Clean list.
struct CleanupItem {
    enum Action {
        /// Every URL goes to the Trash together (an Android emulator is a
        /// folder plus its .ini).
        case trash([URL])
        /// `simctl delete` — CoreSimulator keeps its own device registry, so
        /// the folder can't just be moved away.
        case deleteSimulator(udid: String)
        /// `simctl runtime delete` — runtimes live in system-owned storage.
        case deleteRuntime(identifier: String)
    }

    let id: String
    let title: String
    let detail: String
    let size: Int64
    let action: Action
    /// Why this is worth removing now, or nil when it's merely safe.
    let recommendation: String?
    /// Why no button is offered (a simulator that is running).
    let blockedReason: String?
    /// File whose Finder icon represents the item; `symbol` is used otherwise.
    let iconPath: String?
    let symbol: String

    var revealURL: URL? {
        if case .trash(let urls) = action { return urls.first }
        return nil
    }

    /// Simulator and runtime deletions skip the Trash.
    var isPermanent: Bool {
        if case .trash = action { return false }
        return true
    }
}

struct CleanupGroup {
    enum Kind: String, CaseIterable {
        case runtimes, simulators, derivedData, deviceSupport, xcodeCaches
        case projectBuilds, packageCaches, appCaches, androidEmulators, logs
    }

    let kind: Kind
    var items: [CleanupItem]

    var size: Int64 { items.reduce(0) { $0 + $1.size } }
    var cleanableItems: [CleanupItem] { items.filter { $0.blockedReason == nil } }
    var recommendedItems: [CleanupItem] { cleanableItems.filter { $0.recommendation != nil } }

    var title: String {
        switch kind {
        case .runtimes: return "Simulator Runtimes"
        case .simulators: return "Simulators"
        case .derivedData: return "Xcode Build Data"
        case .deviceSupport: return "Device Support Files"
        case .xcodeCaches: return "Xcode & Simulator Caches"
        case .projectBuilds: return "Project Dependencies & Build Output"
        case .packageCaches: return "Package Manager Caches"
        case .appCaches: return "App Caches"
        case .androidEmulators: return "Android Emulators"
        case .logs: return "Logs"
        }
    }

    var explanation: String {
        switch kind {
        case .runtimes: return "Whole OS versions for the Simulator. Xcode › Settings › Components downloads them again."
        case .simulators: return "Each simulator with its apps and data. Xcode creates new ones on demand."
        case .derivedData: return "DerivedData — intermediate build files per project. Rebuilt on the next build."
        case .deviceSupport: return "Debug symbols copied from devices you connected. Copied again on the next connection."
        case .xcodeCaches: return "SwiftUI preview simulators and shared Simulator caches. Recreated when needed."
        case .projectBuilds: return "node_modules, Pods, build folders and the like in your projects. Reinstall or rebuild to restore."
        case .packageCaches: return "Downloads kept by Gradle, npm, Homebrew, CocoaPods and others. Downloaded again when needed."
        case .appCaches: return "Files apps keep to load faster. Apps rebuild them."
        case .androidEmulators: return "Virtual devices with their data. Recreate them in Android Studio › Device Manager."
        case .logs: return "Log files apps have written. Nothing needs them to keep working."
        }
    }

    /// What removing items from this group costs — said in the confirmation.
    var consequence: String {
        switch kind {
        case .runtimes: return "Simulators that use a deleted runtime stop working until you download it again in Xcode › Settings › Components."
        case .simulators: return "Each simulator is deleted with every app and file on it. Xcode can create a new one any time."
        case .derivedData: return "Xcode rebuilds this data the next time you build, so that first build is slower."
        case .deviceSupport: return "Xcode copies these symbols again the next time the device connects."
        case .xcodeCaches: return "Quit Xcode and Simulator first — they recreate these caches when needed."
        case .projectBuilds: return "Reinstall dependencies or rebuild the project to bring these back."
        case .packageCaches: return "Package managers download these again the next time a project needs them."
        case .appCaches: return "Quit the app first. It rebuilds its cache and may be slower the first time it opens."
        case .androidEmulators: return "Each emulator is deleted with its apps and data. Recreate it in Android Studio › Device Manager."
        case .logs: return "Apps start new logs as needed."
        }
    }

    var symbol: String {
        switch kind {
        case .runtimes: return "shippingbox"
        case .simulators: return "iphone"
        case .derivedData: return "hammer"
        case .deviceSupport: return "cable.connector"
        case .xcodeCaches: return "square.stack.3d.up"
        case .projectBuilds: return "folder.badge.gearshape"
        case .packageCaches: return "arrow.down.circle"
        case .appCaches: return "internaldrive"
        case .androidEmulators: return "iphone.gen1"
        case .logs: return "doc.text"
        }
    }
}

/// What the scan measured, in the shape the finder asks about. Built by
/// DiskScanner from its tree for exactly the folders listed in
/// `CleanupFinder.watchedFolders`.
struct MeasuredFolders {
    /// Size by absolute path.
    let sizes: [String: Int64]
    /// Measured direct children (folders, and files of 50 MB or more) by the
    /// parent's absolute path.
    let children: [String: [(url: URL, size: Int64)]]
    /// Folders named like build output or dependencies, anywhere in the scan.
    let projectFolders: [(url: URL, size: Int64)]
}

/// Turns a finished scan into the Safe to Clean groups.
///
/// Only locations whose contents a tool recreates on its own are listed.
/// Everything else — documents, app data, archives with dSYMs — stays in the
/// Largest Items view, where the person decides.
enum CleanupFinder {
    private static let minimumSize: Int64 = 1 << 20
    private static let minimumListedCacheSize: Int64 = 10 << 20

    private static let packageCaches: [(path: String, title: String)] = [
        (".gradle/caches", "Gradle caches"),
        (".gradle/wrapper/dists", "Gradle distributions"),
        (".gradle/daemon", "Gradle daemon logs"),
        (".npm/_cacache", "npm cache"),
        ("Library/Caches/Yarn", "Yarn cache"),
        ("Library/pnpm/store", "pnpm store"),
        ("Library/Caches/Homebrew", "Homebrew downloads"),
        ("Library/Caches/CocoaPods", "CocoaPods cache"),
        (".cocoapods/repos", "CocoaPods spec repos"),
        ("Library/Caches/pip", "pip cache"),
        (".cargo/registry", "Cargo registry"),
        (".bun/install/cache", "Bun cache"),
        ("Library/Caches/ms-playwright", "Playwright browsers"),
        (".android/cache", "Android SDK cache"),
    ]

    private static let xcodeCaches: [(path: String, title: String)] = [
        ("Library/Developer/Xcode/UserData/Previews", "SwiftUI preview simulators"),
        ("Library/Developer/CoreSimulator/Caches", "Simulator caches"),
        ("Library/Caches/com.apple.dt.Xcode", "Xcode cache"),
        ("Library/Developer/Xcode/DocumentationCache", "Documentation cache"),
    ]

    private static let derivedData = "Library/Developer/Xcode/DerivedData"
    private static let simulatorDevices = "Library/Developer/CoreSimulator/Devices"
    private static let deviceSupport = ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport",
                                        "visionOS DeviceSupport"].map { "Library/Developer/Xcode/" + $0 }
    private static let caches = "Library/Caches"
    private static let logs = "Library/Logs"
    private static let androidAVDs = ".android/avd"

    /// Folders (relative to home) whose size or children the scan must report.
    static let watchedFolders: [String] = [derivedData, simulatorDevices, caches, logs, androidAVDs]
        + deviceSupport + packageCaches.map(\.path) + xcodeCaches.map(\.path)

    /// A folder with this name counts as removable project output only when
    /// one of the marker files sits next to it — proof it belongs to a project.
    static let projectFolderMarkers: [String: [String]] = [
        "node_modules": ["package.json"],
        "Pods": ["Podfile"],
        ".build": ["Package.swift"],
        "build": ["build.gradle", "build.gradle.kts", "pubspec.yaml"],
        ".next": ["package.json"],
        "target": ["Cargo.toml"],
        ".dart_tool": ["pubspec.yaml"],
        ".gradle": ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"],
    ]

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    static func groups(from measured: MeasuredFolders, simulators: SimulatorInventory?) -> [CleanupGroup] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func url(_ relative: String) -> URL { home.appendingPathComponent(relative) }
        func children(_ relative: String) -> [(url: URL, size: Int64)] {
            (measured.children[url(relative).path] ?? []).filter { $0.size >= minimumSize }
        }

        var groups: [CleanupGroup] = []
        func add(_ kind: CleanupGroup.Kind, _ items: [CleanupItem]) {
            guard !items.isEmpty else { return }
            groups.append(CleanupGroup(kind: kind, items: items.sorted { $0.size > $1.size }))
        }

        if let simulators {
            add(.runtimes, runtimeItems(simulators))
            add(.simulators, simulatorItems(children(simulatorDevices), simulators))
        }
        add(.derivedData, children(derivedData).map(derivedDataItem))
        add(.deviceSupport, deviceSupport.flatMap { folder in
            children(folder).map { child in
                let platform = folder.components(separatedBy: "/").last?.replacingOccurrences(of: " DeviceSupport", with: "") ?? ""
                let age = modificationAge(of: child.url)
                return trashItem(child, title: child.url.lastPathComponent,
                                 detail: [platform, age.map { "added \($0.text)" }].compactMap { $0 }.joined(separator: " · "),
                                 recommendation: age.flatMap { $0.days >= 90 ? "Not used in \($0.days) days" : nil },
                                 symbol: "cable.connector")
            }
        })
        add(.xcodeCaches, xcodeCaches.compactMap { entry in
            measured.sizes[url(entry.path).path].flatMap { size in
                size >= minimumListedCacheSize
                    ? trashItem((url(entry.path), size), title: entry.title,
                                detail: (url(entry.path).path as NSString).abbreviatingWithTildeInPath,
                                recommendation: nil, symbol: "square.stack.3d.up")
                    : nil
            }
        })
        add(.projectBuilds, projectItems(measured.projectFolders, home: home))
        add(.packageCaches, packageCaches.compactMap { entry in
            measured.sizes[url(entry.path).path].flatMap { size in
                size >= minimumSize
                    ? trashItem((url(entry.path), size), title: entry.title,
                                detail: (url(entry.path).path as NSString).abbreviatingWithTildeInPath,
                                recommendation: nil, symbol: "arrow.down.circle")
                    : nil
            }
        })
        let claimedCaches = Set((packageCaches + xcodeCaches).map { url($0.path).path })
        add(.appCaches, children(caches)
            .filter { $0.size >= minimumListedCacheSize && !claimedCaches.contains($0.url.path) && !isSystemCache($0.url) }
            .map(appCacheItem))
        add(.androidEmulators, children(androidAVDs).filter { $0.url.pathExtension == "avd" }.map { avd in
            let name = avd.url.deletingPathExtension().lastPathComponent
            let ini = avd.url.deletingPathExtension().appendingPathExtension("ini")
            let age = modificationAge(of: avd.url)
            return CleanupItem(
                id: avd.url.path, title: name.replacingOccurrences(of: "_", with: " "),
                detail: age.map { "Last changed \($0.text)" } ?? "Android Virtual Device",
                size: avd.size,
                action: .trash(FileManager.default.fileExists(atPath: ini.path) ? [avd.url, ini] : [avd.url]),
                recommendation: age.flatMap { $0.days >= 60 ? "Not used in \($0.days) days" : nil },
                blockedReason: nil, iconPath: nil, symbol: "iphone.gen1")
        })
        add(.logs, children(logs)
            .filter { $0.size >= minimumListedCacheSize && $0.url.lastPathComponent != "DiagnosticReports" }
            .map { trashItem($0, title: $0.url.lastPathComponent,
                             detail: ($0.url.path as NSString).abbreviatingWithTildeInPath,
                             recommendation: nil, symbol: "doc.text") })

        return groups.sorted { $0.size > $1.size }
    }

    // MARK: - Simulators

    private static func runtimeItems(_ inventory: SimulatorInventory) -> [CleanupItem] {
        let inUse = Set(inventory.devices.values.map(\.runtimeIdentifier))
        let newestPerPlatform = Dictionary(grouping: inventory.runtimes, by: \.platform)
            .compactMapValues { $0.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }?.identifier }
        return inventory.runtimes.filter(\.deletable).map { runtime in
            let used = runtime.lastUsedAt.map { "last used \(relativeFormatter.localizedString(for: $0, relativeTo: Date()))" }
                ?? "never used"
            let isNewest = newestPerPlatform[runtime.platform] == runtime.identifier
            let recommendation = !inUse.contains(runtime.runtimeIdentifier) && !isNewest
                ? "No simulator uses it" : nil
            return CleanupItem(id: runtime.identifier, title: runtime.name,
                               detail: "Build \(runtime.build) · \(used)", size: runtime.size,
                               action: .deleteRuntime(identifier: runtime.identifier),
                               recommendation: recommendation, blockedReason: nil, iconPath: nil,
                               symbol: "shippingbox")
        }
    }

    private static func simulatorItems(_ folders: [(url: URL, size: Int64)],
                                       _ inventory: SimulatorInventory) -> [CleanupItem] {
        // An empty device list more likely means simctl answered badly (say,
        // right after an Xcode update) than that every simulator is orphaned.
        guard !inventory.devices.isEmpty else { return [] }
        return folders.compactMap { folder -> CleanupItem? in
            let udid = folder.url.lastPathComponent
            guard UUID(uuidString: udid) != nil else { return nil }
            guard let device = inventory.devices[udid] else {
                // Offered, never recommended: "unknown" can be a simctl hiccup.
                return CleanupItem(id: folder.url.path, title: "Unknown simulator", detail: "\(udid) · not listed by Xcode",
                                   size: folder.size, action: .trash([folder.url]),
                                   recommendation: nil, blockedReason: nil, iconPath: nil, symbol: "iphone")
            }
            var recommendation: String?
            let opened: String
            if let booted = device.lastBootedAt {
                let days = Int(Date().timeIntervalSince(booted) / 86_400)
                opened = "opened \(relativeFormatter.localizedString(for: booted, relativeTo: Date()))"
                if days >= 30 { recommendation = "Not opened in \(days) days" }
            } else {
                opened = "never opened"
                recommendation = "Never opened"
            }
            if !device.isAvailable {
                recommendation = "Its runtime is no longer installed"
            }
            return CleanupItem(id: udid, title: device.name, detail: "\(device.runtimeName) · \(opened)",
                               size: folder.size, action: .deleteSimulator(udid: udid),
                               recommendation: device.isBooted ? nil : recommendation,
                               blockedReason: device.isBooted ? "Running — shut it down in Simulator first" : nil,
                               iconPath: nil, symbol: "iphone")
        }
    }

    // MARK: - Folders

    private static func derivedDataItem(_ folder: (url: URL, size: Int64)) -> CleanupItem {
        let name = folder.url.lastPathComponent
        let special = ["ModuleCache.noindex": "Module cache", "SymbolCache.noindex": "Symbol cache",
                       "CompilationCache.noindex": "Compilation cache"]
        if let title = special[name] {
            return trashItem(folder, title: title, detail: "Shared by every project", recommendation: nil, symbol: "hammer")
        }
        // "MyApp-bxjqhmdkcdfpzagxwcxlqqxlnnmk": Xcode appends a 28-letter hash.
        var title = name
        if let dash = name.lastIndex(of: "-"), name.distance(from: dash, to: name.endIndex) == 29 {
            title = String(name[..<dash])
        }
        let info = NSDictionary(contentsOf: folder.url.appendingPathComponent("info.plist"))
        let workspace = (info?["WorkspacePath"] as? String).map { ($0 as NSString).abbreviatingWithTildeInPath }
        let lastAccess = info?["LastAccessedDate"] as? Date
        var detail = [workspace]
        var recommendation: String?
        if let lastAccess {
            let days = Int(Date().timeIntervalSince(lastAccess) / 86_400)
            detail.append("opened \(relativeFormatter.localizedString(for: lastAccess, relativeTo: Date()))")
            if days >= 30 { recommendation = "Not opened in Xcode for \(days) days" }
        }
        if let workspace = info?["WorkspacePath"] as? String, !FileManager.default.fileExists(atPath: workspace) {
            recommendation = "The project no longer exists"
        }
        return trashItem(folder, title: title, detail: detail.compactMap { $0 }.joined(separator: " · "),
                         recommendation: recommendation, symbol: "hammer")
    }

    private static func projectItems(_ folders: [(url: URL, size: Int64)], home: URL) -> [CleanupItem] {
        let homePath = home.path + "/"
        var accepted: [(url: URL, size: Int64)] = []
        for folder in folders.sorted(by: { $0.url.path < $1.url.path }) {
            let path = folder.url.path
            guard path.hasPrefix(homePath), folder.size >= minimumListedCacheSize else { continue }
            // Project folders live in plain, visible places: never under
            // ~/Library or a dot-folder like ~/.vscode, where a node_modules is
            // part of an installed tool rather than a checkout.
            let components = path.dropFirst(homePath.count).split(separator: "/").dropLast()
            // A marker folder straight in the home folder (~/.gradle, ~/build)
            // belongs to the account, not to a checkout.
            guard !components.isEmpty, components.first != "Library",
                  !components.contains(where: { $0.hasPrefix(".") }) else { continue }
            let parent = folder.url.deletingLastPathComponent()
            let markers = projectFolderMarkers[folder.url.lastPathComponent] ?? []
            guard markers.contains(where: { FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path) }) else {
                continue
            }
            // Sorted by path, so an enclosing folder is always seen first.
            if let last = accepted.last, path.hasPrefix(last.url.path + "/") { continue }
            accepted.append(folder)
        }
        return accepted.sorted { $0.size > $1.size }.prefix(100).map { folder in
            let parent = folder.url.deletingLastPathComponent()
            let marker = (projectFolderMarkers[folder.url.lastPathComponent] ?? [])
                .map { parent.appendingPathComponent($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            let age = marker.flatMap(modificationAge)
            return trashItem(folder, title: "\(parent.lastPathComponent) › \(folder.url.lastPathComponent)",
                             detail: (parent.path as NSString).abbreviatingWithTildeInPath,
                             recommendation: age.flatMap { $0.days >= 90 ? "Project untouched for \($0.days) days" : nil },
                             symbol: "folder.badge.gearshape")
        }
    }

    private static func appCacheItem(_ folder: (url: URL, size: Int64)) -> CleanupItem {
        let name = folder.url.lastPathComponent
        var title = name
        var iconPath: String?
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            title = FileManager.default.displayName(atPath: app.path)
            iconPath = app.path
        }
        return CleanupItem(id: folder.url.path, title: title,
                           detail: (folder.url.path as NSString).abbreviatingWithTildeInPath,
                           size: folder.size, action: .trash([folder.url]), recommendation: nil,
                           blockedReason: nil, iconPath: iconPath, symbol: "internaldrive")
    }

    /// Caches macOS itself manages (iCloud, Siri, Maps, …) and background
    /// agents' queues. Clearing them buys little and can make those services
    /// re-sync or lose pending work.
    private static func isSystemCache(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let systemNames: Set<String> = ["CloudKit", "GeoServices", "FamilyCircle", "PassKit", "SiriTTS", "GameKit",
                                        "Animoji", "EnergyKit", "TemporaryItems", "AMSDataMigratorTool"]
        if name.hasPrefix("com.apple.") || systemNames.contains(name) { return true }
        // Daemons and agents name their caches after themselves: familycircled,
        // icloudmailagent, askpermissiond.
        let isDaemonName = name.range(of: "^[a-z0-9]+(d|agent)$", options: .regularExpression) != nil
        return isDaemonName || name.lowercased().contains("crashreporter")
    }

    private static func trashItem(_ folder: (url: URL, size: Int64), title: String, detail: String,
                                  recommendation: String?, symbol: String) -> CleanupItem {
        CleanupItem(id: folder.url.path, title: title, detail: detail, size: folder.size,
                    action: .trash([folder.url]), recommendation: recommendation, blockedReason: nil,
                    iconPath: nil, symbol: symbol)
    }

    private static func modificationAge(of url: URL) -> (days: Int, text: String)? {
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return nil
        }
        return (Int(Date().timeIntervalSince(date) / 86_400),
                relativeFormatter.localizedString(for: date, relativeTo: Date()))
    }
}

/// Simulators and runtimes as CoreSimulator reports them.
struct SimulatorInventory {
    struct Device {
        let name: String
        let runtimeIdentifier: String
        let runtimeName: String
        let isBooted: Bool
        let isAvailable: Bool
        let lastBootedAt: Date?
    }

    struct Runtime {
        let identifier: String
        let runtimeIdentifier: String
        let platform: String
        let version: String
        let build: String
        let size: Int64
        let lastUsedAt: Date?
        let deletable: Bool

        var name: String { "\(platform) \(version)" }
    }

    let devices: [String: Device]
    let runtimes: [Runtime]

    /// Nil when the Simulator has never been used here — running `xcrun`
    /// without developer tools would pop the "install tools" dialog.
    static func load() -> SimulatorInventory? {
        let simulatorFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator")
        guard FileManager.default.fileExists(atPath: simulatorFolder.path),
              let deviceJSON = try? runSimctl(["list", "devices", "-j"]).get(),
              let devicesByRuntime = (try? JSONSerialization.jsonObject(with: deviceJSON) as? [String: Any])?["devices"]
                as? [String: [[String: Any]]] else {
            return nil
        }
        let dates = ISO8601DateFormatter()

        var devices: [String: Device] = [:]
        for (runtime, entries) in devicesByRuntime {
            for entry in entries {
                guard let udid = entry["udid"] as? String else { continue }
                devices[udid] = Device(name: entry["name"] as? String ?? udid,
                                       runtimeIdentifier: runtime,
                                       runtimeName: displayName(ofRuntime: runtime),
                                       isBooted: entry["state"] as? String == "Booted",
                                       isAvailable: entry["isAvailable"] as? Bool ?? true,
                                       lastBootedAt: (entry["lastBootedAt"] as? String).flatMap(dates.date(from:)))
            }
        }

        var runtimes: [Runtime] = []
        if let runtimeJSON = try? runSimctl(["runtime", "list", "-j"]).get(),
           let entries = try? JSONSerialization.jsonObject(with: runtimeJSON) as? [String: [String: Any]] {
            for (identifier, entry) in entries {
                let runtimeIdentifier = entry["runtimeIdentifier"] as? String ?? ""
                runtimes.append(Runtime(
                    identifier: identifier,
                    runtimeIdentifier: runtimeIdentifier,
                    platform: platformName(entry["platformIdentifier"] as? String ?? ""),
                    version: entry["version"] as? String ?? "?",
                    build: entry["build"] as? String ?? "?",
                    size: (entry["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                    lastUsedAt: (entry["lastUsedAt"] as? String).flatMap(dates.date(from:)),
                    deletable: entry["deletable"] as? Bool ?? false
                ))
            }
        }
        return SimulatorInventory(devices: devices, runtimes: runtimes)
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → "iOS 26.5"
    private static func displayName(ofRuntime identifier: String) -> String {
        guard let tail = identifier.components(separatedBy: "SimRuntime.").last else { return identifier }
        let parts = tail.split(separator: "-")
        guard let platform = parts.first else { return tail }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }

    private static func platformName(_ identifier: String) -> String {
        switch identifier {
        case "com.apple.platform.iphonesimulator": return "iOS"
        case "com.apple.platform.watchsimulator": return "watchOS"
        case "com.apple.platform.appletvsimulator": return "tvOS"
        case "com.apple.platform.xrsimulator": return "visionOS"
        default: return identifier.components(separatedBy: ".").last ?? identifier
        }
    }

    /// Runs `xcrun simctl …` synchronously and returns stdout, or stderr as the
    /// error. Call off the main thread — runtime deletion can take a while.
    static func runSimctl(_ arguments: [String]) -> Result<Data, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failure(error)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            os_log("simctl %{public}@ failed: %{public}@", log: log, type: .error,
                   arguments.joined(separator: " "), message ?? "")
            let description = message.flatMap { $0.isEmpty ? nil : $0 }
                ?? "simctl exited with status \(process.terminationStatus)."
            return .failure(CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: description]))
        }
        return .success(data)
    }
}
