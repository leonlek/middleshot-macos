import Cocoa
import UniformTypeIdentifiers
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

    private let hud = CursorHUD()

    /// ⌘C as if typed. App key equivalents take synthesized keystrokes — it's
    /// only WindowServer's symbolic hotkeys (⌘⇧⌃4) that ignore them. Key code 8
    /// is the C key's position, which is what a real ⌘C sends under any layout
    /// (Thai included: shortcuts go through the layout's Latin mapping).
    ///
    /// The badge reports what happened rather than what was attempted: if the
    /// clipboard didn't change, there was nothing selected to copy.
    func copy() {
        let before = NSPasteboard.general.changeCount
        postCommandKey(8)
        os_log("⌘C posted", log: log, type: .info)
        guard Settings.showsCopyPasteHUD else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            if NSPasteboard.general.changeCount != before {
                self?.hud.show("Copied", symbol: "doc.on.doc")
            } else {
                self?.hud.show("Nothing to copy", symbol: "doc.on.doc.slash")
            }
        }
    }

    /// ⌘V as if typed (key code 9, the V key's position).
    func paste() {
        postCommandKey(9)
        os_log("⌘V posted", log: log, type: .info)
        if Settings.showsCopyPasteHUD {
            hud.show("Pasted", symbol: "doc.on.clipboard")
        }
    }

    private func postCommandKey(_ keyCode: CGKeyCode) {
        // .privateState: modifiers the person happens to be holding (⇧ on the
        // keyboard) mustn't leak in and turn ⌘V into ⌘⇧V.
        let source = CGEventSource(stateID: .privateState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else {
                os_log("Failed to create key event %d", log: log, type: .error, keyCode)
                return
            }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    func triggerAreaScreenshot() {
        // Saves the capture to the system screenshot location (Desktop by
        // default). The `Show Screenshot Thumbnail` setting picks between two
        // genuinely different invocations — see the comment on each below.
        //
        // Ignore a re-trigger while an interactive capture is still up: stacking
        // a second `screencapture -i` leaves two crosshairs fighting over the
        // same drag.
        if runningCapture != nil {
            os_log("screencapture already in flight — ignoring re-trigger",
                   log: log, type: .info)
            return
        }

        let destination: URL? = Settings.showsScreenshotThumbnail
            ? nil
            : ScreenshotFile.nextURL()

        // Thumbnail mode: NEVER pass a file path. `screencapture -i` refuses to
        // start with `no file specified` unless it is given either a path or
        // `-p`, and the man page's promise that `-u` makes it "ignore files
        // passed to the command line" only holds when the post-capture UI
        // handoff succeeds. If that handoff loses, screencapture quietly falls
        // back to writing the capture to the path itself — no thumbnail. Spawned
        // from this app that fallback is what almost always happened, which is
        // exactly the "capture finished but no thumbnail appeared" bug. `-p`
        // ("use the default settings for capture; the files argument will be
        // ignored") satisfies the argument parser with no path at all, so there
        // is nothing to silently fall back to.
        //
        // Silent mode: a path is precisely what we want, because a path is what
        // suppresses the thumbnail. `-p` cannot do this job — "default settings"
        // includes the Screenshot app's own `show-thumbnail` preference, so
        // `-i -p` hands off to screencaptureui and presents the thumbnail even
        // with no `-u` (measured: the file did not appear on disk until the
        // thumbnail expired ~7s later). Dropping `-p` means dropping the system
        // defaults it applied for us, so ScreenshotFile reads the ones that
        // matter — folder, name prefix, format — back out of the same domain.
        let arguments = destination.map { ["-i", $0.path] } ?? ["-i", "-u", "-p"]

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = arguments
        task.terminationHandler = { [weak self] process in
            // Fires on an arbitrary thread — back to main for the marker and for
            // the pasteboard. A non-zero status is the ordinary "user pressed
            // Escape" path, so it is not logged as an error.
            let captured = process.terminationStatus == 0
            // Escape is status 1; a clean exit with no file afterwards is the
            // tell of a capture macOS refused (Screen Recording), so both the
            // status and whether the file exists are logged.
            os_log("screencapture exited %d, file %{public}@", log: log, type: .info,
                   process.terminationStatus,
                   destination.map { FileManager.default.fileExists(atPath: $0.path) ? "saved" : "missing" } ?? "n/a")
            DispatchQueue.main.async {
                self?.runningCapture = nil
                if captured, let destination,
                   Settings.copiesScreenshotToClipboard {
                    self?.copyToPasteboard(destination)
                }
            }
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

    /// Puts the just-saved capture on the pasteboard as one item carrying both
    /// the image bytes and its file URL, so an editor pastes the picture while
    /// Finder and file-upload fields paste the file.
    ///
    /// Only silent mode can do this: thumbnail mode never learns where
    /// screencapture put the file (that is the whole point of `-p`), and the
    /// thumbnail is itself draggable, which is the same job by other means.
    private func copyToPasteboard(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            os_log("Capture not readable for pasteboard: %{public}@",
                   log: log, type: .error, url.path)
            return
        }
        let type = UTType(filenameExtension: url.pathExtension) ?? .png
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        item.setString(url.absoluteString, forType: .fileURL)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        os_log("Copied capture to clipboard (%{public}@, %d bytes)",
               log: log, type: .info, type.identifier, data.count)
    }

    // NSEvent.mouseLocation is in screen coords with origin bottom-left, while
    // CGEvent expects origin top-left of the *primary* screen.
    private func cursorInCGCoords() -> CGPoint {
        let p = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}
