import Cocoa
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "dashboard")

/// CPU & Memory tab: system load, memory, pressure, then the top ten apps (or
/// processes) by CPU or memory, each with Force Quit.
///
/// In Apps mode an app with several processes expands: editors built on VS Code
/// into one row per window and per Claude Code session, other apps into their
/// busiest processes.
final class ProcessesViewController: NSViewController, DashboardPanel, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let rowLimit = 10

    private enum SortKey: String {
        case cpu, memory
    }

    /// Outline items must be objects; rebuilt on every render.
    private final class Node {
        let row: ProcessRow
        let children: [Node]
        init(_ row: ProcessRow, children: [Node]) {
            self.row = row
            self.children = children
        }

        /// Survives a refresh, so expanded rows stay expanded.
        var expansionKey: String { "\(row.kind)|\(row.pid)|\(row.name)" }
    }

    var onStateChange: (() -> Void)?
    let neverUpdatedText = "No snapshot yet"
    var lastUpdated: Date? { snapshot?.takenAt }
    var isWorking: Bool { sampler != nil }

    private var snapshot: ProcessSnapshot?
    private var sampler: ProcessSampler?
    private var showsAllProcesses = Settings.showsAllProcesses
    private var sortKey = SortKey.cpu
    private var nodes: [Node] = []
    private var expandedKeys: Set<String> = []
    private var iconCache: [String: NSImage] = [:]

    private let cpuValueLabel = NSTextField(labelWithString: "")
    private let cpuBar = BarView(thickness: 8)
    private let memoryValueLabel = NSTextField(labelWithString: "")
    private let memoryBar = BarView(thickness: 8)
    private let pressureChip = ChipView(text: "—", color: .secondaryLabelColor)
    private let swapLabel = DashboardStyle.label("", size: 12, color: .secondaryLabelColor)
    private let pressureGauge = PressureGaugeView()
    private let filterControl = NSSegmentedControl(labels: ["Apps", "All Processes"], trackingMode: .selectOne,
                                                   target: nil, action: nil)
    private let asideLabel = DashboardStyle.label("", size: 11.5, color: .tertiaryLabelColor)
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let placeholder = PlaceholderView()
    private let statusLine = StatusLine()
    private let toast = ToastView()

    // MARK: - Layout

    override func loadView() {
        let root = NSView()

        let pressureRow = NSStackView(views: [pressureChip, swapLabel])
        pressureRow.spacing = 8
        let tiles = NSStackView(views: [
            tile(title: "CPU load · sampled over 1 s", value: cpuValueLabel, footer: cpuBar),
            tile(title: "Memory used", value: memoryValueLabel, footer: memoryBar),
            tile(title: "Memory pressure", value: pressureRow, footer: pressureGauge),
        ])
        tiles.distribution = .fillEqually
        tiles.spacing = 12

        filterControl.controlSize = .small
        filterControl.selectedSegment = showsAllProcesses ? 1 : 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        autoRefreshBox.controlSize = .small
        autoRefreshBox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        autoRefreshBox.state = Settings.processesAutoRefresh ? .on : .off
        autoRefreshBox.target = self
        autoRefreshBox.action = #selector(autoRefreshToggled)
        let tools = NSStackView(views: [filterControl, autoRefreshBox, NSView(), asideLabel])
        tools.spacing = 8
        tools.setCustomSpacing(14, after: filterControl)

        configureOutline()
        placeholder.onAction = { [weak self] in self?.startRefresh() }
        placeholder.onStop = { [weak self] in self?.stopRefresh(announce: true) }

        for view in [tiles, tools, scrollView, placeholder, statusLine, toast] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tiles.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            tiles.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            tiles.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            tools.topAnchor.constraint(equalTo: tiles.bottomAnchor, constant: 12),
            tools.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            tools.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            scrollView.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            scrollView.bottomAnchor.constraint(equalTo: statusLine.topAnchor, constant: -8),
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
        ])

        view = root
        render()
    }

    private func tile(title: String, value: NSView, footer: NSView) -> NSView {
        let titleLabel = DashboardStyle.label(title, size: 11.5, color: .secondaryLabelColor)
        let stack = NSStackView(views: [titleLabel, value, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let card = FillView(color: DashboardStyle.cardColor, cornerRadius: 12)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            value.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
        return card
    }

    private func configureOutline() {
        let columns: [(id: String, title: String, width: CGFloat, alignment: NSTextAlignment)] = [
            ("name", "App", 300, .left),
            ("pid", "PID", 64, .right),
            ("cpu", "% CPU", 140, .right),
            ("memory", "Memory", 90, .right),
            ("actions", "", 110, .right),
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.headerCell.alignment = spec.alignment
            if spec.id == "name" {
                column.minWidth = 200
            } else {
                column.minWidth = spec.width
                column.maxWidth = spec.width
            }
            if let key = SortKey(rawValue: spec.id) {
                column.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: false)
            }
            outlineView.addTableColumn(column)
            if spec.id == "name" {
                outlineView.outlineTableColumn = column
            }
        }
        outlineView.sortDescriptors = [NSSortDescriptor(key: SortKey.cpu.rawValue, ascending: false)]
        outlineView.style = .inset
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.selectionHighlightStyle = .none
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.indentationPerLevel = 14
        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
    }

    // MARK: - DashboardPanel

    // MARK: - Auto refresh

    /// The one exception to the Dashboard's manual refresh (user decision,
    /// 2026-09-25): like Activity Monitor's default, a fresh snapshot every
    /// 5 s while this tab is on screen. A sample is ~1 s of `proc_pid_rusage`
    /// deltas, light enough to repeat; the Disk tab's minute-long walk is not.
    static let autoRefreshInterval: TimeInterval = 5

    private var autoTimer: Timer?
    /// An automatic round runs quietly: it doesn't turn Refresh into Stop or
    /// dim the list, it just swaps in the new numbers when they're ready.
    private var quietSampler: ProcessSampler?
    private let autoRefreshBox = NSButton(checkboxWithTitle: "Auto-refresh every 5 s", target: nil, action: nil)

    /// Called by the window with whether this tab is currently on screen.
    func setOnScreen(_ onScreen: Bool) {
        guard onScreen, Settings.processesAutoRefresh else {
            autoTimer?.invalidate()
            autoTimer = nil
            quietSampler?.cancel()
            quietSampler = nil
            return
        }
        guard autoTimer == nil else { return }
        let timer = Timer(timeInterval: Self.autoRefreshInterval, repeats: true) { [weak self] _ in
            self?.autoRefresh()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        autoTimer = timer
        // Coming back to a stale snapshot: refresh now rather than in 5 s.
        if let snapshot, Date().timeIntervalSince(snapshot.takenAt) < Self.autoRefreshInterval { return }
        snapshot == nil ? startRefresh() : autoRefresh()
    }

    private func autoRefresh() {
        guard sampler == nil, quietSampler == nil, let window = view.window,
              window.occlusionState.contains(.visible),
              // The rows a confirmation describes must not move under it.
              window.attachedSheet == nil else { return }
        let sampler = ProcessSampler()
        quietSampler = sampler
        sampler.sample { [weak self, weak sampler] snapshot in
            guard let self, let sampler, self.quietSampler === sampler else { return }
            self.quietSampler = nil
            // A sheet that opened during the second of sampling wins too.
            guard let snapshot, self.view.window?.attachedSheet == nil else { return }
            self.snapshot = snapshot
            self.render()
        }
    }

    @objc private func autoRefreshToggled() {
        Settings.processesAutoRefresh = autoRefreshBox.state == .on
        setOnScreen(Settings.processesAutoRefresh && !view.isHidden && view.window?.isVisible == true)
        render()
    }

    func startRefresh() {
        guard sampler == nil else { return }
        quietSampler?.cancel()
        quietSampler = nil
        toast.dismiss()
        let sampler = ProcessSampler()
        self.sampler = sampler
        sampler.sample { [weak self, weak sampler] snapshot in
            guard let self, let sampler, self.sampler === sampler else { return }
            self.sampler = nil
            if let snapshot {
                self.snapshot = snapshot
            }
            self.render()
        }
        render()
    }

    func stopRefresh(announce: Bool) {
        guard let sampler else { return }
        sampler.cancel()
        self.sampler = nil
        render()
        guard announce else { return }
        if let previous = snapshot {
            let time = DateFormatter.localizedString(from: previous.takenAt, dateStyle: .none, timeStyle: .short)
            toast.show("Sampling stopped · still showing the snapshot from \(time)")
        } else {
            toast.show("Sampling stopped")
        }
    }

    // MARK: - Rendering

    private func render() {
        renderSummary()

        let appCount = snapshot?.apps.count
        let processCount = snapshot?.processes.count
        filterControl.setLabel(appCount.map { "Apps  \($0)" } ?? "Apps", forSegment: 0)
        filterControl.setLabel(processCount.map { "All Processes  \(DashboardStyle.count($0))" } ?? "All Processes",
                               forSegment: 1)
        outlineView.tableColumns.first?.title = showsAllProcesses ? "Process" : "App"

        if let snapshot {
            let source = showsAllProcesses ? snapshot.processes : snapshot.apps
            nodes = sorted(source).prefix(Self.rowLimit).map(makeNode)
            placeholder.isHidden = true
            scrollView.isHidden = false
            scrollView.alphaValue = isWorking ? 0.4 : 1
            asideLabel.stringValue = showsAllProcesses ? "" : "Helpers are counted with their app · expand an app for its windows"
        } else {
            nodes = []
            scrollView.isHidden = true
            placeholder.isHidden = false
            asideLabel.stringValue = ""
            if isWorking {
                placeholder.showWorking(title: "Sampling CPU…", message: "Measuring every process for one second.")
            } else {
                placeholder.showEmpty(symbol: "cpu", title: "No snapshot yet",
                                      message: Settings.processesAutoRefresh
                                        ? "Takes about a second, then refreshes every 5 seconds while this tab is open."
                                        : "Takes about a second. The numbers stay as they are until you press Refresh again.",
                                      actionTitle: "Take Snapshot")
            }
        }
        outlineView.reloadData()
        restoreExpansion(nodes)

        if isWorking {
            statusLine.update(left: "Sampling CPU for 1 second…", spinning: true)
        } else if let snapshot {
            let sorted = sortKey == .cpu ? "% CPU" : "Memory"
            statusLine.update(
                left: "\(snapshot.apps.count) apps · \(DashboardStyle.count(snapshot.processes.count)) processes · top \(Self.rowLimit) by \(sorted)",
                right: snapshot.unmeasuredCount > 0
                    ? "\(DashboardStyle.count(snapshot.unmeasuredCount)) processes owned by macOS can't be measured"
                    : nil
            )
        } else {
            statusLine.update(left: "Press Refresh to take a snapshot")
        }
        onStateChange?()
    }

    private func sorted(_ rows: [ProcessRow]) -> [ProcessRow] {
        rows.sorted { sortKey == .cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory }
    }

    private func makeNode(_ row: ProcessRow) -> Node {
        // All Processes stays a flat list — its point is to see each process.
        Node(row, children: showsAllProcesses ? [] : sorted(row.children).map(makeNode))
    }

    private func restoreExpansion(_ nodes: [Node]) {
        for node in nodes where expandedKeys.contains(node.expansionKey) {
            outlineView.expandItem(node)
            restoreExpansion(node.children)
        }
    }

    private func renderSummary() {
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        let noteAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        guard let load = snapshot?.load else {
            let dash = NSAttributedString(string: "—", attributes: [.font: valueFont, .foregroundColor: NSColor.labelColor])
            cpuValueLabel.attributedStringValue = dash
            memoryValueLabel.attributedStringValue = dash
            cpuBar.segments = []
            memoryBar.segments = []
            pressureChip.update(text: "—", color: .secondaryLabelColor)
            swapLabel.stringValue = ""
            pressureGauge.pressure = nil
            return
        }

        let cpu = NSMutableAttributedString(string: String(format: "%.0f%%", (load.userFraction + load.systemFraction) * 100),
                                            attributes: [.font: valueFont, .foregroundColor: NSColor.labelColor])
        cpu.append(NSAttributedString(string: String(format: "  user %.0f · system %.0f",
                                                     load.userFraction * 100, load.systemFraction * 100),
                                      attributes: noteAttributes))
        cpuValueLabel.attributedStringValue = cpu
        cpuBar.segments = [
            BarView.Segment(fraction: load.userFraction, color: .controlAccentColor),
            BarView.Segment(fraction: load.systemFraction, color: .systemOrange),
        ]

        let memory = NSMutableAttributedString(string: DashboardStyle.memory(load.memoryUsed),
                                               attributes: [.font: valueFont, .foregroundColor: NSColor.labelColor])
        memory.append(NSAttributedString(string: "  of \(DashboardStyle.memory(load.memoryTotal))", attributes: noteAttributes))
        memoryValueLabel.attributedStringValue = memory
        memoryBar.segments = [BarView.Segment(fraction: Double(load.memoryUsed) / Double(max(load.memoryTotal, 1)),
                                              color: .controlAccentColor)]

        switch load.pressure {
        case .normal: pressureChip.update(text: "Normal", color: .systemGreen)
        case .warning: pressureChip.update(text: "Warning", color: .systemOrange)
        case .critical: pressureChip.update(text: "Critical", color: .systemRed)
        }
        swapLabel.stringValue = "Swap \(DashboardStyle.memory(load.swapUsed))"
        pressureGauge.pressure = load.pressure
    }

    // MARK: - Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? nodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? Node {
            expandedKeys.insert(node.expansionKey)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? Node {
            expandedKeys.remove(node.expansionKey)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        outlineView.parent(forItem: item) == nil ? 46 : 40
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let key = outlineView.sortDescriptors.first?.key.flatMap(SortKey.init(rawValue:)) else { return }
        // Only the biggest consumers are listed, so the order is always
        // descending — clicking the active header again doesn't flip it.
        if outlineView.sortDescriptors.first?.ascending == true {
            outlineView.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: false)]
            return
        }
        sortKey = key
        render()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let process = (item as? Node)?.row else { return nil }
        switch tableColumn?.identifier.rawValue {
        case "name":
            return nameCell(icon: icon(for: process), name: process.name, chip: nil, detail: detail(for: process),
                            iconTint: symbolName(for: process) == nil ? nil : .secondaryLabelColor)
        case "pid":
            let label = DashboardStyle.numberLabel(color: .secondaryLabelColor)
            // A window or the shared group is many processes; no single PID says anything.
            label.stringValue = [.window, .shared].contains(process.kind) && !process.targets.isEmpty ? "—" : "\(process.pid)"
            return centeredCell(label, alignment: .trailing)
        case "cpu":
            let bar = BarView(thickness: 5)
            bar.segments = [BarView.Segment(fraction: min(process.cpu, 100) / 100,
                                            color: process.cpu >= 50 ? .systemOrange : .controlAccentColor)]
            let value = DashboardStyle.numberLabel()
            value.stringValue = String(format: "%.1f", process.cpu)
            let stack = NSStackView(views: [bar, value])
            stack.spacing = 8
            NSLayoutConstraint.activate([value.widthAnchor.constraint(equalToConstant: 44)])
            return centeredCell(stack, alignment: .width)
        case "memory":
            let label = DashboardStyle.numberLabel()
            label.stringValue = DashboardStyle.memory(process.memory)
            return centeredCell(label, alignment: .trailing)
        case "actions":
            if let reason = process.protectionReason {
                return centeredCell(DashboardStyle.protectedLabel(reason: reason, text: process.kind == .shared ? "Shared" : "Protected"),
                                    alignment: .trailing)
            }
            return centeredCell(DashboardStyle.destructiveButton("Force Quit", target: self,
                                                                 action: #selector(forceQuitPressed(_:))),
                                alignment: .trailing)
        default:
            return nil
        }
    }

    private func detail(for process: ProcessRow) -> String {
        if let detail = process.detail { return detail }
        switch process.kind {
        case .current: return process.pid == getpid() ? "This app" : "Started by MiddleShot"
        case .app where !showsAllProcesses:
            return process.processCount == 1 ? "1 process" : "\(process.processCount) processes"
        case .app: return "Application"
        case .helper: return "Part of \(process.owner?.name ?? "an app")"
        case .system: return "macOS system process"
        case .process: return "Process"
        case .window: return "Window"
        case .session: return "Claude Code session"
        case .shared: return "Shared"
        }
    }

    private func symbolName(for process: ProcessRow) -> String? {
        switch process.kind {
        case .window: return "macwindow"
        case .session: return "sparkles"
        case .shared where !process.targets.isEmpty: return "square.stack.3d.up"
        default: return nil
        }
    }

    private func icon(for process: ProcessRow) -> NSImage {
        if let symbol = symbolName(for: process),
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) {
            return image
        }
        guard let path = process.iconPath else {
            return NSWorkspace.shared.icon(for: .unixExecutable)
        }
        if let cached = iconCache[path] {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = image
        return image
    }

    // MARK: - Actions

    @objc private func filterChanged() {
        showsAllProcesses = filterControl.selectedSegment == 1
        Settings.showsAllProcesses = showsAllProcesses
        toast.dismiss()
        render()
    }

    @objc private func forceQuitPressed(_ sender: NSButton) {
        guard !isWorking, let process = (outlineView.item(atRow: outlineView.row(for: sender)) as? Node)?.row,
              let window = view.window else { return }

        let title: String
        let body: String
        let owner = process.owner?.name ?? "the app"
        switch process.kind {
        case .window:
            let sessions = process.children.filter { $0.kind == .session }.count
            title = "Force quit everything “\(process.name)” runs in \(owner)?"
            body = "\(process.processCount) processes stop at once"
                + (sessions == 0 ? "" : ", including \(sessions) Claude Code session\(sessions == 1 ? "" : "s")")
                + " — extensions, language servers and programs started in this folder. The window itself stays open with your files and unsaved edits; \(owner) offers to restart its extensions."
        case .session:
            title = "Force quit this Claude Code session?"
            body = "\(process.detail ?? "The session") stops at once, along with anything it is running. Its conversation stays in Claude Code's history."
        case .app where NSRunningApplication(processIdentifier: process.pid)?.bundleIdentifier == "com.apple.finder":
            title = "Force quit “\(process.name)”?"
            body = "Finder closes and macOS opens it again right away."
        case .app where !showsAllProcesses && process.processCount > 1:
            title = "Force quit “\(process.name)”?"
            body = "\(process.name) closes immediately, along with its \(process.processCount - 1) other processes. Unsaved changes will be lost."
        case .helper:
            title = "Force quit “\(process.name)”?"
            body = "This process belongs to \(owner). Whatever it serves — a tab, an extension, a build — stops, but \(owner) keeps running."
        default:
            title = "Force quit “\(process.name)”?"
            body = "\(process.name) closes immediately. Unsaved changes will be lost."
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = icon(for: process)
        alert.messageText = title
        let pid = process.targets.isEmpty ? "PID \(process.pid) · " : ""
        alert.informativeText = "\(pid)\(String(format: "%.1f", process.cpu))% CPU · \(DashboardStyle.memory(process.memory))\n\n\(body)"
        // Escape cancels and Return does nothing (see the note on Move to Trash).
        alert.addButton(withTitle: "Cancel")
        let quit = alert.addButton(withTitle: "Force Quit")
        quit.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            // A refresh may have started while the sheet was up.
            guard response == .alertSecondButtonReturn, let self, !self.isWorking else { return }
            self.forceQuit(process)
        }
    }

    private func forceQuit(_ process: ProcessRow) {
        switch ProcessSampler.forceQuit(process) {
        case .failure(let error):
            os_log("Force quit %d failed: %{public}@", log: log, type: .error, process.pid, "\(error)")
            if let window = view.window {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        case .success:
            os_log("Force quit %{public}@ (%d, %d processes)", log: log, type: .info, process.name, process.pid,
                   max(process.targets.count, 1))
            if var snapshot {
                var ended = Set(process.targets.map(\.pid))
                ended.insert(process.pid)
                if process.kind == .app {
                    ended.formUnion(snapshot.processes.filter { $0.owner?.pid == process.pid }.map(\.pid))
                }
                snapshot.apps = Self.removing(ended, from: snapshot.apps, dropGroupsOf: process)
                snapshot.processes.removeAll { ended.contains($0.pid) }
                self.snapshot = snapshot
            }
            render()
            toast.show("Force quit “\(process.name)”")
        }
    }

    /// The rows left once `pids` are gone. Numbers on the parents stay as
    /// sampled — the next Refresh recounts them.
    private static func removing(_ pids: Set<pid_t>, from rows: [ProcessRow], dropGroupsOf ended: ProcessRow) -> [ProcessRow] {
        rows.compactMap { row in
            let isEndedGroup = row.kind == ended.kind && row.pid == ended.pid && row.name == ended.name
            if isEndedGroup || (row.targets.isEmpty && pids.contains(row.pid)) { return nil }
            var row = row
            row.children = removing(pids, from: row.children, dropGroupsOf: ended)
            return row
        }
    }
}
