import Cocoa

/// "Menu Bar Stats" settings: drag modules into order, tick the ones to show,
/// pick the style and update pace. Every change applies to the menu bar at once.
final class MenuBarStatsSettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowType = NSPasteboard.PasteboardType("app.middleshot.menu-bar-module")

    private let stats: MenuBarStatsController
    private let tableView = NSTableView()
    private let stylePopup = NSPopUpButton()
    private let colorCheckbox = NSButton(checkboxWithTitle: "Color graphs", target: nil, action: nil)
    private let intervalPopup = NSPopUpButton()
    private let intervals: [TimeInterval] = [1, 2, 5]
    private let alertCheckbox = NSButton(checkboxWithTitle: "Warn when an app keeps the CPU busy", target: nil, action: nil)
    private let thresholdPopup = NSPopUpButton()
    private let ignoredLabel = NSTextField(wrappingLabelWithString: "")
    private let clearIgnoredButton = NSButton(title: "Clear", target: nil, action: nil)

    init(stats: MenuBarStatsController) {
        self.stats = stats
        let window = ShortcutWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 540),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Menu Bar Stats"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        window.center()
        window.setFrameAutosaveName("MenuBarStatsSettings")
        reload()
    }

    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is not used")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Re-reads everything from Settings (the submenu may have changed it).
    func reload() {
        tableView.reloadData()
        stylePopup.selectItem(at: MenuBarStatsStyle.allCases.firstIndex(of: Settings.menuBarStatsStyle) ?? 0)
        colorCheckbox.state = Settings.menuBarColorGraphs ? .on : .off
        intervalPopup.selectItem(at: intervals.firstIndex(of: Settings.menuBarUpdateInterval) ?? 0)
        alertCheckbox.state = Settings.cpuAlertEnabled ? .on : .off
        thresholdPopup.selectItem(at: Settings.cpuAlertThresholds.firstIndex(of: Settings.cpuAlertThreshold) ?? 1)
        thresholdPopup.isEnabled = Settings.cpuAlertEnabled
        let ignored = Settings.cpuAlertIgnored
        ignoredLabel.stringValue = ignored.isEmpty
            ? "No ignored apps."
            : "Ignored: " + ignored.map { id in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                    .map { FileManager.default.displayName(atPath: $0.path) } ?? id
            }.joined(separator: ", ")
        clearIgnoredButton.isEnabled = !ignored.isEmpty
    }

    // MARK: - Layout

    private func buildContent() {
        let intro = NSTextField(wrappingLabelWithString:
            "Drag to change the order — left to right in the menu bar, top to bottom in its menu. Untick to hide.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("module"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 32
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.rowType])
        tableView.draggingDestinationFeedbackStyle = .gap
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        stylePopup.addItems(withTitles: MenuBarStatsStyle.allCases.map(\.title))
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)
        colorCheckbox.target = self
        colorCheckbox.action = #selector(colorChanged)
        intervalPopup.addItems(withTitles: intervals.map { $0 == 1 ? "1 second" : "\(Int($0)) seconds" })
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged)

        alertCheckbox.target = self
        alertCheckbox.action = #selector(alertChanged)
        thresholdPopup.addItems(withTitles: Settings.cpuAlertThresholds.map { String(format: "Over %.0f%% of a core for a minute", $0) })
        thresholdPopup.target = self
        thresholdPopup.action = #selector(thresholdChanged)
        ignoredLabel.font = .systemFont(ofSize: 11.5)
        ignoredLabel.textColor = .secondaryLabelColor
        ignoredLabel.preferredMaxLayoutWidth = 220
        clearIgnoredButton.controlSize = .small
        clearIgnoredButton.target = self
        clearIgnoredButton.action = #selector(clearIgnored)
        let ignoredRow = NSStackView(views: [ignoredLabel, clearIgnoredButton])
        ignoredRow.alignment = .firstBaseline

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Style:"), stylePopup],
            [NSGridCell.emptyContentView, colorCheckbox],
            [NSTextField(labelWithString: "Update every:"), intervalPopup],
            [NSTextField(labelWithString: "CPU alert:"), alertCheckbox],
            [NSGridCell.emptyContentView, thresholdPopup],
            [NSGridCell.emptyContentView, ignoredRow],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8

        let content = NSView()
        for view in [intro, scroll, grid] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            grid.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 14),
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window?.contentView = content
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        stats.orderedModules.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let module = stats.orderedModules[safe: row] else { return nil }
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(visibilityChanged(_:)))
        checkbox.state = stats.isShown(module) ? .on : .off
        checkbox.identifier = NSUserInterfaceItemIdentifier(module.id)
        checkbox.setAccessibilityLabel("Show \(module.title)")

        let icon = NSImageView(image: NSImage(systemSymbolName: module.symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "square", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let title = NSTextField(labelWithString: module.title)
        let handle = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal",
                                                accessibilityDescription: "Drag to reorder") ?? NSImage())
        handle.contentTintColor = .tertiaryLabelColor
        handle.toolTip = "Drag to reorder"

        let row = NSStackView(views: [checkbox, icon, title, NSView(), handle])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8)
        return row
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above, info.draggingSource as? NSTableView === tableView else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowType),
              let source = Int(text) else { return false }
        // Dropping "above" a row below the source shifts every index by one.
        let destination = source < row ? row - 1 : row
        guard destination != source else { return false }
        stats.move(moduleAt: source, to: destination)
        return true
    }

    // MARK: - Actions

    @objc private func visibilityChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let module = stats.modules.first(where: { $0.id == id }) else { return }
        stats.setShown(sender.state == .on, for: module)
    }

    @objc private func styleChanged() {
        guard let style = MenuBarStatsStyle.allCases[safe: stylePopup.indexOfSelectedItem] else { return }
        stats.setStyle(style)
    }

    @objc private func colorChanged() {
        stats.setColorGraphs(colorCheckbox.state == .on)
    }

    @objc private func alertChanged() {
        stats.setCPUAlert(enabled: alertCheckbox.state == .on)
    }

    @objc private func thresholdChanged() {
        guard let percent = Settings.cpuAlertThresholds[safe: thresholdPopup.indexOfSelectedItem] else { return }
        stats.setCPUAlertThreshold(percent)
    }

    @objc private func clearIgnored() {
        stats.clearCPUAlertIgnored()
    }

    @objc private func intervalChanged() {
        guard let seconds = intervals[safe: intervalPopup.indexOfSelectedItem] else { return }
        stats.setUpdateInterval(seconds)
    }
}

/// MiddleShot usually runs without a main menu (it is a menu bar app), so ⌘W
/// has nothing to dispatch through. This window handles it itself.
private final class ShortcutWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
