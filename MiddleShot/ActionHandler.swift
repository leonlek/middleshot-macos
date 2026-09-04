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
        // Saves the capture to the system screenshot location (Desktop by
        // default). Whether it also presents the floating-thumbnail UI is the
        // `Show Screenshot Thumbnail` setting: on, this matches Cmd+Shift+4;
        // off (the default), the file just lands in the folder silently.
        //
        // Ignore a re-trigger while an interactive capture is still up: stacking
        // a second `screencapture -i` leaves two crosshairs fighting over the
        // same drag.
        if runningCapture != nil {
            os_log("screencapture already in flight — ignoring re-trigger",
                   log: log, type: .info)
            return
        }

        // NEVER pass a file path here. `screencapture -i` refuses to start with
        // `no file specified` unless it is given either a path or `-p`, and the
        // man page's promise that `-u` makes it "ignore files passed to the
        // command line" only holds when the post-capture UI handoff succeeds. If
        // that handoff loses, screencapture quietly falls back to writing the
        // capture to the path itself — no thumbnail. Spawned from this app that
        // fallback is what almost always happened, which is exactly the "capture
        // finished but no thumbnail appeared" bug; the tell was the filename,
        // because our own path was stamped with a Gregorian year while the system
        // UI names its files in the user's locale (e.g. Buddhist-era 2569).
        //
        // `-p` ("use the default settings for capture; the files argument will be
        // ignored") satisfies the argument parser with no path at all, so there is
        // nothing to silently fall back to: both outcomes now save into the folder
        // configured in com.apple.screencapture, named the way the system names
        // them. `-p` alone does NOT present the thumbnail — `-u` is what asks for
        // it — so `-u` is exactly the flag the setting adds or withholds, and
        // `-i -p` stays the floor in both modes.
        var arguments = ["-i", "-p"]
        if Settings.showsScreenshotThumbnail {
            arguments.insert("-u", at: 1)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = arguments
        task.terminationHandler = { [weak self] _ in
            // Fires on an arbitrary thread — clear the in-flight marker on main.
            DispatchQueue.main.async { self?.runningCapture = nil }
        }
        do {
            try task.run()
            runningCapture = task
            os_log("Launched screencapture %{public}@",
                   log: log, type: .info, arguments.joined(separator: " "))
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
