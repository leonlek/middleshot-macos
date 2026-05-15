import Cocoa
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var listener: MagicMouseListener?
    private var detector: GestureDetector?
    private var actionHandler: ActionHandler?
    private var mouseTap: MouseClickTap?
    private var deviceWatcher: DeviceWatcher?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        os_log("MiddleShot launching", log: log, type: .info)
        PermissionHelper.ensureAccessibility()
        PermissionHelper.ensureInputMonitoring()
        PermissionHelper.ensureScreenRecording()

        let actionHandler = ActionHandler()
        let detector = GestureDetector(actionHandler: actionHandler)
        let listener = MagicMouseListener()
        listener.onFrame = { frame in
            detector.ingest(frame: frame)
        }
        listener.start()

        let mouseTap = MouseClickTap()
        mouseTap.shouldIntercept = { [weak listener] in
            (listener?.currentMouseFingerCount ?? 0) >= GestureDetector.mouseFingerCount
        }
        mouseTap.onIntercept = {
            actionHandler.postMiddleClickAtCursor()
        }
        mouseTap.start()

        let reload: () -> Void = { [weak listener] in
            listener?.stop()
            listener?.start()
        }

        // Wake recovery runs two paths in parallel:
        //
        //   1. Staggered reloads at 1.5s / 4s / 8s after wake. Covers the
        //      device that survives sleep without re-matching in IOKit
        //      (typically the built-in trackpad — its AppleMultitouchDevice
        //      service stays present, so no notification fires, but the MT
        //      handles can be stale until the framework finishes its own
        //      post-wake settling).
        //
        //   2. DeviceWatcher (IOKit kIOMatchedNotification on
        //      AppleMultitouchDevice). Covers devices that tear down and
        //      re-register, most importantly Magic Mouse — Bluetooth
        //      reconnect time is variable and routinely exceeds the 8s
        //      window above.
        //
        // Both call into the same idempotent reload(); a duplicate during
        // the overlap window is harmless.
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            os_log("System wake — staggered MT re-enumeration",
                   log: log, type: .info)
            for delay in [1.5, 4.0, 8.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: reload)
            }
        }

        let deviceWatcher = DeviceWatcher()
        deviceWatcher.onDeviceAppeared = {
            os_log("DeviceWatcher reload", log: log, type: .info)
            reload()
        }
        deviceWatcher.start()

        self.actionHandler = actionHandler
        self.detector = detector
        self.listener = listener
        self.mouseTap = mouseTap
        self.deviceWatcher = deviceWatcher
        self.statusBar = StatusBarController(onReloadDevices: reload)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        deviceWatcher?.stop()
        listener?.stop()
        mouseTap?.stop()
    }
}
