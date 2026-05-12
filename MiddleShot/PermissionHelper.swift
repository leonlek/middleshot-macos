import Cocoa
import ApplicationServices
import IOKit.hid
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

    /// Input Monitoring — required for MultitouchSupport to deliver frames.
    /// `IOHIDRequestAccess` triggers the system prompt on first run; afterwards
    /// it just returns the stored grant.
    @discardableResult
    static func ensureInputMonitoring() -> Bool {
        let status = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if status == kIOHIDAccessTypeGranted {
            os_log("Input Monitoring granted", log: log, type: .info)
            return true
        }
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        os_log("Input Monitoring requested, granted=%{public}@",
               log: log, type: .info, "\(granted)")
        return granted
    }

    /// Screen Recording — `screencapture` is attributed to this process on
    /// recent macOS releases, so we need the grant ourselves.
    @discardableResult
    static func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            os_log("Screen Recording granted", log: log, type: .info)
            return true
        }
        let granted = CGRequestScreenCaptureAccess()
        os_log("Screen Recording requested, granted=%{public}@",
               log: log, type: .info, "\(granted)")
        return granted
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
