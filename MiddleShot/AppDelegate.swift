import Cocoa
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var listener: MagicMouseListener?
    private var detector: GestureDetector?
    private var actionHandler: ActionHandler?
    private var mouseTap: MouseClickTap?
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

        // After Mac wakes from sleep, Bluetooth needs ~1s to reconnect the
        // Magic Mouse — re-enumerating before that just rediscovers the
        // trackpad and leaves the mouse broken until next manual reload.
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            os_log("System wake — re-enumerating MT devices in 1.5s",
                   log: log, type: .info)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reload)
        }

        self.actionHandler = actionHandler
        self.detector = detector
        self.listener = listener
        self.mouseTap = mouseTap
        self.statusBar = StatusBarController(onReloadDevices: reload)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        listener?.stop()
        mouseTap?.stop()
    }
}
