import Cocoa
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "mouse")

final class GestureDetector {
    // Tuning constants — adjust after wearing the gestures for a few days.
    static let mouseFingerCount = 3
    static let trackpadFingerCount = 4
    static let maxTapDuration: TimeInterval = 0.5
    static let interTapGap: TimeInterval = 0.35
    static let driftThreshold: CGFloat = 0.15  // normalized 0..1 space

    private let actionHandler: ActionHandler

    // Magic Mouse: only the double-tap recognizer (single 3-finger tap means nothing —
    // middle click is triggered by a physical *click* via the CGEventTap).
    private let mouseDoubleTap: StaticTapRecognizer

    // Trackpad: single tap → middle click, double tap → screenshot.
    private let trackpadTap: StaticTapRecognizer

    init(actionHandler: ActionHandler) {
        self.actionHandler = actionHandler
        self.mouseDoubleTap = StaticTapRecognizer(
            targetFingerCount: GestureDetector.mouseFingerCount,
            onSingleTap: nil,
            onDoubleTap: { [weak actionHandler] in
                os_log("Magic Mouse 3-finger double tap → screenshot", log: log, type: .info)
                actionHandler?.triggerAreaScreenshot()
            }
        )
        self.trackpadTap = StaticTapRecognizer(
            targetFingerCount: GestureDetector.trackpadFingerCount,
            onSingleTap: { [weak actionHandler] in
                os_log("Trackpad 4-finger tap → middle click", log: log, type: .info)
                actionHandler?.postMiddleClickAtCursor()
            },
            onDoubleTap: { [weak actionHandler] in
                os_log("Trackpad 4-finger double tap → screenshot", log: log, type: .info)
                actionHandler?.triggerAreaScreenshot()
            }
        )
    }

    /// Called on the main queue from MagicMouseListener.
    func ingest(frame: MagicMouseListener.Frame) {
        switch frame.device {
        case .magicMouse:
            mouseDoubleTap.ingest(frame: frame)
        case .trackpad:
            trackpadTap.ingest(frame: frame)
        }
    }
}

/// Detects either a single tap (N fingers down → 0 within a tight window) or a
/// double tap (two such sequences inside `interTapGap`). When both `onSingleTap`
/// and `onDoubleTap` are set, the recognizer waits `interTapGap` after the first
/// release to disambiguate — single fires only if no second tap arrives.
///
/// Drives entirely on main; not thread-safe.
private final class StaticTapRecognizer {
    let targetFingerCount: Int
    let onSingleTap: (() -> Void)?
    let onDoubleTap: (() -> Void)?

    private enum Phase { case idle, firstDown, gap, secondDown }
    private var phase: Phase = .idle
    private var downStart: TimeInterval = 0
    private var anchor: CGPoint = .zero
    private var lastFingerCount: Int = 0
    private var pendingSingleTap: DispatchWorkItem?

    init(targetFingerCount: Int,
         onSingleTap: (() -> Void)?,
         onDoubleTap: (() -> Void)?) {
        self.targetFingerCount = targetFingerCount
        self.onSingleTap = onSingleTap
        self.onDoubleTap = onDoubleTap
    }

    func ingest(frame: MagicMouseListener.Frame) {
        let count = frame.fingerCount
        defer { lastFingerCount = count }

        // MT reports finger counts gradually (e.g. 0→1→2→3 going down, 3→2→1→0
        // going up). The state machine must tolerate transient intermediate
        // counts and only reset on (a) extra finger beyond target, (b) drift,
        // or (c) timeout. Reaching `target` once "arms" each down phase; the
        // release transition is recognized when count returns to 0.

        switch phase {
        case .idle:
            if count == targetFingerCount && lastFingerCount < targetFingerCount {
                phase = .firstDown
                downStart = frame.timestamp
                anchor = frame.centroid
                trace("→ firstDown", frame: frame)
            }

        case .firstDown:
            if count == 0 {
                let duration = frame.timestamp - downStart
                if duration > GestureDetector.maxTapDuration {
                    trace("firstDown timeout \(String(format: "%.2f", duration))s", frame: frame)
                    reset()
                    return
                }
                phase = .gap
                downStart = frame.timestamp
                trace("→ gap", frame: frame)
                schedulePendingSingleTapIfNeeded()
            } else if count > targetFingerCount {
                trace("firstDown extra finger", frame: frame)
                reset()
            } else if count == targetFingerCount && drifted(from: frame.centroid) {
                trace("firstDown drift", frame: frame)
                reset()
            }
            // else: count in [1, target) — release in progress, keep waiting

        case .gap:
            if count == targetFingerCount {
                cancelPendingSingleTap()
                phase = .secondDown
                downStart = frame.timestamp
                anchor = frame.centroid
                trace("→ secondDown", frame: frame)
            } else if count > targetFingerCount {
                trace("gap extra finger", frame: frame)
                reset()
            }
            // else: count in [0, target) — keep waiting (single-tap timer will fire eventually)

        case .secondDown:
            if count == 0 {
                let duration = frame.timestamp - downStart
                trace("secondDown release \(String(format: "%.2f", duration))s", frame: frame)
                reset()
                if duration <= GestureDetector.maxTapDuration {
                    onDoubleTap?()
                }
            } else if count > targetFingerCount {
                trace("secondDown extra finger", frame: frame)
                reset()
            } else if count == targetFingerCount && drifted(from: frame.centroid) {
                trace("secondDown drift", frame: frame)
                reset()
            }
            // else: count in [1, target) — release in progress, keep waiting
        }
    }

    private func trace(_ event: String, frame: MagicMouseListener.Frame) {
        os_log("[%{public}d-finger] %{public}@ (count=%{public}d)",
               log: log, type: .info,
               targetFingerCount, event, frame.fingerCount)
    }

    private func schedulePendingSingleTapIfNeeded() {
        guard let onSingleTap = onSingleTap else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Only fire if we're still waiting for a second tap.
            if self.phase == .gap {
                self.reset()
                onSingleTap()
            }
        }
        pendingSingleTap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + GestureDetector.interTapGap,
                                      execute: work)
    }

    private func cancelPendingSingleTap() {
        pendingSingleTap?.cancel()
        pendingSingleTap = nil
    }

    private func reset() {
        phase = .idle
        cancelPendingSingleTap()
    }

    private func drifted(from current: CGPoint) -> Bool {
        hypot(current.x - anchor.x, current.y - anchor.y) > GestureDetector.driftThreshold
    }
}
