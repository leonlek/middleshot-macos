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

        // The man page claims `-u` ignores the file argument, but that only holds
        // in *non-interactive* mode. In interactive mode (`-i -u file`) each launch
        // races two outcomes: either WindowServer's screenshot UI wins → floating
        // thumbnail + save to the default location (our path ignored), OR the UI
        // handoff loses → screencapture writes the capture to `file` itself with no
        // thumbnail. We used to pass a throwaway tmp path, so every time the second
        // outcome won the screenshot was silently written to tmp and overwritten on
        // the next trigger — "capture finished but nothing showed, had to redo it".
        // Passing a real destination on the screenshot folder makes both outcomes
        // land a usable file there; only the thumbnail is still race-dependent.
        let destinationPath = screenshotDestinationPath()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-u", destinationPath]
        task.terminationHandler = { [weak self] _ in
            // Fires on an arbitrary thread — clear the in-flight marker on main.
            DispatchQueue.main.async { self?.runningCapture = nil }
        }
        do {
            try task.run()
            runningCapture = task
            os_log("Launched screencapture -i -u %{public}@", log: log, type: .info, destinationPath)
        } catch {
            os_log("Failed to launch screencapture: %{public}@",
                   log: log, type: .error, "\(error)")
        }
    }

    // Builds a fresh, native-styled save path in the user's configured screenshot
    // folder, e.g. "~/Desktop/Screenshot 2026-07-21 at 13.49.00.png". Honors the
    // `location` and `name` keys of com.apple.screencapture (what the Screenshot app
    // sets), falling back to ~/Desktop and "Screenshot" like the system default. A
    // uniquifying suffix avoids clobbering an existing file within the same second.
    private func screenshotDestinationPath() -> String {
        let capturePrefs = UserDefaults(suiteName: "com.apple.screencapture")
        let folder = (capturePrefs?.string(forKey: "location") as NSString?)?
            .expandingTildeInPath
            ?? (NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first
                ?? (NSHomeDirectory() as NSString).appendingPathComponent("Desktop"))
        let prefix = capturePrefs?.string(forKey: "name") ?? "Screenshot"

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())

        let fm = FileManager.default
        var candidate = (folder as NSString)
            .appendingPathComponent("\(prefix) \(stamp).png")
        var counter = 1
        while fm.fileExists(atPath: candidate) {
            candidate = (folder as NSString)
                .appendingPathComponent("\(prefix) \(stamp) (\(counter)).png")
            counter += 1
        }
        return candidate
    }

    // NSEvent.mouseLocation is in screen coords with origin bottom-left, while
    // CGEvent expects origin top-left of the *primary* screen.
    private func cursorInCGCoords() -> CGPoint {
        let p = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}
