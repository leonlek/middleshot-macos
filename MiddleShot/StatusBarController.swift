import Cocoa
import ServiceManagement
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "app")

final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let launchAtLoginItem: NSMenuItem
    private let thumbnailItem: NSMenuItem
    private let onReloadDevices: () -> Void

    init(onReloadDevices: @escaping () -> Void) {
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

        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        thumbnailItem.target = self
        thumbnailItem.toolTip = "Off: the capture saves straight to the "
            + "screenshot folder (Desktop by default) with no floating preview."
        menu.addItem(thumbnailItem)
        addItem(to: menu, title: "Reload Devices",
                action: #selector(reloadDevices))
        menu.addItem(.separator())

        addItem(to: menu, title: "Open Accessibility…",
                action: #selector(openAccessibility))
        addItem(to: menu, title: "Open Input Monitoring…",
                action: #selector(openInputMonitoring))
        addItem(to: menu, title: "Open Screen Recording…",
                action: #selector(openScreenRecording))

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MiddleShot",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        thumbnailItem.state = Settings.showsScreenshotThumbnail ? .on : .off
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
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

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                os_log("Launch at Login disabled", log: log, type: .info)
            } else {
                try service.register()
                os_log("Launch at Login enabled", log: log, type: .info)
            }
        } catch {
            os_log("SMAppService toggle failed: %{public}@",
                   log: log, type: .error, "\(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't toggle Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
