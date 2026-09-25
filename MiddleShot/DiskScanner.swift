import Cocoa
import os
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "dashboard")

/// Where a disk scan starts.
enum DiskScanScope: String, CaseIterable {
    case home
    case entireDisk

    var title: String {
        switch self {
        case .home: return "Home Folder"
        case .entireDisk: return "Entire Disk"
        }
    }

    var rootURL: URL {
        switch self {
        case .home: return FileManager.default.homeDirectoryForCurrentUser
        case .entireDisk: return URL(fileURLWithPath: "/")
        }
    }
}

/// Places a scan leaves out unless asked. Neither is something to clean up
/// from here: a photo library is managed by Photos, iCloud Drive by Finder's
/// Remove Download. Photos alone can be hundreds of thousands of files.
struct DiskScanInclusions: OptionSet {
    let rawValue: Int
    static let photosLibrary = DiskScanInclusions(rawValue: 1 << 0)
    static let iCloudDrive = DiskScanInclusions(rawValue: 1 << 1)

    /// Whether `url` belongs to a place this set leaves out, and which one.
    func excluded(_ url: URL) -> DiskScanInclusions? {
        if !contains(.photosLibrary), url.pathExtension == "photoslibrary" { return .photosLibrary }
        if !contains(.iCloudDrive) {
            let components = url.pathComponents.suffix(2)
            if components.first == "Library", ["Mobile Documents", "CloudStorage"].contains(components.last) {
                return .iCloudDrive
            }
        }
        return nil
    }

    var names: [String] {
        [(DiskScanInclusions.photosLibrary, "Photos Library"), (.iCloudDrive, "iCloud Drive")]
            .filter { contains($0.0) }.map(\.1)
    }
}

/// How safe an item is to move to the Trash. Decided from well-known paths,
/// not from the contents — it is a hint for the person reading the list, and
/// the confirmation note spells out what removing it actually costs.
enum DiskItemCategory: Equatable {
    case rebuildable
    case reviewFirst
    case appData
    case application
    /// Not offered for removal. The string says why, in the user's terms.
    case protected(String)
}

struct DiskItem {
    let url: URL
    /// Bytes actually allocated on disk, which is what emptying the Trash frees.
    let size: Int64
    let category: DiskItemCategory
    /// Shown in the confirmation sheet: what happens once this is gone.
    let note: String
    let displayName: String

    var displayPath: String { (url.path as NSString).abbreviatingWithTildeInPath }
}

struct DiskScanResult {
    let scope: DiskScanScope
    var items: [DiskItem]
    let itemCount: Int
    /// Folders the enumerator could not read — almost always privacy-protected
    /// locations that need Full Disk Access.
    let skippedCount: Int
    /// Places left out because they weren't included — only ones actually met.
    let leftOut: DiskScanInclusions
    let duration: TimeInterval
    let finishedAt: Date
    /// The same scan seen as Safe to Clean groups.
    var cleanup: [CleanupGroup]
}

/// Walks a folder tree once and picks the largest items worth acting on.
///
/// "Largest" needs a rule, because every folder is smaller than its parent: a
/// naive top-10 is just the chain `~ › Library › Developer › …`. The rule used
/// here: for a size threshold S, an item qualifies when it is at least S and
/// none of its children is — the deepest folders that are still big. Such items
/// can never contain each other, so their sizes never double count. S is then
/// lowered until ten items qualify.
///
/// Some folders are only meaningful as a whole (DerivedData, node_modules,
/// app bundles, caches). Those are *atomic*: they qualify on their own size and
/// nothing inside them is ever listed separately.
///
/// The walk itself is I/O bound — `du -sk ~` takes as long as a single-threaded
/// FileManager enumeration — so the top two levels are listed up front and every
/// folder below them is walked concurrently, then stitched back into one tree.
final class DiskScanner {
    struct Progress {
        let itemCount: Int
        let currentFolder: String
    }

    static let resultLimit = 10

    /// Files smaller than this are folded into their folder's size instead of
    /// getting a tree node — keeps an entire-disk scan's memory in check.
    private static let fileNodeMinimum: Int64 = 50 << 20
    private static let candidateMinimum: Int64 = 1 << 20
    private static let progressInterval: UInt64 = 100_000_000
    /// Folders at this depth (and atomic ones above it) are walked in parallel.
    private static let splitDepth = 2

    /// The Data volume is reachable twice from `/` (once through the firmlinks
    /// like /Users, once as /System/Volumes/Data), `/.nofollow` and `/.resolve`
    /// mirror the whole root again, and /Volumes holds other disks entirely.
    private static let excludedPaths: Set<String> = [
        "/System/Volumes", "/Volumes", "/.nofollow", "/.resolve", "/.vol",
        "/dev", "/net", "/home", "/Network",
    ]

    private static let atomicFolderNames: Set<String> = [
        "DerivedData", "node_modules", "Caches", ".Trash", "Pods", ".build",
        ".gradle", ".npm", ".cocoapods",
        "iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport",
        "visionOS DeviceSupport",
    ]

    /// Folders that only hold unrelated things side by side. Listing one of
    /// them ("Application Support, 43 GB") says nothing actionable, so they
    /// never qualify themselves — only what is inside them does.
    private static func isContainer(name: String, parentName: String) -> Bool {
        switch name {
        case "Library", "Applications", "Users", "Application Support", "Containers", "Group Containers":
            return true
        case "Developer": return parentName == "Library"
        case "var": return parentName == "private"
        case "private": return parentName.isEmpty  // /private, in an entire-disk scan
        case "Xcode", "CoreSimulator": return parentName == "Developer"
        default: return parentName == "Users"  // a home folder, in an entire-disk scan
        }
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey, .volumeIdentifierKey, .linkCountKey,
    ]

    private struct Node {
        let name: String
        var parent: Int32
        var size: Int64
        var largestChild: Int64 = 0
        let isAtomic: Bool
        let isInsideAtomic: Bool
        var isContainer = false
    }

    /// Counters shared by the concurrent walkers.
    private struct Tally {
        var items = 0
        var skipped = 0
        var leftOut: DiskScanInclusions = []
        var lastReport: UInt64 = 0
    }

    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private let tally = OSAllocatedUnfairLock(initialState: Tally())
    /// Inodes of hard-linked files already counted. pnpm hard-links one copy
    /// of each package file into every place that uses it; counting every path
    /// read a 11 GB node_modules as 23 GB (2026-09-25). Like `du`, a file with
    /// several links is counted once — at whichever path the walk meets first.
    private let countedLinks = OSAllocatedUnfairLock(initialState: Set<HardLink>())

    private struct HardLink: Hashable {
        let device: Int32
        let inode: UInt64
    }

    private var isCancelled: Bool { cancelled.withLock { $0 } }

    /// Stops the walk at its next checkpoint. `completion` then receives nil.
    func cancel() {
        cancelled.withLock { $0 = true }
    }

    /// Runs `body` with iCloud's dataless items left alone on this thread.
    ///
    /// Listing a folder iCloud has evicted (an `.epub` in Books, a package in
    /// iCloud Drive) makes the kernel wait while the whole thing downloads —
    /// the scan sat in `getattrlistbulk` indefinitely, and one that did get
    /// through would have filled the disk it was measuring. With this policy
    /// off, those calls fail at once with EDEADLK and the folder counts as
    /// skipped; it takes no local space anyway. Thread scope, restored after,
    /// because GCD hands these threads to other work once we're done.
    private static func withoutMaterializing<T>(_ body: () -> T) -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                       IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previous >= 0 {
                setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
            }
        }
        return body()
    }

    /// Scans on a background queue. Both callbacks arrive on main.
    func scan(_ scope: DiskScanScope, including inclusions: DiskScanInclusions,
              progress: @escaping (Progress) -> Void,
              completion: @escaping (DiskScanResult?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.withoutMaterializing {
                self.run(scope, including: inclusions, progress: progress)
            }
            DispatchQueue.main.async {
                completion(self.isCancelled ? nil : result)
            }
        }
    }

    private func run(_ scope: DiskScanScope, including inclusions: DiskScanInclusions,
                     progress: @escaping (Progress) -> Void) -> DiskScanResult? {
        let started = Date()
        let root = scope.rootURL

        // Firmlinked folders under `/` live on the Data volume, so both volumes
        // are home turf. Anything else mounted inside the tree (simulator
        // runtime images, the VM swap volume) is somebody else's space.
        let allowedVolumes: [NSObject] = [URL(fileURLWithPath: "/"), root,
                                          FileManager.default.homeDirectoryForCurrentUser]
            .compactMap { try? $0.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject }
        func shouldSkip(_ url: URL, _ values: URLResourceValues?) -> Bool {
            if let place = inclusions.excluded(url) {
                tally.withLock { $0.leftOut.formUnion(place) }
                return true
            }
            if scope == .entireDisk {
                // FileManager reports `/.nofollow` as "/.nofollow/", slash and all.
                var path = url.path
                while path.count > 1, path.hasSuffix("/") { path.removeLast() }
                if Self.excludedPaths.contains(path) { return true }
            }
            guard let volume = values?.volumeIdentifier as? NSObject else { return false }
            return !allowedVolumes.contains(where: { $0.isEqual(volume) })
        }

        // Nodes are kept in pre-order — every child at a higher index than its
        // parent — which is what lets the size roll-up below run in one pass.
        var nodes = [Node(name: "", parent: -1, size: 0, isAtomic: false, isInsideAtomic: false)]
        var units: [(url: URL, node: Int32)] = []

        func list(_ folder: URL, node: Int32, depth: Int) {
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: Self.resourceKeys, options: [])
            } catch {
                tally.withLock { $0.skipped += 1 }
                return
            }
            tally.withLock { $0.items += children.count }
            for child in children {
                let values = try? child.resourceValues(forKeys: Set(Self.resourceKeys))
                guard values?.isDirectory == true else {
                    addFile(child, values, parent: node, to: &nodes)
                    continue
                }
                if shouldSkip(child, values) { continue }
                let index = addFolder(child, values, parent: node, to: &nodes)
                if depth + 1 < Self.splitDepth, !nodes[Int(index)].isAtomic {
                    list(child, node: index, depth: depth + 1)
                } else {
                    units.append((child, index))
                }
            }
        }
        list(root, node: 0, depth: 0)

        var subtrees = [[Node]?](repeating: nil, count: units.count)
        let parents = units.map { nodes[Int($0.node)] }
        subtrees.withUnsafeMutableBufferPointer { buffer in
            guard let slots = buffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: units.count) { index in
                slots[index] = Self.withoutMaterializing {
                    walk(units[index].url, as: parents[index],
                         shouldSkip: shouldSkip, progress: progress)
                }
            }
        }
        if isCancelled { return nil }

        for (unit, subtree) in zip(units, subtrees) {
            guard let subtree else { continue }
            nodes[Int(unit.node)].size += subtree[0].size
            let offset = Int32(nodes.count) - 1
            for var node in subtree.dropFirst() {
                node.parent = node.parent == 0 ? unit.node : node.parent + offset
                nodes.append(node)
            }
        }

        for index in stride(from: nodes.count - 1, to: 0, by: -1) {
            let size = nodes[index].size
            let parent = Int(nodes[index].parent)
            nodes[parent].size += size
            nodes[parent].largestChild = max(nodes[parent].largestChild, size)
        }

        let pool = (1..<nodes.count).filter {
            !nodes[$0].isInsideAtomic && nodes[$0].size >= Self.candidateMinimum
        }
        func qualifying(atLeast threshold: Int64) -> [Int] {
            pool.filter {
                !nodes[$0].isContainer
                    && nodes[$0].size >= threshold
                    && (nodes[$0].isAtomic || nodes[$0].largestChild < threshold)
            }
        }
        // The qualifying count grows (almost always) as the threshold drops, so
        // a binary search over the distinct sizes finds the highest threshold
        // that still yields a full list.
        let thresholds = Set(pool.map { nodes[$0].size }).sorted(by: >)
        var chosen = thresholds.last ?? 0
        var low = 0
        var high = thresholds.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if qualifying(atLeast: thresholds[mid]).count >= Self.resultLimit {
                chosen = thresholds[mid]
                high = mid - 1
            } else {
                low = mid + 1
            }
        }

        func url(of index: Int) -> URL {
            var names: [String] = []
            var cursor = index
            while cursor > 0 {
                names.append(nodes[cursor].name)
                cursor = Int(nodes[cursor].parent)
            }
            return names.reversed().reduce(root) { $0.appendingPathComponent($1) }
        }

        let items = qualifying(atLeast: chosen)
            .sorted { nodes[$0].size > nodes[$1].size }
            .prefix(Self.resultLimit)
            .map { index -> DiskItem in
                let itemURL = url(of: index)
                let (category, note) = Self.classify(itemURL)
                return DiskItem(url: itemURL, size: nodes[index].size, category: category,
                                note: note,
                                displayName: FileManager.default.displayName(atPath: itemURL.path))
            }

        let measured = measuredFolders(in: nodes, root: root, url: url(of:))
        let cleanup = CleanupFinder.groups(from: measured, simulators: SimulatorInventory.load())
        if isCancelled { return nil }

        let counts = tally.withLock { $0 }
        let duration = Date().timeIntervalSince(started)
        os_log("Scanned %{public}@: %d items in %d folders walked in parallel, %d skipped, %.1fs",
               log: log, type: .info, root.path, counts.items, units.count, counts.skipped, duration)
        return DiskScanResult(scope: scope, items: items, itemCount: counts.items,
                              skippedCount: counts.skipped, leftOut: counts.leftOut, duration: duration, finishedAt: Date(),
                              cleanup: cleanup)
    }

    /// Pulls out what CleanupFinder needs. Paths are only built along the way
    /// to the watched folders, so this stays cheap on a multi-million-node tree.
    private func measuredFolders(in nodes: [Node], root: URL, url: (Int) -> URL) -> MeasuredFolders {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let targets = Set(CleanupFinder.watchedFolders.map { home.appendingPathComponent($0).path })
        var onTheWay = Set<String>()
        for target in targets {
            var path = target
            while path.count > 1 {
                onTheWay.insert(path)
                path = (path as NSString).deletingLastPathComponent
            }
        }
        func join(_ parent: String, _ name: String) -> String {
            parent == "/" ? "/" + name : parent + "/" + name
        }

        var paths: [Int32: String] = [0: root.path]
        var sizes: [String: Int64] = [:]
        var children: [String: [(url: URL, size: Int64)]] = [:]
        var projectFolders: [(url: URL, size: Int64)] = []
        for index in 1..<max(nodes.count, 1) {
            let node = nodes[index]
            if let parentPath = paths[node.parent] {
                let path = join(parentPath, node.name)
                if targets.contains(parentPath) {
                    children[parentPath, default: []].append((URL(fileURLWithPath: path), node.size))
                }
                if onTheWay.contains(path) {
                    paths[Int32(index)] = path
                    if targets.contains(path) { sizes[path] = node.size }
                }
            }
            if !node.isInsideAtomic, node.size >= 10 << 20, CleanupFinder.projectFolderMarkers[node.name] != nil {
                projectFolders.append((url(index), node.size))
            }
        }
        return MeasuredFolders(sizes: sizes, children: children, projectFolders: projectFolders)
    }

    /// Walks one folder's subtree. Index 0 of the result stands for `folder`
    /// itself (its size is the files directly inside it); every other node's
    /// parent index is local to this array until `run` stitches it in.
    private func walk(_ folder: URL, as node: Node,
                      shouldSkip: (URL, URLResourceValues?) -> Bool,
                      progress: @escaping (Progress) -> Void) -> [Node]? {
        var nodes = [Node(name: node.name, parent: -1, size: 0,
                          isAtomic: node.isAtomic, isInsideAtomic: node.isInsideAtomic)]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Self.resourceKeys,
            options: [],
            errorHandler: { [tally] _, _ in
                tally.withLock { $0.skipped += 1 }
                return true
            }
        ) else { return nodes }

        let keys = Set(Self.resourceKeys)
        var ancestors: [Int32] = [0]
        var pending = 0

        for case let url as URL in enumerator {
            pending += 1
            if pending == 1024 {
                if isCancelled { return nil }
                report(pending, folder: url.deletingLastPathComponent(), progress: progress)
                pending = 0
            }

            let level = enumerator.level
            if ancestors.count > level {
                ancestors.removeLast(ancestors.count - level)
            }
            guard let parent = ancestors.last else { continue }
            let values = try? url.resourceValues(forKeys: keys)

            if values?.isDirectory == true {
                if shouldSkip(url, values) {
                    enumerator.skipDescendants()
                    continue
                }
                ancestors.append(addFolder(url, values, parent: parent, to: &nodes))
            } else {
                addFile(url, values, parent: parent, to: &nodes)
            }
        }
        let remaining = pending
        tally.withLock { $0.items += remaining }
        return nodes
    }

    private func report(_ count: Int, folder: URL, progress: @escaping (Progress) -> Void) {
        let now = DispatchTime.now().uptimeNanoseconds
        let snapshot: Int? = tally.withLock { tally in
            tally.items += count
            guard now - tally.lastReport > Self.progressInterval else { return nil }
            tally.lastReport = now
            return tally.items
        }
        guard let items = snapshot else { return }
        let update = Progress(itemCount: items,
                              currentFolder: (folder.path as NSString).abbreviatingWithTildeInPath)
        DispatchQueue.main.async { progress(update) }
    }

    private func addFolder(_ url: URL, _ values: URLResourceValues?, parent: Int32,
                           to nodes: inout [Node]) -> Int32 {
        let parentNode = nodes[Int(parent)]
        let name = url.lastPathComponent
        let atomic = values?.isPackage == true
            || Self.atomicFolderNames.contains(name)
            || (name == "Devices" && parentNode.name == "CoreSimulator")
        nodes.append(Node(name: name, parent: parent, size: 0, isAtomic: atomic,
                          isInsideAtomic: parentNode.isAtomic || parentNode.isInsideAtomic,
                          isContainer: !atomic && Self.isContainer(name: name, parentName: parentNode.name)))
        return Int32(nodes.count - 1)
    }

    /// True the first time any path to this file is seen during the scan.
    private func isFirstLink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return true }
        let link = HardLink(device: info.st_dev, inode: info.st_ino)
        return countedLinks.withLock { $0.insert(link).inserted }
    }

    private func addFile(_ url: URL, _ values: URLResourceValues?, parent: Int32,
                         to nodes: inout [Node]) {
        let size = Int64(values?.totalFileAllocatedSize ?? 0)
        if let links = values?.linkCount, links > 1, !isFirstLink(url) { return }
        guard size >= Self.fileNodeMinimum else {
            nodes[Int(parent)].size += size
            return
        }
        let parentNode = nodes[Int(parent)]
        nodes.append(Node(name: url.lastPathComponent, parent: parent, size: size, isAtomic: true,
                          isInsideAtomic: parentNode.isAtomic || parentNode.isInsideAtomic))
    }

    // MARK: - Classification

    private static let rebuildNotes: [String: String] = [
        "DerivedData": "Xcode rebuilds this folder the next time you build a project.",
        "node_modules": "Run your package manager's install to bring it back.",
        "Caches": "Apps rebuild their caches. Some may be slower the first time they launch.",
        "iOS DeviceSupport": "Xcode downloads these symbols again the next time you connect a device.",
        "watchOS DeviceSupport": "Xcode downloads these symbols again the next time you connect a device.",
        "tvOS DeviceSupport": "Xcode downloads these symbols again the next time you connect a device.",
        "visionOS DeviceSupport": "Xcode downloads these symbols again the next time you connect a device.",
        ".build": "Swift Package Manager rebuilds this folder on the next build.",
        "Pods": "Run pod install to bring it back.",
        ".npm": "npm downloads packages again when it needs them.",
        ".cocoapods": "CocoaPods downloads its specs again when it needs them.",
    ]

    /// Folders a name alone can't vouch for: they're only rebuildable when the
    /// project file that recreates them sits alongside.
    private static let projectMarkers: [String: [String]] = [
        "node_modules": ["package.json"], "Pods": ["Podfile"], ".build": ["Package.swift"],
    ]

    /// Decides how an item is labelled — and whether it may be removed at all.
    /// Rules run from "never" to "safe": protection first, then data an app or a
    /// tool depends on, and only then the rebuildable caches.
    static func classify(_ url: URL) -> (DiskItemCategory, String) {
        let fileManager = FileManager.default
        let path = url.path
        let home = fileManager.homeDirectoryForCurrentUser.path
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        func isInside(_ folder: String) -> Bool {
            path == folder || path.hasPrefix(folder + "/")
        }

        // Never offered.
        if name == ".Trash" {
            return (.protected("Already in the Trash — empty the Trash in Finder to free this space"), "")
        }
        let standardHomeFolders = ["Desktop", "Documents", "Downloads", "Library", "Movies",
                                   "Music", "Pictures", "Public", "Applications"]
        if path == home || standardHomeFolders.contains(where: { path == home + "/" + $0 }) {
            return (.protected("macOS needs this folder — open it in Finder and clear what's inside"), "")
        }
        if ["/System", "/usr", "/bin", "/sbin", "/private", "/Library/Apple", "/cores"].contains(where: isInside),
           !isInside("/usr/local") {
            return (.protected("Part of macOS"), "")
        }
        if ["/opt/homebrew", "/usr/local"].contains(where: isInside) {
            return (.protected("Managed by Homebrew — use brew uninstall or brew cleanup instead"), "")
        }
        if isInside(Bundle.main.bundleURL.path) {
            return (.protected("This is MiddleShot"), "")
        }
        if name == "Devices", parent.lastPathComponent == "CoreSimulator" {
            return (.protected("Delete simulators one by one in Safe to Clean — they have to go through Xcode's simulator service"), "")
        }
        let syncedRoots = ["Dropbox", "Library/CloudStorage", "Library/Mobile Documents"].map { home + "/" + $0 }
        if syncedRoots.contains(where: { path == $0 || parent.path == $0 }) {
            return (.protected("A synced folder — removing it here removes it on your other devices too; open it in Finder instead"), "")
        }
        if !fileManager.isDeletableFile(atPath: path) {
            return (.protected("Your account doesn't have permission to remove it"), "")
        }

        // Something an app or a tool depends on.
        if url.pathExtension == "app" {
            return (.application, "Moving an app to the Trash uninstalls it. Its settings in ~/Library stay behind.")
        }
        if ["photoslibrary", "photolibrary", "musiclibrary", "tvlibrary"].contains(url.pathExtension) {
            return (.appData, "This is a media library. Anything not synced to iCloud is gone once you empty the Trash.")
        }
        if name == "Docker.raw" {
            return (.appData, "All Docker images, containers and volumes live in this file. Quit Docker Desktop first.")
        }
        let appDataFolders = ["Library/Application Support", "Library/Containers",
                              "Library/Group Containers", "Library/Mail", "Library/Messages", ".docker"]
        if appDataFolders.contains(where: { isInside(home + "/" + $0) }) {
            return (.appData, "An app keeps its data here. Quit that app first — it may lose settings or content.")
        }
        if syncedRoots.contains(where: isInside) {
            return (.reviewFirst, "This folder syncs — removing it here removes it on your other devices too.")
        }
        if path.contains("/lib/node_modules") {
            return (.reviewFirst, "Globally installed command-line tools (npm itself among them) live here.")
        }
        if path == home + "/.gradle" {
            return (.reviewFirst, "Gradle's home folder: downloaded JDKs and your Gradle settings live here, not just caches.")
        }
        if name == "Archives", parent.lastPathComponent == "Xcode" {
            return (.reviewFirst, "Archives hold the dSYMs for builds you shipped — keep any you may need to read crash reports.")
        }

        // Rebuildable: a tool recreates it on its own.
        if let markers = projectMarkers[name] {
            let hasMarker = markers.contains { fileManager.fileExists(atPath: parent.appendingPathComponent($0).path) }
            return hasMarker
                ? (.rebuildable, rebuildNotes[name] ?? "")
                : (.reviewFirst, "Check what's inside before removing it.")
        }
        if let note = rebuildNotes[name] {
            return (.rebuildable, note)
        }
        if isInside(home + "/Library/Caches") {
            return (.rebuildable, rebuildNotes["Caches"] ?? "")
        }
        return (.reviewFirst, "Check what's inside before removing it.")
    }

    /// Re-checks a path at the moment it is about to go to the Trash, because a
    /// scan can be minutes or hours old. Returns why it must not be moved, or
    /// nil when it is still what the scan listed and still allowed.
    static func refusalReason(forTrashing url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
            return "It's no longer there."
        }
        if values.isSymbolicLink == true {
            return "It has been replaced by a link since the scan."
        }
        // A folder on the way could have become a link, redirecting the move.
        if url.resolvingSymlinksInPath().path != url.standardizedFileURL.path {
            return "A folder on its path is now a link somewhere else."
        }
        if case .protected(let reason) = classify(url).0 {
            return reason
        }
        if url.pathExtension == "app",
           NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }) {
            return "It's running — quit it first."
        }
        return nil
    }

    // MARK: - Trash

    /// Moves `url` to the Trash and returns where it landed, which is what
    /// `restore(_:to:)` needs to undo it.
    static func moveToTrash(_ url: URL) throws -> URL {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        guard let location = trashed as URL? else {
            preconditionFailure("trashItem succeeded without reporting a location")
        }
        return location
    }

    static func restore(_ trashed: URL, to original: URL) throws {
        try FileManager.default.moveItem(at: trashed, to: original)
    }
}
