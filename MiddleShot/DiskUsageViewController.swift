import Cocoa
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "dashboard")

/// Disk tab: the startup volume's capacity, then one scan seen two ways —
/// **Largest Items** (the ten biggest things, each with Move to Trash) and
/// **Safe to Clean** (caches, simulators, build output and the like, grouped
/// and expandable).
///
/// Results are kept per scope for as long as the app runs, so switching between
/// Home Folder and Entire Disk shows each one's last scan instead of rescanning.
final class DiskUsageViewController: NSViewController, DashboardPanel, NSTableViewDataSource, NSTableViewDelegate {
    var onStateChange: (() -> Void)?
    let neverUpdatedText = "Not scanned yet"
    var lastUpdated: Date? { results[scope]?.finishedAt }
    var isWorking: Bool { scanner != nil }

    private typealias TrashEntry = (name: String, urls: [URL], size: Int64)

    private var scope = Settings.diskScanScope
    private var showsCleanup = Settings.diskShowsCleanup
    private var results: [DiskScanScope: DiskScanResult] = [:]
    private var scanner: DiskScanner?
    /// Bumped whenever `results` changes for a reason other than Undo, so an
    /// Undo can tell whether its snapshot is still the latest state.
    private var resultsVersion = 0
    /// Cleanup items whose `simctl` deletion is still running.
    private var pendingIDs: Set<String> = []

    private let volumeNameLabel = DashboardStyle.label("", weight: .semibold)
    private let volumeUsageLabel = DashboardStyle.label("", size: 12, color: .secondaryLabelColor)
    private let volumeBar = BarView(thickness: 8)
    private let modeControl = NSSegmentedControl(labels: ["Largest Items", "Safe to Clean"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let scopePopup = NSPopUpButton()
    private let asideLabel = DashboardStyle.label("", size: 11.5, color: .tertiaryLabelColor)
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let cleanupList = CleanupListController()
    private let placeholder = PlaceholderView()
    private let statusLine = StatusLine()
    private let toast = ToastView()

    private var items: [DiskItem] { results[scope]?.items ?? [] }

    // MARK: - Layout

    override func loadView() {
        let root = NSView()

        volumeUsageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let volumeHeader = NSStackView(views: [volumeNameLabel, volumeUsageLabel])
        volumeHeader.spacing = 8
        volumeHeader.alignment = .firstBaseline
        let volumeStack = NSStackView(views: [volumeHeader, volumeBar])
        volumeStack.orientation = .vertical
        volumeStack.alignment = .leading
        volumeStack.spacing = 8
        volumeStack.translatesAutoresizingMaskIntoConstraints = false
        let volumeCard = FillView(color: DashboardStyle.cardColor, cornerRadius: 12)
        volumeCard.addSubview(volumeStack)

        modeControl.controlSize = .small
        modeControl.selectedSegment = showsCleanup ? 1 : 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        scopePopup.addItems(withTitles: DiskScanScope.allCases.map(\.title))
        scopePopup.controlSize = .small
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged)
        let scopeLabel = DashboardStyle.label("Scan", size: 12, color: .secondaryLabelColor)
        let tools = NSStackView(views: [modeControl, scopeLabel, scopePopup, NSView(), asideLabel])
        tools.spacing = 8
        tools.setCustomSpacing(18, after: modeControl)

        configureTable()
        cleanupList.onClean = { [weak self] items, group in self?.confirmClean(items, in: group) }
        cleanupList.onReveal = { [weak self] url in
            guard self?.isWorking == false else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        placeholder.onAction = { [weak self] in self?.startRefresh() }
        placeholder.onStop = { [weak self] in self?.stopRefresh(announce: true) }
        statusLine.onLink = { PermissionHelper.openFullDiskAccessSettings() }

        let lists = [scrollView, cleanupList.scrollView]
        for view in [volumeCard, tools] + lists + [placeholder, statusLine, toast] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        var constraints = [
            volumeCard.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            volumeCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            volumeCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            volumeStack.topAnchor.constraint(equalTo: volumeCard.topAnchor, constant: 12),
            volumeStack.bottomAnchor.constraint(equalTo: volumeCard.bottomAnchor, constant: -12),
            volumeStack.leadingAnchor.constraint(equalTo: volumeCard.leadingAnchor, constant: 14),
            volumeStack.trailingAnchor.constraint(equalTo: volumeCard.trailingAnchor, constant: -14),
            volumeBar.widthAnchor.constraint(equalTo: volumeStack.widthAnchor),

            tools.topAnchor.constraint(equalTo: volumeCard.bottomAnchor, constant: 12),
            tools.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            tools.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            placeholder.topAnchor.constraint(equalTo: scrollView.topAnchor),
            placeholder.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),

            statusLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusLine.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            toast.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: statusLine.topAnchor, constant: -14),
            toast.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -80),
        ]
        for list in lists {
            constraints += [
                list.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 8),
                list.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
                list.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
                list.bottomAnchor.constraint(equalTo: statusLine.topAnchor, constant: -8),
            ]
        }
        NSLayoutConstraint.activate(constraints)

        view = root
        refreshVolume()
        render()
    }

    private func configureTable() {
        let columns: [(id: String, title: String, width: CGFloat, alignment: NSTextAlignment)] = [
            ("name", "Name", 320, .left),
            ("bar", "", 130, .left),
            ("size", "Size", 80, .right),
            ("actions", "", 160, .right),
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.headerCell.alignment = spec.alignment
            if spec.id != "name" {
                column.minWidth = spec.width
                column.maxWidth = spec.width
            } else {
                column.minWidth = 200
            }
            tableView.addTableColumn(column)
        }
        tableView.style = .inset
        tableView.rowHeight = 46
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .none
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
    }

    // MARK: - DashboardPanel

    func startRefresh() {
        guard scanner == nil else { return }
        toast.dismiss()
        let scanner = DiskScanner()
        let scope = self.scope
        self.scanner = scanner
        scanner.scan(scope, progress: { [weak self, weak scanner] update in
            guard let self, let scanner, self.scanner === scanner else { return }
            self.show(update)
        }, completion: { [weak self, weak scanner] result in
            guard let self, let scanner, self.scanner === scanner else { return }
            self.scanner = nil
            if let result {
                self.results[scope] = result
                self.resultsVersion += 1
            }
            self.refreshVolume()
            self.render()
        })
        os_log("Disk scan started: %{public}@", log: log, type: .info, scope.rawValue)
        render()
    }

    func stopRefresh(announce: Bool) {
        guard let scanner else { return }
        scanner.cancel()
        self.scanner = nil
        os_log("Disk scan stopped", log: log, type: .info)
        render()
        guard announce else { return }
        if let previous = results[scope] {
            let time = DateFormatter.localizedString(from: previous.finishedAt, dateStyle: .none, timeStyle: .short)
            toast.show("Scan stopped · still showing results from \(time)")
        } else {
            toast.show("Scan stopped")
        }
    }

    // MARK: - Rendering

    private func render() {
        scopePopup.selectItem(at: DiskScanScope.allCases.firstIndex(of: scope) ?? 0)
        scopePopup.isEnabled = !isWorking

        if let result = results[scope] {
            placeholder.isHidden = true
            scrollView.isHidden = showsCleanup
            cleanupList.scrollView.isHidden = !showsCleanup
            let alpha: CGFloat = isWorking ? 0.4 : 1
            scrollView.alphaValue = alpha
            cleanupList.scrollView.alphaValue = alpha
            if showsCleanup {
                cleanupList.show(result.cleanup, pending: pendingIDs)
                let total = result.cleanup.reduce(0) { $0 + $1.size }
                let recommended = result.cleanup.flatMap(\.recommendedItems).reduce(0) { $0 + $1.size }
                asideLabel.stringValue = recommended > 0
                    ? "\(DashboardStyle.bytes(total)) safe to clean · \(DashboardStyle.bytes(recommended)) recommended"
                    : "\(DashboardStyle.bytes(total)) safe to clean"
            } else {
                tableView.reloadData()
                asideLabel.stringValue = "\(result.items.count) largest items"
            }
        } else {
            scrollView.isHidden = true
            cleanupList.scrollView.isHidden = true
            placeholder.isHidden = false
            asideLabel.stringValue = ""
            if isWorking {
                placeholder.showWorking(title: "Scanning \(scope.title)…", message: nil)
            } else {
                let duration = scope == .home
                    ? "Scanning your home folder usually takes under a minute"
                    : "Scanning the entire disk can take a few minutes"
                placeholder.showEmpty(symbol: "internaldrive",
                                      title: "No scan yet",
                                      message: "MiddleShot only scans when you ask. \(duration), and you can stop at any time.",
                                      actionTitle: "Scan \(scope.title)")
            }
        }

        if isWorking {
            statusLine.update(left: "Starting scan…", spinning: true,
                              right: results[scope] == nil ? nil : "Stop keeps the previous results")
        } else if let result = results[scope] {
            let seconds = String(format: "%.0f s", result.duration)
            statusLine.update(
                left: "Scanned \(scope.title) · \(DashboardStyle.count(result.itemCount)) items in \(seconds)",
                right: result.skippedCount > 0 ? "\(DashboardStyle.count(result.skippedCount)) folders skipped — no access" : nil,
                rightIsWarning: true,
                link: result.skippedCount > 0 ? "Grant Full Disk Access…" : nil
            )
        } else {
            statusLine.update(left: "Choose what to scan, then press Refresh")
        }
        onStateChange?()
    }

    private func show(_ update: DiskScanner.Progress) {
        let count = "\(DashboardStyle.count(update.itemCount)) items"
        placeholder.updateProgress(count: count, detail: update.currentFolder)
        statusLine.update(left: "Scanning \(update.currentFolder) · \(count)", spinning: true,
                          right: results[scope] == nil ? nil : "Stop keeps the previous results")
    }

    private func refreshVolume() {
        guard let disk = SystemStats.startupDisk() else {
            volumeNameLabel.stringValue = "Startup disk"
            volumeUsageLabel.stringValue = "Capacity unavailable"
            return
        }
        volumeNameLabel.stringValue = disk.name
        volumeUsageLabel.stringValue = "\(DashboardStyle.bytes(disk.used)) of \(DashboardStyle.bytes(disk.total)) used · \(DashboardStyle.bytes(disk.available)) available"
        volumeBar.segments = [BarView.Segment(fraction: 1 - disk.freeFraction,
                                              color: disk.freeFraction < 0.1 ? .systemOrange : .controlAccentColor)]
    }

    /// The latest finished scan's Safe to Clean total, for the menu bar dropdown.
    var cleanupSummary: (size: Int64, finishedAt: Date)? {
        guard let latest = results.values.max(by: { $0.finishedAt < $1.finishedAt }) else { return nil }
        return (latest.cleanup.reduce(0) { $0 + $1.size }, latest.finishedAt)
    }

    func showSafeToClean() {
        showsCleanup = true
        Settings.diskShowsCleanup = true
        modeControl.selectedSegment = 1
        render()
    }

    // MARK: - Largest Items table

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        switch tableColumn?.identifier.rawValue {
        case "name":
            let (title, color) = Self.chip(for: item.category)
            return nameCell(icon: NSWorkspace.shared.icon(forFile: item.url.path),
                            name: item.displayName,
                            chip: ChipView(text: title, color: color),
                            detail: item.displayPath, detailToolTip: item.url.path)
        case "bar":
            let bar = BarView(thickness: 5)
            let largest = items.first?.size ?? 1
            let isProtected: Bool
            if case .protected = item.category { isProtected = true } else { isProtected = false }
            bar.segments = [BarView.Segment(fraction: Double(item.size) / Double(max(largest, 1)),
                                            color: isProtected ? .tertiaryLabelColor : .controlAccentColor)]
            return centeredCell(bar, alignment: .width)
        case "size":
            let label = DashboardStyle.numberLabel()
            label.stringValue = DashboardStyle.bytes(item.size)
            return centeredCell(label, alignment: .trailing)
        case "actions":
            let reveal = NSButton(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Show in Finder") ?? NSImage(),
                                  target: self, action: #selector(revealPressed(_:)))
            reveal.isBordered = false
            reveal.contentTintColor = .secondaryLabelColor
            reveal.toolTip = "Show in Finder"
            let action: NSView
            if case .protected(let reason) = item.category {
                action = DashboardStyle.protectedLabel(reason: reason)
            } else {
                action = DashboardStyle.destructiveButton("Move to Trash", target: self, action: #selector(trashPressed(_:)))
            }
            let stack = NSStackView(views: [reveal, action])
            stack.spacing = 8
            return centeredCell(stack, alignment: .trailing)
        default:
            return nil
        }
    }

    private static func chip(for category: DiskItemCategory) -> (String, NSColor) {
        switch category {
        case .rebuildable: return ("Rebuildable", .systemGreen)
        case .reviewFirst: return ("Review first", .systemOrange)
        case .appData: return ("App data", .systemPurple)
        case .application: return ("Application", .systemPurple)
        case .protected: return ("System", .secondaryLabelColor)
        }
    }

    // MARK: - Controls

    @objc private func modeChanged() {
        showsCleanup = modeControl.selectedSegment == 1
        Settings.diskShowsCleanup = showsCleanup
        render()
    }

    @objc private func scopeChanged() {
        guard let chosen = DiskScanScope.allCases[safe: scopePopup.indexOfSelectedItem] else { return }
        scope = chosen
        Settings.diskScanScope = chosen
        toast.dismiss()
        render()
    }

    @objc private func revealPressed(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard !isWorking, let item = items[safe: row] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - Removing: Largest Items

    @objc private func trashPressed(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard !isWorking, let item = items[safe: row], let window = view.window else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSWorkspace.shared.icon(forFile: item.url.path)
        alert.messageText = "Move “\(item.displayName)” to the Trash?"
        alert.informativeText = "\(DashboardStyle.bytes(item.size)) · \(item.displayPath)\n\n\(item.note) You can put it back from the Trash until you empty it."
        addConfirmButtons(to: alert, title: "Move to Trash")
        alert.beginSheetModal(for: window) { [weak self] response in
            // A scan may have started while the sheet was up (⌘R).
            guard response == .alertSecondButtonReturn, let self, !self.isWorking else { return }
            self.moveToTrash([(item.displayName, [item.url], item.size)])
        }
    }

    // MARK: - Removing: Safe to Clean

    private func confirmClean(_ items: [CleanupItem], in group: CleanupGroup) {
        guard !isWorking, !items.isEmpty, let window = view.window else { return }
        let total = items.reduce(0) { $0 + $1.size }
        let permanent = items.contains(where: \.isPermanent)

        let alert = NSAlert()
        alert.alertStyle = .warning
        if items.count == 1, let url = items[0].revealURL {
            alert.icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        let noun: (singular: String, plural: String)
        switch group.kind {
        case .simulators: noun = ("simulator", "simulators")
        case .runtimes: noun = ("simulator runtime", "simulator runtimes")
        case .androidEmulators: noun = ("emulator", "emulators")
        default: noun = ("item", "items")
        }
        if items.count == 1 {
            let title = items[0].title
            if !permanent {
                alert.messageText = "Move “\(title)” to the Trash?"
            } else if group.kind == .runtimes {
                alert.messageText = "Delete the \(title) simulator runtime?"
            } else {
                alert.messageText = "Delete the “\(title)” \(noun.singular)?"
            }
        } else {
            alert.messageText = permanent
                ? "Delete \(items.count) \(noun.plural)?"
                : "Move \(items.count) \(noun.plural) to the Trash?"
        }

        var lines: [String] = []
        if items.count == 1 {
            lines.append("\(DashboardStyle.bytes(total)) · \(items[0].detail)")
        } else {
            lines.append("\(DashboardStyle.bytes(total)) in total:")
            lines += items.prefix(6).map { "• \($0.title) — \(DashboardStyle.bytes($0.size))" }
            if items.count > 6 { lines.append("…and \(items.count - 6) more") }
        }
        let ending = permanent
            ? "This can't be undone."
            : "You can put \(items.count == 1 ? "it" : "them") back from the Trash until you empty it."
        alert.informativeText = lines.joined(separator: "\n") + "\n\n\(group.consequence) \(ending)"
        addConfirmButtons(to: alert, title: permanent ? "Delete" : "Move to Trash")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self, !self.isWorking else { return }
            self.clean(items.filter { !self.pendingIDs.contains($0.id) })
        }
    }

    private func clean(_ items: [CleanupItem]) {
        var toTrash: [TrashEntry] = []
        var toDelete: [CleanupItem] = []
        for item in items {
            if case .trash(let urls) = item.action {
                toTrash.append((item.title, urls, item.size))
            } else {
                toDelete.append(item)
            }
        }
        if !toTrash.isEmpty { moveToTrash(toTrash) }
        if !toDelete.isEmpty { deleteWithSimctl(toDelete) }
    }

    /// Moves everything to the Trash, drops it from both views in every scope,
    /// and offers Undo — which puts the files back and restores the lists
    /// exactly as they were.
    private func moveToTrash(_ entries: [TrashEntry]) {
        let before = results
        var moved: [(original: URL, trashed: URL)] = []
        var succeeded: [TrashEntry] = []
        var failures: [(name: String, error: Error)] = []
        for entry in entries {
            // The scan can be hours old: re-check every path right now.
            if let reason = entry.urls.lazy.compactMap(DiskScanner.refusalReason(forTrashing:)).first {
                os_log("Refused to trash %{public}@: %{public}@", log: log, type: .info, entry.name, reason)
                failures.append((entry.name, CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: reason])))
                continue
            }
            var movedHere: [(original: URL, trashed: URL)] = []
            do {
                for url in entry.urls {
                    movedHere.append((url, try DiskScanner.moveToTrash(url)))
                }
                moved += movedHere
                succeeded.append(entry)
            } catch {
                // All of an entry or none of it: put back what already moved
                // (an emulator's .avd without its .ini would be half-deleted).
                for part in movedHere.reversed() {
                    try? DiskScanner.restore(part.trashed, to: part.original)
                }
                os_log("Move to Trash failed for %{public}@: %{public}@", log: log, type: .error,
                       entry.name, "\(error)")
                failures.append((entry.name, error))
            }
        }
        os_log("Moved %d items to Trash", log: log, type: .info, moved.count)
        removeFromResults(urls: succeeded.flatMap(\.urls), ids: [])
        resultsVersion += 1
        let versionAfterTrash = resultsVersion
        render()

        if !succeeded.isEmpty {
            let what = succeeded.count == 1 ? "“\(succeeded[0].name)”" : "\(succeeded.count) items"
            let freed = succeeded.reduce(0) { $0 + $1.size }
            toast.show("Moved \(what) to Trash · \(DashboardStyle.bytes(freed)) frees up when you empty it") { [weak self] in
                self?.undoTrash(moved, restoring: before, ifStillAt: versionAfterTrash)
            }
        }
        presentFailures(failures, verb: "move to the Trash")
    }

    private func undoTrash(_ moved: [(original: URL, trashed: URL)], restoring before: [DiskScanScope: DiskScanResult],
                           ifStillAt version: Int) {
        var failed: Error?
        for entry in moved.reversed() {
            do {
                try DiskScanner.restore(entry.trashed, to: entry.original)
            } catch {
                // Keep going: one item that can't come back mustn't strand the rest.
                os_log("Restore from Trash failed for %{public}@: %{public}@", log: log, type: .error,
                       entry.original.path, "\(error)")
                failed = failed ?? error
            }
        }
        if let failed {
            view.window.map { NSAlert(error: failed).beginSheetModal(for: $0) }
        }
        // Only roll the lists back if nothing newer (a scan, a simulator
        // deletion) has replaced them since; otherwise the files are back and a
        // rescan will show them.
        if failed == nil, resultsVersion == version {
            results = before
        }
        render()
    }

    private func deleteWithSimctl(_ items: [CleanupItem]) {
        let ids = Set(items.map(\.id))
        pendingIDs.formUnion(ids)
        render()
        DispatchQueue.global(qos: .userInitiated).async {
            var deleted: [CleanupItem] = []
            var failures: [(name: String, error: Error)] = []
            for item in items {
                let arguments: [String]
                switch item.action {
                case .deleteSimulator(let udid): arguments = ["delete", udid]
                case .deleteRuntime(let identifier): arguments = ["runtime", "delete", identifier]
                case .trash: continue
                }
                switch SimulatorInventory.runSimctl(arguments) {
                case .success: deleted.append(item)
                case .failure(let error): failures.append((item.title, error))
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingIDs.subtract(ids)
                self.removeFromResults(urls: [], ids: Set(deleted.map(\.id)))
                self.resultsVersion += 1
                self.refreshVolume()
                self.render()
                if !deleted.isEmpty {
                    let what = deleted.count == 1 ? "“\(deleted[0].title)”" : "\(deleted.count) items"
                    let freed = deleted.reduce(0) { $0 + $1.size }
                    os_log("simctl deleted %d items", log: log, type: .info, deleted.count)
                    self.toast.show("Deleted \(what) · \(DashboardStyle.bytes(freed)) freed")
                }
                self.presentFailures(failures, verb: "delete")
            }
        }
    }

    /// Drops removed things from every scope's lists. A trashed folder also
    /// takes along any cleanup item inside it.
    private func removeFromResults(urls: [URL], ids: Set<String>) {
        let paths = urls.map(\.path)
        func isRemoved(_ url: URL) -> Bool {
            paths.contains { url.path == $0 || url.path.hasPrefix($0 + "/") }
        }
        for (scope, var result) in results {
            result.items.removeAll { isRemoved($0.url) }
            for index in result.cleanup.indices {
                result.cleanup[index].items.removeAll { item in
                    ids.contains(item.id) || item.revealURL.map(isRemoved) == true
                }
            }
            result.cleanup.removeAll { $0.items.isEmpty }
            results[scope] = result
        }
    }

    private func addConfirmButtons(to alert: NSAlert, title: String) {
        // No key can confirm this: with a destructive button present macOS gives
        // the alert no default, so Return does nothing and Escape hits Cancel.
        // (Binding Return to Cancel by hand would take Escape away from it.)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: title).hasDestructiveAction = true
    }

    private func presentFailures(_ failures: [(name: String, error: Error)], verb: String) {
        guard let first = failures.first, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1
            ? "Couldn't \(verb) “\(first.name)”"
            : "Couldn't \(verb) \(failures.count) items"
        alert.informativeText = first.error.localizedDescription
        alert.beginSheetModal(for: window)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
