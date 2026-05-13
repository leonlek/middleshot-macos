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
        // We tried `-c` (clipboard) and synthesized Cmd+Shift+Ctrl+4 via
        // CGEvent; neither reliably produces the thumbnail. `-c` and `-u` are
        // mutually exclusive at the screencapture layer (thumbnail needs a
        // saved file to drag/preview), and WindowServer's symbolic-hotkey
        // path silently drops synthesized modifier+key events.
        //
        // The thumbnail itself can be dragged into any text field (Slack,
        // browser, etc.) so the loss of direct clipboard is mostly cosmetic.
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"
        task.arguments = ["-i", "-u"]
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
