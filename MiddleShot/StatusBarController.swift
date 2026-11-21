import Cocoa
import ServiceManagement
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "app")

final class StatusBarController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let statusItem: NSStatusItem
    private let launchAtLoginItem: NSMenuItem
    private let thumbnailItem: NSMenuItem
    private let copyToClipboardItem: NSMenuItem
    private let copyPasteItem = NSMenuItem(title: "Magic Mouse Copy & Paste",
                                           action: #selector(toggleCopyPaste), keyEquivalent: "")
    private let tapToClickItem = NSMenuItem(title: "Tap to Click (Magic Mouse)",
                                            action: #selector(toggleTapToClick), keyEquivalent: "")
    private let tapRightClickItem = NSMenuItem(title: "Left Click Only",
                                               action: #selector(toggleTapRightClick), keyEquivalent: "")
    private let smartZoomItem = NSMenuItem(title: "Turn Off Smart Zoom…",
                                           action: #selector(openMouseSettings), keyEquivalent: "")
    private let copyPasteHUDItem = NSMenuItem(title: "Show “Copied” / “Pasted”",
                                              action: #selector(toggleCopyPasteHUD), keyEquivalent: "")
    private let saveLocationMenu = NSMenu()
    private let updater = Updater()
    private let updateItem = NSMenuItem(title: "Update", action: #selector(installUpdate), keyEquivalent: "")
    private let onReloadDevices: () -> Void
    /// Created on first use and kept for the life of the app, so closing the
    /// window keeps the last scan and snapshot around for next time.
    private var dashboard: DashboardWindowController?

    init(menuBarStats: MenuBarStatsController, onReloadDevices: @escaping () -> Void) {
        self.onReloadDevices = onReloadDevices
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        launchAtLoginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        thumbnailItem = NSMenuItem(
            title: "Show Screenshot Thumbnail",
            action: #selector(toggleScreenshotThumbnail),
            keyEquivalent: ""
        )
        copyToClipboardItem = NSMenuItem(
            title: "Copy Screenshot to Clipboard",
            action: #selector(toggleCopyToClipboard),
            keyEquivalent: ""
        )
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "cursorarrow.click.2",
                                accessibilityDescription: "MiddleShot")
            image?.isTemplate = true
            button.image = image
            os_log("Status item created (image=%{public}@)",
                   log: log, type: .info,
                   image == nil ? "nil" : "ok")
        } else {
            os_log("Status item has no button — menu bar may be unavailable",
                   log: log, type: .error)
        }

        let menu = NSMenu()
        menu.delegate = self

        let header = NSMenuItem(title: Self.versionTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        updateItem.target = self
        updateItem.image = Self.symbol("arrow.down.circle.fill")
        updateItem.isHidden = true
        menu.addItem(updateItem)
        menu.addItem(.separator())

        addItem(to: menu, title: "Open Dashboard…", symbol: "gauge.with.dots.needle.33percent",
                action: #selector(openDashboard))
        let statsItem = NSMenuItem(title: "Menu Bar Stats", action: nil, keyEquivalent: "")
        statsItem.image = Self.symbol("chart.bar.xaxis")
        statsItem.submenu = menuBarStats.makeSettingsMenu()
        menu.addItem(statsItem)
        menu.addItem(.separator())

        launchAtLoginItem.target = self
        launchAtLoginItem.image = Self.symbol("power")
        menu.addItem(launchAtLoginItem)
        thumbnailItem.target = self
        thumbnailItem.image = Self.symbol("photo.on.rectangle")
        thumbnailItem.toolTip = "Off: the capture saves straight to the "
            + "screenshot folder (Desktop by default) with no floating preview."
        menu.addItem(thumbnailItem)
        copyToClipboardItem.target = self
        copyToClipboardItem.image = Self.symbol("doc.on.clipboard")
        copyToClipboardItem.toolTip = "Also put the capture on the clipboard, "
            + "ready to paste. Unavailable while the thumbnail is shown — drag "
            + "the thumbnail instead."
        menu.addItem(copyToClipboardItem)
        let saveLocationItem = NSMenuItem(title: "Save Screenshots To",
                                          action: nil, keyEquivalent: "")
        saveLocationItem.image = Self.symbol("folder")
        saveLocationMenu.delegate = self
        saveLocationItem.submenu = saveLocationMenu
        menu.addItem(saveLocationItem)
        copyPasteItem.target = self
        copyPasteItem.image = Self.symbol("doc.on.doc")
        copyPasteItem.toolTip = "Magic Mouse: tap with 3 fingers to copy, tap with 4 fingers to paste."
        menu.addItem(copyPasteItem)
        copyPasteHUDItem.target = self
        copyPasteHUDItem.image = Self.symbol("text.bubble")
        copyPasteHUDItem.toolTip = "A small badge by the pointer confirms each copy and paste."
        menu.addItem(copyPasteHUDItem)
        tapToClickItem.target = self
        tapToClickItem.image = Self.symbol("hand.tap")
        tapToClickItem.toolTip = "Magic Mouse: tap with one finger to click — left half clicks, right half right-clicks, "
            + "two taps double-click."
        menu.addItem(tapToClickItem)
        tapRightClickItem.target = self
        tapRightClickItem.indentationLevel = 1
        tapRightClickItem.toolTip = "Every tap is a left click, wherever it lands. "
            + "Right-click with a physical press as usual."
        menu.addItem(tapRightClickItem)
        smartZoomItem.target = self
        smartZoomItem.image = Self.symbol("plus.magnifyingglass")
        smartZoomItem.toolTip = "Smart Zoom also answers a one-finger double tap — turn it off in Mouse settings "
            + "so double-tapping only double-clicks."
        menu.addItem(smartZoomItem)
        addItem(to: menu, title: "Reload Devices", symbol: "magicmouse",
                action: #selector(reloadDevices))
        menu.addItem(.separator())

        addItem(to: menu, title: "Open Accessibility…", symbol: "accessibility",
                action: #selector(openAccessibility))
        addItem(to: menu, title: "Open Input Monitoring…", symbol: "keyboard",
                action: #selector(openInputMonitoring))
        addItem(to: menu, title: "Open Screen Recording…", symbol: "rectangle.dashed.badge.record",
                action: #selector(openScreenRecording))

        menu.addItem(.separator())
        addItem(to: menu, title: "Check for Updates…", symbol: "arrow.triangle.2.circlepath",
                action: #selector(checkForUpdates))
        addItem(to: menu, title: "Restart MiddleShot", symbol: "arrow.clockwise", action: #selector(restart))
        let quit = menu.addItem(withTitle: "Quit MiddleShot",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        quit.image = Self.symbol("xmark.rectangle")

        statusItem.menu = menu

        updater.onChange = { [weak self] in self?.updateAvailabilityChanged() }
        updater.start()
    }

    // MARK: - Updates

    private func updateAvailabilityChanged() {
        if let release = updater.available {
            updateItem.title = "Update to \(release.version) (build \(release.build))…"
            updateItem.isHidden = false
        } else {
            updateItem.isHidden = true
        }
        statusItem.button?.image = Self.statusImage(badged: updater.available != nil)
    }

    /// The menu bar icon, with a dot while an update waits. Drawn at display
    /// time so the glyph takes the menu bar's own ink (light or dark).
    private static func statusImage(badged: Bool) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "MiddleShot") else {
            return nil
        }
        symbol.isTemplate = true
        guard badged else { return symbol }
        let size = symbol.size
        let image = NSImage(size: size, flipped: false) { rect in
            let glyph = NSImage(size: size, flipped: false) { inner in
                symbol.draw(in: inner)
                NSColor.labelColor.set()
                inner.fill(using: .sourceAtop)
                return true
            }
            glyph.draw(in: rect)
            let dot = NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.accessibilityDescription = "MiddleShot — update available"
        return image
    }

    @objc private func checkForUpdates() {
        let alert = NSAlert()
        if let release = updater.check() {
            alert.messageText = "MiddleShot \(release.version) (build \(release.build)) is available"
            alert.informativeText = "This Mac has build \(Updater.currentBuild). Installing quits MiddleShot for a moment "
                + "and opens the new version; permissions carry over."
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { install(release) }
        } else {
            alert.messageText = "MiddleShot is up to date"
            alert.informativeText = "Build \(Updater.currentBuild) is the newest in Dropbox › Apps."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func installUpdate() {
        guard let release = updater.check() ?? updater.available else { return }
        install(release)
    }

    private func install(_ release: Updater.Release) {
        updateItem.title = "Installing build \(release.build)…"
        updateItem.isEnabled = false
        updater.install(release) { [weak self] failure in
            guard let self, let failure else { return }
            self.updateItem.isEnabled = true
            self.updateAvailabilityChanged()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't update MiddleShot"
            alert.informativeText = failure.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == saveLocationMenu {
            rebuildSaveLocationMenu()
            return
        }
        updater.check()
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        thumbnailItem.state = Settings.showsScreenshotThumbnail ? .on : .off
        copyToClipboardItem.state = Settings.copiesScreenshotToClipboard ? .on : .off
        copyPasteItem.state = Settings.mouseCopyPaste ? .on : .off
        tapToClickItem.state = Settings.mouseTapToClick ? .on : .off
        tapRightClickItem.state = Settings.mouseTapRightClick ? .off : .on
        tapRightClickItem.isHidden = !Settings.mouseTapToClick
        smartZoomItem.isHidden = !(Settings.mouseTapToClick && Self.isSmartZoomOn)
        copyPasteHUDItem.state = Settings.showsCopyPasteHUD ? .on : .off
    }

    /// Only silent captures can reach the clipboard — thumbnail mode never
    /// learns where the file landed — so the copy item greys out rather than
    /// claiming something the app won't do.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item == copyToClipboardItem { return !Settings.showsScreenshotThumbnail }
        if item == copyPasteHUDItem { return Settings.mouseCopyPaste }
        return true
    }

    private func addItem(to menu: NSMenu, title: String, symbol: String? = nil, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = symbol.flatMap(Self.symbol)
        menu.addItem(item)
    }

    /// A menu icon from an SF Symbol. A name this macOS doesn't have just
    /// leaves the item without one.
    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// "MiddleShot 0.2.0 (18 · efde0e6)" — build number and commit are stamped
    /// by build.sh, so this identifies exactly which binary a machine is on.
    private static var versionTitle: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let commit = info?["MSGitCommit"] as? String ?? "?"
        return "MiddleShot \(short) (\(build) · \(commit))"
    }

    @objc private func openAccessibility()    { PermissionHelper.openAccessibilitySettings() }
    @objc private func openInputMonitoring()  { PermissionHelper.openInputMonitoringSettings() }
    @objc private func openScreenRecording()  { PermissionHelper.openScreenRecordingSettings() }

    @objc private func openDashboard() {
        showDashboard()
    }

    func showDashboard() {
        loadedDashboard().show()
    }

    func showSafeToClean() {
        loadedDashboard().showSafeToClean()
    }

    /// Nil until the Dashboard has been opened — and so until anything has been
    /// scanned; asking must not build a window just to find no results.
    var cleanupSummary: (size: Int64, finishedAt: Date)? {
        dashboard?.cleanupSummary
    }

    private func loadedDashboard() -> DashboardWindowController {
        if let dashboard { return dashboard }
        let created = DashboardWindowController()
        dashboard = created
        return created
    }

    /// Quits and opens this same bundle again — picks up a fresh build, or
    /// clears whatever state a long run got into.
    ///
    /// The relaunch is handed to a small shell that waits for this process to
    /// exit first: two copies running at once would both install event taps
    /// and both answer every gesture. The shell outlives us (reparented to
    /// launchd), and `open` starts the bundle the normal way, so permissions
    /// and Launch at Login see the same app.
    @objc private func restart() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath]
        do {
            try task.run()
            os_log("Restarting from %{public}@", log: log, type: .info, Bundle.main.bundlePath)
            NSApp.terminate(nil)
        } catch {
            os_log("Restart failed to launch helper: %{public}@", log: log, type: .error, "\(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't restart MiddleShot"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func reloadDevices() {
        os_log("Reload Devices requested", log: log, type: .info)
        onReloadDevices()
    }

    @objc private func toggleScreenshotThumbnail() {
        let enabled = !Settings.showsScreenshotThumbnail
        Settings.showsScreenshotThumbnail = enabled
        thumbnailItem.state = enabled ? .on : .off
        os_log("Screenshot thumbnail %{public}@",
               log: log, type: .info, enabled ? "enabled" : "disabled")
    }

    @objc private func toggleCopyToClipboard() {
        let enabled = !Settings.copiesScreenshotToClipboard
        Settings.copiesScreenshotToClipboard = enabled
        copyToClipboardItem.state = enabled ? .on : .off
        os_log("Clipboard copy %{public}@",
               log: log, type: .info, enabled ? "enabled" : "disabled")
    }

    // MARK: - Save location

    /// MiddleShot's own folder, never the system's: ⌘⇧4 keeps saving where it
    /// did. Rebuilt on every open because the "Same as ⌘⇧4" row names the
    /// system folder, which ⌘⇧5 → Options can change at any time.
    private func rebuildSaveLocationMenu() {
        saveLocationMenu.removeAllItems()
        let fileManager = FileManager.default
        let chosen = Settings.screenshotFolder?.standardizedFileURL

        let system = ScreenshotFile.systemDirectory
        let systemItem = folderItem(
            title: "Same as ⌘⇧4 (\(fileManager.displayName(atPath: system.path)))",
            folder: system, represents: nil)
        systemItem.state = chosen == nil ? .on : .off
        saveLocationMenu.addItem(systemItem)
        saveLocationMenu.addItem(.separator())

        var folders = [ScreenshotFile.desktop]
        for directory: FileManager.SearchPathDirectory in [.documentDirectory, .downloadsDirectory] {
            if let url = fileManager.urls(for: directory, in: .userDomainMask).first {
                folders.append(url)
            }
        }
        if let chosen, !folders.contains(where: { $0.standardizedFileURL == chosen }) {
            folders.append(chosen)
        }
        for folder in folders {
            let item = folderItem(title: fileManager.displayName(atPath: folder.path),
                                  folder: folder, represents: folder)
            item.state = folder.standardizedFileURL == chosen ? .on : .off
            saveLocationMenu.addItem(item)
        }

        if Settings.showsScreenshotThumbnail {
            let note = NSMenuItem(title: "With the thumbnail on, captures go where ⌘⇧4 saves",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            saveLocationMenu.addItem(note)
        }
        saveLocationMenu.addItem(.separator())
        addItem(to: saveLocationMenu, title: "Other Location…",
                action: #selector(chooseOtherSaveLocation))
        addItem(to: saveLocationMenu, title: "Show in Finder",
                action: #selector(showSaveLocation))
    }

    /// `represents` is what choosing the row stores: a folder, or nil for
    /// "follow the system".
    private func folderItem(title: String, folder: URL, represents: URL?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(chooseSaveLocation(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = represents
        item.toolTip = (folder.path as NSString).abbreviatingWithTildeInPath
        let icon = NSWorkspace.shared.icon(forFile: folder.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }

    @objc private func chooseSaveLocation(_ sender: NSMenuItem) {
        setSaveLocation(sender.representedObject as? URL)
    }

    @objc private func chooseOtherSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where screenshots are saved."
        panel.directoryURL = ScreenshotFile.directory
        // An accessory app's panel opens behind the frontmost window otherwise.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        setSaveLocation(folder)
    }

    @objc private func showSaveLocation() {
        let folder = Settings.showsScreenshotThumbnail
            ? ScreenshotFile.systemDirectory : ScreenshotFile.directory
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func setSaveLocation(_ folder: URL?) {
        Settings.screenshotFolder = folder
        os_log("Screenshot folder set to %{public}@",
               log: log, type: .info, folder?.path ?? "system location")
    }

    @objc private func toggleCopyPaste() {
        Settings.mouseCopyPaste.toggle()
        os_log("Magic Mouse copy & paste %{public}@", log: log, type: .info,
               Settings.mouseCopyPaste ? "enabled" : "disabled")
    }

    @objc private func toggleTapRightClick() {
        Settings.mouseTapRightClick.toggle()
        os_log("Tap left click only %{public}@", log: log, type: .info, Settings.mouseTapRightClick ? "off" : "on")
    }

    @objc private func toggleTapToClick() {
        Settings.mouseTapToClick.toggle()
        os_log("Tap to click %{public}@", log: log, type: .info, Settings.mouseTapToClick ? "enabled" : "disabled")
        guard Settings.mouseTapToClick, Self.isSmartZoomOn else { return }
        let alert = NSAlert()
        alert.messageText = "Turn off Smart Zoom too?"
        alert.informativeText = "A one-finger double tap is also Smart Zoom, so double-tapping to double-click would "
            + "zoom the page as well.\n\nmacOS only applies this setting from System Settings › Mouse — "
            + "switch Smart Zoom off there."
        alert.addButton(withTitle: "Open Mouse Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openMouseSettings()
        }
    }

    /// Smart Zoom is the Magic Mouse's one-finger double tap. Read, never
    /// written: a `defaults write` to the driver's domain isn't picked up until
    /// the next login, and the setting belongs to System Settings.
    private static var isSmartZoomOn: Bool {
        let domains = ["com.apple.driver.AppleBluetoothMultitouch.mouse", "com.apple.AppleMultitouchMouse"]
        return domains.contains { UserDefaults(suiteName: $0)?.integer(forKey: "MouseOneFingerDoubleTapGesture") == 1 }
    }

    @objc private func openMouseSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Mouse-Settings.extension")!)
    }

    @objc private func toggleCopyPasteHUD() {
        Settings.showsCopyPasteHUD.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        let status = service.status
        os_log("Launch at Login toggle from status %{public}@ (bundle %{public}@)", log: log, type: .info,
               "\(status.rawValue)", Bundle.main.bundlePath)
        do {
            if status == .enabled {
                try service.unregister()
                os_log("Launch at Login disabled", log: log, type: .info)
            } else {
                try service.register()
                os_log("Launch at Login enabled", log: log, type: .info)
            }
        } catch {
            os_log("SMAppService toggle failed: %{public}@",
                   log: log, type: .error, "\(error)")
            // Seen as "Invalid argument" (code 22) when the login item record
            // macOS keeps no longer matches this copy of the app — a rebuilt or
            // moved bundle. The switch in Login Items still works then.
            let alert = NSAlert()
            alert.messageText = "Couldn't toggle Launch at Login"
            alert.informativeText = error.localizedDescription
                + "\n\nYou can turn MiddleShot on or off under System Settings › General › Login Items."
            alert.addButton(withTitle: "Open Login Items")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }
}
