import Cocoa
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var listener: MagicMouseListener?
    private var detector: GestureDetector?
    private var actionHandler: ActionHandler?
    private var mouseTap: MouseClickTap?

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

        self.actionHandler = actionHandler
        self.detector = detector
        self.listener = listener
        self.mouseTap = mouseTap
        self.statusBar = StatusBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        listener?.stop()
        mouseTap?.stop()
    }
}
