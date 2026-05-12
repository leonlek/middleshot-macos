import Cocoa
import ApplicationServices
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "permission")

enum PermissionHelper {
    /// Checks Accessibility and shows the system prompt if not granted.
    @discardableResult
    static func ensureAccessibility(prompt: Bool = true) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        os_log("Accessibility trusted=%{public}@", log: log, type: .info, "\(trusted)")
        return trusted
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
