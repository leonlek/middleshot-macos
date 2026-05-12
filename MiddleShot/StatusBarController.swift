import Cocoa
import ServiceManagement
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "app")

final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let launchAtLoginItem: NSMenuItem
    private let onReloadDevices: () -> Void

    init(onReloadDevices: @escaping () -> Void) {
        self.onReloadDevices = onReloadDevices
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        launchAtLoginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "cursorarrow.click.2",
                                accessibilityDescription: "MiddleShot")
            image?.isTemplate = true
            button.image = image
            // Text label makes it findable when the menu bar is full and
            // items get clipped behind the notch on MacBook Pro / Air.
            button.title = "MS"
            button.imagePosition = .imageLeading
            os_log("Status item created (image=%{public}@, title=%{public}@)",
                   log: log, type: .info,
                   image == nil ? "nil" : "ok", button.title)
        } else {
            os_log("Status item has no button — menu bar may be unavailable",
                   log: log, type: .error)
        }

        let menu = NSMenu()
        menu.delegate = self

        let header = NSMenuItem(title: "MiddleShot", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
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
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func openAccessibility()    { PermissionHelper.openAccessibilitySettings() }
    @objc private func openInputMonitoring()  { PermissionHelper.openInputMonitoringSettings() }
    @objc private func openScreenRecording()  { PermissionHelper.openScreenRecordingSettings() }

    @objc private func reloadDevices() {
        os_log("Reload Devices requested", log: log, type: .info)
        onReloadDevices()
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
