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
    private let cpu = CPUModule()
    /// Every module, in its default order. A new module goes here.
    private(set) lazy var modules: [MenuBarModule] = [NetworkModule(), MemoryModule(), cpu, disk]

    private let cpuAlert = CPUAlertMonitor()
    private var alertPopover: NSPopover?
    private let alertContent = CPUAlertViewController()
    /// Where each module's part sits in the menu bar image, for anchoring
    /// bubbles and working out which part the pointer is over.
    private var partSpans: [(module: MenuBarModule, x: CGFloat, width: CGFloat)] = []
    private var imageWidth: CGFloat = 0

    private static let hoverShowDelay: TimeInterval = 0.4
    private static let hoverHideDelay: TimeInterval = 0.3
    /// Global + local mouse-moved monitors while the item exists.
    private var mouseMonitors: [Any] = []
    private var pointerInsideItem = false
    /// Set when the menu closes with the pointer still on the item: no bubble
    /// until the pointer has left, or closing the menu would summon one.
    private var hoverSuppressedUntilExit = false
    private let hoverContent = HoverPopoverContent()
    private var hoverPopover: NSPopover?
    private var hoverModule: MenuBarModule?
    private var hoverShowWork: DispatchWorkItem?
    private var hoverHideWork: DispatchWorkItem?
    private var hoverSampler: ProcessSampler?

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

    func setCPUAlert(enabled: Bool) {
        Settings.cpuAlertEnabled = enabled
        settingsChanged()
    }

    func setCPUAlertThreshold(_ percent: Double) {
        Settings.cpuAlertThreshold = percent
        settingsChanged()
    }

    func clearCPUAlertIgnored() {
        Settings.cpuAlertIgnored = []
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
        closeHover()
        guard !shown.isEmpty else {
            stopTimer()
            cpuAlert.stop()
            stopHoverMonitoring()
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
            startHoverMonitoring()
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
        if Settings.cpuAlertEnabled {
            wireCPUAlert()
            cpuAlert.start()
        } else {
            cpuAlert.stop()
        }
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
        } else if let hoverModule, hoverPopover != nil {
            hoverModule.updateMenuSection(timeline)
        }
    }

    private var timeline: MenuBarTimeline {
        MenuBarTimeline(interval: Settings.menuBarUpdateInterval, capacity: Self.timelineCapacity)
    }

    private func render(_ shown: [MenuBarModule]) {
        guard let button = statusItem?.button else { return }
        let color = Settings.menuBarColorGraphs
        let style = Settings.menuBarStatsStyle
        let parts = shown.map { $0.part(style: style, color: color) }
        var x: CGFloat = 0
        partSpans = []
        imageWidth = ceil(parts.reduce(0) { $0 + $1.width } + MenuBarDrawing.partGap * CGFloat(max(parts.count - 1, 0)))
        for (module, part) in zip(shown, parts) {
            partSpans.append((module, x, part.width))
            x += part.width + MenuBarDrawing.partGap
        }
        let appearance = button.effectiveAppearance
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(style.rawValue)|\(color)|\(appearance.name.rawValue)|\(scale)|" + parts.map(\.key).joined(separator: "|")
        guard key != renderedKey else { return }
        renderedKey = key
        button.image = MenuBarDrawing.image(parts: parts, color: color, appearance: appearance, scale: scale)
        button.setAccessibilityLabel(shown.map(\.accessibilityDescription).joined(separator: ", "))
    }

    private func updateSections(_ shown: [MenuBarModule]) {
        let timeline = self.timeline
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
        // The click wins: the bubble goes and its section returns to the menu.
        closeHover()
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
        hoverSuppressedUntilExit = pointerInsideItem
        processSampler?.cancel()
        processSampler = nil
        modules.forEach { $0.menuDidClose() }
    }

    @objc private func openDashboard() {
        onOpenDashboard?()
    }

    // MARK: - CPU alert

    private func wireCPUAlert() {
        guard cpuAlert.onChange == nil else { return }
        cpuAlert.onChange = { [weak self] hog in self?.showCPUAlert(hog) }
        alertContent.onClose = { [weak self] in self?.cpuAlert.dismissCurrent() }
        alertContent.onIgnore = { [weak self] in
            guard let self, let hog = self.cpuAlert.current else { return }
            Settings.cpuAlertIgnored = Array(Set(Settings.cpuAlertIgnored + [hog.ignoreKey])).sorted()
            os_log("CPU alert: ignoring %{public}@", log: log, type: .info, hog.ignoreKey)
            self.cpuAlert.forget(hog)
            self.settingsWindow?.reload()
        }
        alertContent.onForceQuit = { [weak self] in
            guard let self, let hog = self.cpuAlert.current else { return }
            self.confirmForceQuit(hog)
        }
    }

    private func showCPUAlert(_ hog: CPUHog?) {
        let alerting = hog != nil
        if alerting { closeHover() }
        if cpu.isAlerting != alerting {
            cpu.isAlerting = alerting
            render(shownModules)
        }
        guard let hog, let button = statusItem?.button else {
            alertPopover?.performClose(nil)
            alertPopover = nil
            return
        }
        alertContent.show(hog)
        guard alertPopover == nil else { return }
        let popover = NSPopover()
        popover.contentViewController = alertContent
        // Stays until closed: a bubble that vanished on the next click in
        // another app would be gone before anyone read it.
        popover.behavior = .applicationDefined
        popover.animates = true
        alertPopover = popover
        popover.show(relativeTo: anchorRect(in: button), of: button, preferredEdge: .minY)
    }

    /// The CPU graph's slice of the button; the whole button if CPU is hidden.
    private func anchorRect(in button: NSStatusBarButton) -> NSRect {
        rect(for: cpu, in: button) ?? button.bounds
    }

    private func rect(for module: MenuBarModule, in button: NSStatusBarButton) -> NSRect? {
        guard let span = partSpans.first(where: { $0.module === module }) else { return nil }
        let imageLeft = (button.bounds.width - imageWidth) / 2
        return NSRect(x: imageLeft + span.x, y: button.bounds.minY, width: span.width, height: button.bounds.height)
    }

    // MARK: - Hover

    /// On macOS 26 status items are drawn by Control Center in another
    /// process, so a tracking area on the button never hears the pointer.
    /// Watching mouse-moved events (global for other apps, local for ours) and
    /// testing them against the item's screen frame does — and costs one
    /// rectangle check per movement.
    private func startHoverMonitoring() {
        guard mouseMonitors.isEmpty else { return }
        hoverContent.onEnter = { [weak self] in self?.hoverHideWork?.cancel() }
        hoverContent.onExit = { [weak self] in self?.pointerLeft() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            self?.mouseMoved()
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.mouseMoved()
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func stopHoverMonitoring() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
        pointerInsideItem = false
    }

    private func mouseMoved() {
        guard let button = statusItem?.button, let window = button.window else { return }
        let point = NSEvent.mouseLocation
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        if frame.contains(point) {
            pointerInsideItem = true
            pointerMoved(toScreenX: point.x - frame.minX)
        } else if pointerInsideItem {
            pointerInsideItem = false
            hoverSuppressedUntilExit = false
            pointerLeft()
        }
    }

    private func pointerMoved(toScreenX buttonX: CGFloat) {
        guard !isMenuOpen, !hoverSuppressedUntilExit, alertPopover == nil, let button = statusItem?.button else { return }
        hoverHideWork?.cancel()
        let x = buttonX - (button.bounds.width - imageWidth) / 2
        // Between two parts: leave whatever is showing (or pending) alone.
        guard let module = partSpans.first(where: { x >= $0.x - MenuBarDrawing.partGap / 2
            && x <= $0.x + $0.width + MenuBarDrawing.partGap / 2 })?.module else { return }
        if hoverPopover != nil {
            if module !== hoverModule { showHover(for: module) }
            return
        }
        guard module !== hoverModule || hoverShowWork == nil else { return }
        hoverShowWork?.cancel()
        hoverModule = module
        let work = DispatchWorkItem { [weak self, weak module] in
            guard let self, let module else { return }
            self.hoverShowWork = nil
            self.showHover(for: module)
        }
        hoverShowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverShowDelay, execute: work)
    }

    private func pointerLeft() {
        hoverShowWork?.cancel()
        hoverShowWork = nil
        guard hoverPopover != nil else {
            hoverModule = nil
            return
        }
        hoverHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hoverContent.isMouseInside else { return }
            self.closeHover()
        }
        hoverHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverHideDelay, execute: work)
    }

    private func showHover(for module: MenuBarModule) {
        guard !isMenuOpen, alertPopover == nil, let button = statusItem?.button,
              let anchor = rect(for: module, in: button) else { return }
        closeHover()
        hoverModule = module
        module.menuWillOpen()
        module.updateMenuSection(timeline)
        hoverContent.embed(module.menuSection)

        let popover = NSPopover()
        popover.contentViewController = hoverContent
        popover.behavior = .applicationDefined
        popover.animates = false
        hoverPopover = popover
        popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)

        guard module.wantsProcessSnapshot else { return }
        module.show(nil)
        let sampler = ProcessSampler()
        hoverSampler = sampler
        sampler.sample { [weak self, weak sampler, weak module] snapshot in
            guard let self, let sampler, self.hoverSampler === sampler, let snapshot, let module else { return }
            self.hoverSampler = nil
            module.show(snapshot)
        }
    }

    /// Closes the bubble and gives its section back to the dropdown.
    private func closeHover() {
        hoverShowWork?.cancel()
        hoverShowWork = nil
        hoverHideWork?.cancel()
        hoverHideWork = nil
        hoverSampler?.cancel()
        hoverSampler = nil
        guard let popover = hoverPopover else {
            hoverModule = nil
            return
        }
        popover.close()
        hoverPopover = nil
        hoverContent.release()
        hoverModule?.menuDidClose()
        hoverModule = nil
        menuContainer.show(sections: shownModules.map(\.menuSection))
    }

    private func confirmForceQuit(_ hog: CPUHog) {
        alertPopover?.performClose(nil)
        alertPopover = nil
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = hog.iconPath.map { NSWorkspace.shared.icon(forFile: $0) }
        alert.messageText = "Force quit “\(hog.name)”?"
        alert.informativeText = String(format: "%.0f%% CPU\n\n", hog.cpu) + (hog.isApp
            ? "\(hog.name) closes immediately, with all of its processes. Unsaved changes will be lost."
            : "This process stops immediately.")
        // Escape cancels; Return does nothing (a destructive button means no default).
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Force Quit").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else {
            // Still busy? Bring the bubble back on the next check.
            cpuAlert.forget(hog)
            return
        }
        let row = ProcessRow(pid: hog.pid, name: hog.name, kind: hog.isApp ? .app : .process, cpu: hog.cpu, memory: 0,
                             processCount: 1, owner: nil, iconPath: hog.iconPath, startTime: hog.startTime)
        switch ProcessSampler.forceQuit(row) {
        case .success:
            os_log("CPU alert: force quit %{public}@", log: log, type: .info, hog.name)
        case .failure(let error):
            NSAlert(error: error).runModal()
        }
        cpuAlert.forget(hog)
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
