import Cocoa
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "dashboard")

/// The Dashboard window: Disk and CPU & Memory tabs, refreshed only by hand.
///
/// MiddleShot is a menu-bar app (`LSUIElement`), which would leave an open
/// window unreachable from the Dock and ⌘-Tab once it slips behind another app.
/// So while this window is open the app becomes a regular app — Dock icon, menu
/// bar, ⌘-Tab — and drops back to accessory when it closes.
///
/// Closing only hides the window; the controller (and every scan result) lives
/// as long as the status bar item that owns it.
final class DashboardWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    private enum Tab: Int {
        case disk
        case processes
    }

    private static let tabsItem = NSToolbarItem.Identifier("tabs")
    private static let stampItem = NSToolbarItem.Identifier("stamp")
    private static let refreshItem = NSToolbarItem.Identifier("refresh")

    private let diskPanel = DiskUsageViewController()
    private let processPanel = ProcessesViewController()
    private let tabControl = NSSegmentedControl(labels: ["Disk", "CPU & Memory"], trackingMode: .selectOne,
                                                target: nil, action: nil)
    private let stampLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private var stampTimer: Timer?

    private var tab: Tab { Tab(rawValue: tabControl.selectedSegment) ?? .disk }
    private var panel: DashboardPanel { tab == .disk ? diskPanel : processPanel }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = "Dashboard"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 540)
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self

        let content = NSView()
        for child in [diskPanel, processPanel] as [NSViewController] {
            child.view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child.view)
            NSLayoutConstraint.activate([
                child.view.topAnchor.constraint(equalTo: content.topAnchor),
                child.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                child.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        window.contentView = content

        tabControl.selectedSegment = Tab(rawValue: Settings.dashboardTab)?.rawValue ?? 0
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.imagePosition = .imageLeading
        refreshButton.target = self
        refreshButton.action = #selector(refreshOrStop)
        stampLabel.alignment = .right
        stampLabel.lineBreakMode = .byClipping

        diskPanel.onStateChange = { [weak self] in self?.updateToolbar() }
        processPanel.onStateChange = { [weak self] in self?.updateToolbar() }

        let toolbar = NSToolbar(identifier: "Dashboard")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.tabsItem]
        window.toolbar = toolbar

        window.center()
        window.setFrameAutosaveName("Dashboard")
        showSelectedTab()
    }

    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is not used")
    }

    func show() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.applicationIconImage = Self.dockIcon
            Self.installMainMenu(target: self)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateToolbar()
        processPanel.setOnScreen(tab == .processes)
        stampTimer?.invalidate()
        // Only the "3 min ago" text ticks — never the data.
        stampTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateToolbar()
        }
        os_log("Dashboard shown", log: log, type: .info)
    }

    /// Opens straight onto Disk › Safe to Clean (from the menu bar dropdown).
    func showSafeToClean() {
        tabControl.selectedSegment = Tab.disk.rawValue
        tabChanged()
        diskPanel.showSafeToClean()
        show()
    }

    var cleanupSummary: (size: Int64, finishedAt: Date)? {
        diskPanel.cleanupSummary
    }

    func windowWillClose(_ notification: Notification) {
        // A scan nobody can see is just load on the disk.
        diskPanel.stopRefresh(announce: false)
        processPanel.stopRefresh(announce: false)
        processPanel.setOnScreen(false)
        stampTimer?.invalidate()
        stampTimer = nil
        NSApp.setActivationPolicy(.accessory)
        os_log("Dashboard closed", log: log, type: .info)
    }

    // MARK: - Tabs and toolbar

    @objc private func tabChanged() {
        Settings.dashboardTab = tab.rawValue
        showSelectedTab()
    }

    @objc private func showDiskTab() {
        tabControl.selectedSegment = Tab.disk.rawValue
        tabChanged()
    }

    @objc private func showProcessesTab() {
        tabControl.selectedSegment = Tab.processes.rawValue
        tabChanged()
    }

    private func showSelectedTab() {
        diskPanel.view.isHidden = tab != .disk
        processPanel.view.isHidden = tab != .processes
        processPanel.setOnScreen(tab == .processes && window?.isVisible == true)
        updateToolbar()
    }

    @objc private func refreshOrStop() {
        if panel.isWorking {
            panel.stopRefresh(announce: true)
        } else if window?.attachedSheet == nil {
            panel.startRefresh()
        }
    }

    @objc private func refresh() {
        // Not while a confirmation is up: the lists it describes must not change under it.
        guard window?.attachedSheet == nil else { return }
        panel.startRefresh()
    }

    @objc private func stop() {
        panel.stopRefresh(announce: true)
    }

    private func updateToolbar() {
        let panel = self.panel
        stampLabel.attributedStringValue = DashboardStyle.stamp(panel.lastUpdated, never: panel.neverUpdatedText)
        if panel.isWorking {
            refreshButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            refreshButton.attributedTitle = NSAttributedString(string: "Stop", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.systemRed,
            ])
            refreshButton.contentTintColor = .systemRed
            refreshButton.toolTip = "Stop (⌘.)"
        } else {
            refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            refreshButton.title = "Refresh"
            refreshButton.contentTintColor = nil
            refreshButton.toolTip = "Refresh (⌘R)"
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.tabsItem, .flexibleSpace, Self.stampItem, Self.refreshItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.tabsItem:
            item.view = tabControl
            item.label = "View"
        case Self.stampItem:
            item.view = stampLabel
            item.label = "Updated"
        case Self.refreshItem:
            item.view = refreshButton
            item.label = "Refresh"
        default:
            return nil
        }
        return item
    }

    // MARK: - Menu bar (only visible while the window is open)

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showDiskTab):
            menuItem.state = tab == .disk ? .on : .off
        case #selector(showProcessesTab):
            menuItem.state = tab == .processes ? .on : .off
        case #selector(refresh):
            return !panel.isWorking && window?.attachedSheet == nil
        case #selector(stop):
            return panel.isWorking
        default:
            break
        }
        return true
    }

    private static func installMainMenu(target: DashboardWindowController) {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MiddleShot",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MiddleShot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MiddleShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let viewMenu = NSMenu(title: "View")
        for (title, action, key) in [("Disk", #selector(showDiskTab), "1"),
                                     ("CPU & Memory", #selector(showProcessesTab), "2")] {
            viewMenu.addItem(withTitle: title, action: action, keyEquivalent: key).target = target
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = target
        viewMenu.addItem(withTitle: "Stop", action: #selector(stop), keyEquivalent: ".").target = target

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        for (title, submenu) in [("MiddleShot", appMenu), ("View", viewMenu), ("Window", windowMenu)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// The bundle ships no icon file (the app never had a Dock presence), so
    /// the Dock tile is drawn from the same symbol as the menu bar item.
    private static let dockIcon: NSImage = {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 50, dy: 50), xRadius: 92, yRadius: 92)
            NSGradient(starting: NSColor(srgbRed: 0.27, green: 0.58, blue: 1.0, alpha: 1),
                       ending: NSColor(srgbRed: 0.03, green: 0.35, blue: 0.9, alpha: 1))?
                .draw(in: tile, angle: -90)
            let configuration = NSImage.SymbolConfiguration(pointSize: 210, weight: .medium)
                .applying(.init(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let size = symbol.size
                symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                       width: size.width, height: size.height))
            }
            return true
        }
    }()
}
