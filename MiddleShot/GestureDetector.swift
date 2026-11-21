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
    // Magic Mouse 1 finger: tap → click (left half) / right click (right half).
    private let mouseClickTap = OneFingerTapRecognizer()

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
        self.mouseClickTap.onTap = { [weak actionHandler] side, clickCount in
            actionHandler?.postClick(right: side == .right, clickCount: clickCount)
        }
        self.mouseClickTap.onDragBegin = { [weak actionHandler] in actionHandler?.beginDrag() }
        self.mouseClickTap.onDragEnd = { [weak actionHandler] in actionHandler?.endDrag() }
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
        mouseClickTap.cancel()
    }

    /// A real button press (not one we posted): the finger on the surface is
    /// pressing, not tapping, so tap to click must not add a second click.
    func physicalClick() {
        mouseClickTap.cancel()
    }

    /// The watchdog let go of the drag's button: forget the drag.
    func dragReleased() {
        if mouseClickTap.isDragging { mouseClickTap.cancel() }
    }

    /// Called on the main queue from MagicMouseListener.
    func ingest(frame: MagicMouseListener.Frame) {
        switch frame.device {
        case .magicMouse:
            mouseDoubleTap.ingest(frame: frame)
            mousePasteTap.ingest(frame: frame)
            // A drag in progress always gets its release, even if tap to
            // click was just switched off.
            if Settings.mouseTapToClick || mouseClickTap.isDragging {
                mouseClickTap.ingest(frame: frame)
            }
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

/// Magic Mouse tap to click: one finger, lifted quickly, without the finger,
/// the mouse or any other finger moving. The left half of the surface is a
/// click, the right half a right click; a second tap on the same side within
/// the system double-click interval is a double click.
///
/// The Magic Mouse is held with fingers resting on it, so the conditions are
/// strict on purpose — a regrip or a finger shifting must not click. Every
/// rejection is logged with its reason, for tuning against real use.
///
/// Drives entirely on main; not thread-safe.
final class OneFingerTapRecognizer {
    // Tuning. First cut (0.18 s / 0.03 / 0.15 s) rejected as many taps as it
    // took: 89 "finger moved" and 84 "touch ended just before" against 88
    // clicks in an hour (2026-11-20) — a landing fingertip's contact spreads
    // and its centroid wanders by more than 0.03 on its own.
    static let maxDuration: TimeInterval = 0.25
    static let maxDrift: CGFloat = 0.08            // normalized 0..1
    static let maxCursorTravel: CGFloat = 3        // points
    /// No touch may have ended just before: a finger landing right after
    /// another lifted is a hand settling, not a tap. A tap's own second tap
    /// (double click) is exempt.
    static let quietBefore: TimeInterval = 0.08
    /// Where the surface stops clicking and starts right-clicking. Not the
    /// middle: the index finger taps around 0.2–0.6 (measured 2026-11-20 —
    /// left clicks were landing at 0.55–0.68 and coming out as right clicks),
    /// while a deliberate right click lands past 0.75.
    static let rightClickFrom: CGFloat = 0.7
    /// Taps on the very sides are a thumb or ring finger brushing the edge
    /// while holding the mouse (seen at x = 0.01 and 0.99), not clicks.
    static let edgeMargin: CGFloat = 0.06
    /// Shorter than this is a brush, not a tap (seen: 0.01 s, 0.03 s).
    static let minDuration: TimeInterval = 0.035

    /// Tap, then touch again within this and hold: a drag, like the
    /// trackpad's tap-to-drag. Lifting every finger drops.
    static let dragWindow: TimeInterval = 0.4

    enum Side { case left, right }

    var onTap: ((_ side: Side, _ clickCount: Int) -> Void)?
    var onDragBegin: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private var dragArmed = false
    private(set) var isDragging = false

    private var active = false
    private var start: TimeInterval = 0
    private var anchor: CGPoint = .zero
    private var cursorAtStart: NSPoint = .zero
    private var lastCount = 0
    private var lastRelease: TimeInterval = -.infinity
    private var lastTap: (time: TimeInterval, side: Side, cursor: NSPoint, count: Int)?

    func ingest(frame: MagicMouseListener.Frame) {
        let count = frame.fingerCount
        defer {
            if count == 0 && lastCount > 0 { lastRelease = frame.timestamp }
            lastCount = count
        }

        if !active {
            guard count == 1, lastCount == 0 else { return }
            let isSecondTap = lastTap.map { frame.timestamp - $0.time <= NSEvent.doubleClickInterval } ?? false
            guard isSecondTap || frame.timestamp - lastRelease >= Self.quietBefore else {
                trace(String(format: "rejected: a touch ended just before (%.2fs)", frame.timestamp - lastRelease))
                return
            }
            active = true
            start = frame.timestamp
            anchor = frame.centroid
            cursorAtStart = NSEvent.mouseLocation
            // Only a left tap leads into a drag: a right-button drag is rare
            // and would only surprise.
            dragArmed = lastTap.map { $0.side == .left && frame.timestamp - $0.time <= Self.dragWindow } ?? false
            return
        }

        if isDragging {
            // While dragging the finger may roll and others may brush the
            // surface; only lifting every finger drops.
            if count == 0 { endDrag() }
            return
        }

        if count > 1 {
            cancel()
            return
        }
        if count == 1 {
            let drift = hypot(frame.centroid.x - anchor.x, frame.centroid.y - anchor.y)
            if drift > Self.maxDrift {
                trace(String(format: "rejected: finger moved (%.3f)", drift))
                cancel()
            } else if frame.timestamp - start > Self.maxDuration {
                if dragArmed {
                    isDragging = true
                    os_log("1-finger tap and hold → drag", log: log, type: .info)
                    onDragBegin?()
                } else {
                    cancel()  // a rest, not a tap — too common to log
                }
            }
            return
        }

        // count == 0: released.
        active = false
        let cursor = NSEvent.mouseLocation
        guard hypot(cursor.x - cursorAtStart.x, cursor.y - cursorAtStart.y) <= Self.maxCursorTravel else {
            trace("rejected: the mouse moved")
            return
        }
        let duration = frame.timestamp - start
        guard duration >= Self.minDuration else {
            trace(String(format: "rejected: too brief (%.3fs)", duration))
            return
        }
        guard anchor.x >= Self.edgeMargin, anchor.x <= 1 - Self.edgeMargin else {
            trace(String(format: "rejected: on the edge (x=%.2f)", anchor.x))
            return
        }
        // Left-only mode: the whole surface clicks; a right click stays a
        // physical press on the right side.
        let side: Side = !Settings.mouseTapRightClick || anchor.x < Self.rightClickFrom ? .left : .right
        var clickCount = 1
        if let previous = lastTap, previous.side == side,
           frame.timestamp - previous.time <= NSEvent.doubleClickInterval,
           hypot(cursor.x - previous.cursor.x, cursor.y - previous.cursor.y) <= 5 {
            clickCount = min(previous.count + 1, 3)
        }
        lastTap = (frame.timestamp, side, cursor, clickCount)
        os_log("1-finger tap (%{public}@, x=%.2f, %.2fs) → click ×%d", log: log, type: .info,
               side == .left ? "left" : "right", anchor.x, frame.timestamp - start, clickCount)
        onTap?(side, clickCount)
    }

    /// Drops the touch in progress — a physical click happened, or more
    /// fingers arrived. Also forgets the last tap, so a click never pairs
    /// with a tap into a double click.
    func cancel() {
        if isDragging { endDrag() }
        active = false
        dragArmed = false
        lastTap = nil
    }

    private func endDrag() {
        isDragging = false
        active = false
        dragArmed = false
        lastTap = nil
        os_log("Drag ended", log: log, type: .info)
        onDragEnd?()
    }

    private func trace(_ reason: String) {
        os_log("[tap-to-click] %{public}@", log: log, type: .info, reason)
    }
}
