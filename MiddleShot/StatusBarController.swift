import Cocoa
import ServiceManagement
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "app")

final class StatusBarController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let statusItem: NSStatusItem
    private let launchAtLoginItem: NSMenuItem
    private let thumbnailItem: NSMenuItem
    private let copyToClipboardItem: NSMenuItem
    private let saveLocationMenu = NSMenu()
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
        addItem(to: menu, title: "Restart MiddleShot", symbol: "arrow.clockwise", action: #selector(restart))
        let quit = menu.addItem(withTitle: "Quit MiddleShot",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        quit.image = Self.symbol("xmark.rectangle")

        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == saveLocationMenu {
            rebuildSaveLocationMenu()
            return
        }
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        thumbnailItem.state = Settings.showsScreenshotThumbnail ? .on : .off
        copyToClipboardItem.state = Settings.copiesScreenshotToClipboard ? .on : .off
    }

    /// Only silent captures can reach the clipboard — thumbnail mode never
    /// learns where the file landed — so the copy item greys out rather than
    /// claiming something the app won't do.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item == copyToClipboardItem ? !Settings.showsScreenshotThumbnail : true
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
