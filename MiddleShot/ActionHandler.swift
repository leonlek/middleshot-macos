import Cocoa
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "action")

final class ActionHandler {
    func postMiddleClickAtCursor() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            os_log("Failed to create CGEventSource", log: log, type: .error)
            return
        }
        let location = cursorInCGCoords()
        let down = CGEvent(mouseEventSource: source,
                           mouseType: .otherMouseDown,
                           mouseCursorPosition: location,
                           mouseButton: .center)
        let up = CGEvent(mouseEventSource: source,
                         mouseType: .otherMouseUp,
                         mouseCursorPosition: location,
                         mouseButton: .center)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func triggerAreaScreenshot() {
        // Matches Cmd+Shift+4: save the capture to the system screenshot
        // location (Desktop by default) and present the floating-thumbnail UI.
        //
        // The man page claims "-u: files passed to command line will be
        // ignored", but `screencapture -i -u` without a path actually exits
        // with `no file specified`. We pass a tmp path purely to satisfy the
        // argument parser; the actual save destination is whatever the user
        // has configured in com.apple.screencapture (Desktop by default).
        let dummyPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("middleshot-screencapture-dummy.png")
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"
        task.arguments = ["-i", "-u", dummyPath]
        do {
            try task.run()
        } catch {
            os_log("Failed to launch screencapture: %{public}@",
                   log: log, type: .error, "\(error)")
        }
    }

    // NSEvent.mouseLocation is in screen coords with origin bottom-left, while
    // CGEvent expects origin top-left of the *primary* screen.
    private func cursorInCGCoords() -> CGPoint {
        let p = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}
