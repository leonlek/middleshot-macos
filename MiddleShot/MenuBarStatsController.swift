import Cocoa
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "dashboard")

/// Live readouts in the menu bar, as one status item made of modules (CPU,
/// memory, network, disk, …) that can be reordered and hidden.
///
/// Unlike the Dashboard this refreshes on its own — a menu bar readout that
/// needs a click to update is just a stale number. Only shown modules take
/// readings, and the per-process sample behind "Using the most CPU" runs only
/// while the dropdown is open.
final class MenuBarStatsController: NSObject, NSMenuDelegate {
    var onOpenDashboard: (() -> Void)?

    var onOpenSafeToClean: (() -> Void)? {
        didSet {
            disk.onOpenSafeToClean = { [weak self] in self?.onOpenSafeToClean?() }
        }
    }

    var cleanupSummary: (() -> (size: Int64, finishedAt: Date)?)? {
        didSet { disk.cleanupSummary = cleanupSummary }
    }

    private let disk = DiskModule()
    /// Every module, in its default order. A new module goes here.
    private(set) lazy var modules: [MenuBarModule] = [NetworkModule(), MemoryModule(), CPUModule(), disk]

    private static let timelineCapacity = 60

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private let menuContainer = StatsMenuContainerView()
    private var isMenuOpen = false
    private var processSampler: ProcessSampler?
    private var settingsMenus: [NSMenu] = []
    private var settingsWindow: MenuBarStatsSettingsWindowController?
    /// What the menu bar currently shows; a tick that would draw the same
    /// thing does nothing.
    private var renderedKey: String?
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Order and visibility

    /// All modules in the person's order.
    var orderedModules: [MenuBarModule] {
        let saved = Settings.menuBarModuleOrder
        let listed = saved.compactMap { id in modules.first { $0.id == id } }
        return listed + modules.filter { !saved.contains($0.id) }
    }

    private var shownModules: [MenuBarModule] {
        orderedModules.filter(isShown)
    }

    func isShown(_ module: MenuBarModule) -> Bool {
        Settings.isMenuBarModuleEnabled(module.id, default: module.isEnabledByDefault)
    }

    func setShown(_ shown: Bool, for module: MenuBarModule) {
        Settings.setMenuBarModule(module.id, enabled: shown)
        settingsChanged()
    }

    func move(moduleAt source: Int, to destination: Int) {
        var ids = orderedModules.map(\.id)
        let id = ids.remove(at: source)
        ids.insert(id, at: min(destination, ids.count))
        Settings.menuBarModuleOrder = ids
        settingsChanged()
    }

    func setStyle(_ style: MenuBarStatsStyle) {
        Settings.menuBarStatsStyle = style
        settingsChanged()
    }

    func setColorGraphs(_ color: Bool) {
        Settings.menuBarColorGraphs = color
        settingsChanged()
    }

    func setUpdateInterval(_ seconds: TimeInterval) {
        Settings.menuBarUpdateInterval = seconds
        // Samples taken at another pace would squash or stretch the graphs.
        modules.forEach { $0.resetHistory() }
        settingsChanged()
    }

    func showSettingsWindow() {
        statusItem?.menu?.cancelTracking()
        let controller = settingsWindow ?? MenuBarStatsSettingsWindowController(stats: self)
        settingsWindow = controller
        controller.show()
    }

    /// Creates, updates or removes the status item to match Settings.
    func apply() {
        let shown = shownModules
        guard !shown.isEmpty else {
            stopTimer()
            if let statusItem {
                appearanceObservation = nil
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "MenuBarStats"
            item.button?.imagePosition = .imageOnly
            item.menu = makeMenu()
            // The bitmap bakes in label colors, so a light/dark menu bar switch
            // needs a fresh one.
            // Setting a new image also reports an appearance "change", so this
            // must not force a redraw: `render` compares keys (which include the
            // appearance name) and only draws when the appearance really moved.
            appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.render(self.shownModules)
                }
            }
            statusItem = item
        }
        renderedKey = nil
        menuContainer.show(sections: shown.map(\.menuSection))
        restartTimer()
    }

    private func settingsChanged() {
        os_log("Menu bar stats: %{public}@ style=%{public}@ color=%d every %.0fs", log: log, type: .info,
               shownModules.map(\.id).joined(separator: ","), Settings.menuBarStatsStyle.rawValue,
               Settings.menuBarColorGraphs, Settings.menuBarUpdateInterval)
        apply()
        settingsWindow?.reload()
    }

    // MARK: - Sampling

    private func restartTimer() {
        stopTimer()
        let interval = Settings.menuBarUpdateInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.sample() }
        timer.tolerance = interval * 0.1
        // .common, so readings keep coming while a menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let shown = shownModules
        shown.forEach { $0.sample(now: now) }
        render(shown)
        if isMenuOpen {
            updateSections(shown)
        }
    }

    private func render(_ shown: [MenuBarModule]) {
        guard let button = statusItem?.button else { return }
        let color = Settings.menuBarColorGraphs
        let style = Settings.menuBarStatsStyle
        let parts = shown.map { $0.part(style: style, color: color) }
        let appearance = button.effectiveAppearance
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(style.rawValue)|\(color)|\(appearance.name.rawValue)|\(scale)|" + parts.map(\.key).joined(separator: "|")
        guard key != renderedKey else { return }
        renderedKey = key
        button.image = MenuBarDrawing.image(parts: parts, color: color, appearance: appearance, scale: scale)
        button.setAccessibilityLabel(shown.map(\.accessibilityDescription).joined(separator: ", "))
    }

    private func updateSections(_ shown: [MenuBarModule]) {
        let timeline = MenuBarTimeline(interval: Settings.menuBarUpdateInterval, capacity: Self.timelineCapacity)
        shown.forEach { $0.updateMenuSection(timeline) }
    }

    // MARK: - Dropdown

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let viewItem = NSMenuItem()
        viewItem.view = menuContainer
        menu.addItem(viewItem)
        menu.addItem(.separator())
        let dashboard = NSMenuItem(title: "Open Dashboard…", action: #selector(openDashboard), keyEquivalent: "")
        dashboard.target = self
        menu.addItem(dashboard)
        let settings = NSMenuItem(title: "Menu Bar Stats", action: nil, keyEquivalent: "")
        settings.submenu = makeSettingsMenu()
        menu.addItem(settings)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        isMenuOpen = true
        let shown = shownModules
        shown.forEach { $0.menuWillOpen() }
        // Sections may have grown or shrunk (external drives come and go); the
        // size has to settle before the menu is on screen.
        menuContainer.resize()
        updateSections(shown)

        let wanting = shown.filter(\.wantsProcessSnapshot)
        guard !wanting.isEmpty else { return }
        wanting.forEach { $0.show(nil) }
        let sampler = ProcessSampler()
        processSampler = sampler
        sampler.sample { [weak self, weak sampler] snapshot in
            guard let self, let sampler, self.processSampler === sampler, let snapshot else { return }
            self.processSampler = nil
            wanting.forEach { $0.show(snapshot) }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        isMenuOpen = false
        processSampler?.cancel()
        processSampler = nil
        modules.forEach { $0.menuDidClose() }
    }

    @objc private func openDashboard() {
        onOpenDashboard?()
    }

    /// Modules' action items sit between the sections and "Open Dashboard…";
    /// they're tagged so the next opening can swap them for fresh ones.
    private static let actionItemTag = 7_301

    private func refreshActionItems(in menu: NSMenu) {
        menu.items.filter { $0.tag == Self.actionItemTag }.forEach(menu.removeItem)
        guard let anchor = menu.items.firstIndex(where: { $0.action == #selector(openDashboard) }) else { return }
        for (offset, item) in shownModules.flatMap({ $0.actionMenuItems() }).enumerated() {
            item.tag = Self.actionItemTag
            menu.insertItem(item, at: anchor + offset)
        }
    }

    // MARK: - Settings submenu

    /// The "Menu Bar Stats" submenu. Built once per parent menu (the stats
    /// dropdown and MiddleShot's own menu); refilled each time it opens so it
    /// lists modules in the current order.
    func makeSettingsMenu() -> NSMenu {
        let menu = NSMenu(title: "Menu Bar Stats")
        menu.delegate = self
        settingsMenus.append(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusItem?.menu {
            refreshActionItems(in: menu)
            return
        }
        guard settingsMenus.contains(where: { $0 === menu }) else { return }
        menu.removeAllItems()
        func header(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func option(_ title: String, _ action: Selector, value: Any?, on: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        header("Show")
        for module in orderedModules {
            option(module.title, #selector(toggleModule(_:)), value: module.id, on: isShown(module))
        }
        menu.addItem(.separator())
        header("Style")
        for style in MenuBarStatsStyle.allCases {
            option(style.title, #selector(chooseStyle(_:)), value: style.rawValue,
                   on: style == Settings.menuBarStatsStyle)
        }
        option("Color Graphs", #selector(toggleColor), value: nil, on: Settings.menuBarColorGraphs)
        menu.addItem(.separator())
        header("Update Every")
        for seconds in [1.0, 2.0, 5.0] {
            option(seconds == 1 ? "1 Second" : "\(Int(seconds)) Seconds", #selector(chooseInterval(_:)),
                   value: seconds, on: seconds == Settings.menuBarUpdateInterval)
        }
        menu.addItem(.separator())
        let customize = NSMenuItem(title: "Reorder & Customize…", action: #selector(customize), keyEquivalent: "")
        customize.target = self
        menu.addItem(customize)
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let module = modules.first(where: { $0.id == id }) else { return }
        setShown(!isShown(module), for: module)
    }

    @objc private func toggleColor() {
        setColorGraphs(!Settings.menuBarColorGraphs)
    }

    @objc private func chooseStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = MenuBarStatsStyle(rawValue: raw) else { return }
        setStyle(style)
    }

    @objc private func chooseInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        setUpdateInterval(seconds)
    }

    @objc private func customize() {
        showSettingsWindow()
    }
}
