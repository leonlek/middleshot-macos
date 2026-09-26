import Cocoa
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "mouse")

final class GestureDetector {
    // Tuning constants — adjust after wearing the gestures for a few days.
    static let mouseFingerCount = 3
    /// Magic Mouse paste (single tap); copy is a single tap with `mouseFingerCount`.
    static let mousePasteFingerCount = 4
    static let trackpadFingerCount = 4
    static let maxTapDuration: TimeInterval = 0.5
    static let interTapGap: TimeInterval = 0.22
    /// Ceiling on the pause between the two taps of a double tap. Must stay above
    /// `interTapGap`, or the trackpad's single-tap timer would resolve the gesture
    /// before a legitimate second tap could land.
    static let maxInterTapGap: TimeInterval = 0.35
    static let driftThreshold: CGFloat = 0.15  // normalized 0..1 space

    private let actionHandler: ActionHandler

    // Magic Mouse 3 fingers: tap → copy, double tap → screenshot. (Middle click
    // is a physical *click*, handled by the CGEventTap.) The copy waits
    // `interTapGap` to be sure no second tap is coming.
    private let mouseDoubleTap: StaticTapRecognizer
    // Magic Mouse 4 fingers: tap → paste, at once — nothing else uses 4 fingers.
    private let mousePasteTap: StaticTapRecognizer

    // Trackpad: single tap → middle click, double tap → screenshot.
    private let trackpadTap: StaticTapRecognizer

    init(actionHandler: ActionHandler) {
        self.actionHandler = actionHandler
        self.mouseDoubleTap = StaticTapRecognizer(
            targetFingerCount: GestureDetector.mouseFingerCount,
            onSingleTap: { [weak actionHandler] in
                guard Settings.mouseCopyPaste else { return }
                os_log("Magic Mouse 3-finger tap → copy", log: log, type: .info)
                actionHandler?.copy()
            },
            onDoubleTap: { [weak actionHandler] in
                os_log("Magic Mouse 3-finger double tap → screenshot", log: log, type: .info)
                actionHandler?.triggerAreaScreenshot()
            }
        )
        self.mousePasteTap = StaticTapRecognizer(
            targetFingerCount: GestureDetector.mousePasteFingerCount,
            onSingleTap: { [weak actionHandler] in
                guard Settings.mouseCopyPaste else { return }
                os_log("Magic Mouse 4-finger tap → paste", log: log, type: .info)
                actionHandler?.paste()
            },
            onDoubleTap: nil
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

    /// A physical click was just turned into a middle click. The fingers that
    /// made it also look like a tap to MT, so without this every 3-finger
    /// middle click would copy as well, and two quick ones would take a
    /// screenshot.
    func clickConsumed() {
        mouseDoubleTap.cancel()
        mousePasteTap.cancel()
    }

    /// Called on the main queue from MagicMouseListener.
    func ingest(frame: MagicMouseListener.Frame) {
        switch frame.device {
        case .magicMouse:
            mouseDoubleTap.ingest(frame: frame)
            mousePasteTap.ingest(frame: frame)
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

        // Expire a stale gap frame-driven rather than on a timer: the recognizer
        // without an `onSingleTap` (Magic Mouse) schedules no timer at all, and MT
        // goes silent once every finger lifts — so the frame that reveals an
        // over-long gap is the first frame of the *next* touch. Falling through to
        // the switch afterwards lets that same frame arm a fresh `firstDown`.
        if phase == .gap {
            let gap = frame.timestamp - downStart
            if gap > GestureDetector.maxInterTapGap {
                trace("gap timeout \(String(format: "%.2f", gap))s", frame: frame)
                reset()
            }
        }

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
        // Nothing to tell a single tap apart from: fire now, no waiting.
        guard onDoubleTap != nil else {
            reset()
            onSingleTap()
            return
        }
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

    /// Drops whatever sequence is in progress; the next arrival of the target
    /// count starts fresh.
    func cancel() {
        reset()
    }

    private func reset() {
        phase = .idle
        cancelPendingSingleTap()
    }

    private func drifted(from current: CGPoint) -> Bool {
        hypot(current.x - anchor.x, current.y - anchor.y) > GestureDetector.driftThreshold
    }
}
