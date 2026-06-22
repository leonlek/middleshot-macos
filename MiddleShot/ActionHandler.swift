import Cocoa
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "action")

final class ActionHandler {
    // The currently-running interactive `screencapture`, if any. Retained for
    // two reasons: (1) it keeps the Process alive so `terminationHandler` fires
    // and the child is reaped instead of lingering as a zombie, and (2) its
    // non-nil-ness serializes captures — a second trigger while the crosshair is
    // still up would stack a redundant `screencapture -i` and make macOS
    // suppress the floating thumbnail of the first capture (it treats back-to-
    // back captures as one). Accessed on main only (gesture callbacks dispatch
    // to main; the termination handler clears it back on main).
    private var runningCapture: Process?

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
        // Ignore a re-trigger while an interactive capture is still up: stacking
        // a second `screencapture -i` makes WindowServer skip the floating
        // thumbnail of the in-flight one (back-to-back captures are coalesced).
        // This is the likely cause of the occasional missing thumbnail when a
        // double-tap is repeated or borderline.
        if runningCapture != nil {
            os_log("screencapture already in flight — ignoring re-trigger",
                   log: log, type: .info)
            return
        }

        let dummyPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("middleshot-screencapture-dummy.png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-u", dummyPath]
        task.terminationHandler = { [weak self] _ in
            // Fires on an arbitrary thread — clear the in-flight marker on main.
            DispatchQueue.main.async { self?.runningCapture = nil }
        }
        do {
            try task.run()
            runningCapture = task
            os_log("Launched screencapture -i -u", log: log, type: .info)
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
