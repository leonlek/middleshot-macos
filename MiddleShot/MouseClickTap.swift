import Cocoa
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "mouse")

/// CGEventTap that watches `leftMouseDown` on the Magic Mouse path. When a click
/// arrives while the caller reports `>= 3` fingers resting on the surface, the
/// tap swallows the click and the caller posts a synthesized middle click.
///
/// Once a `leftMouseDown` is swallowed we must also swallow the matching
/// `leftMouseUp` (and any `leftMouseDragged` in between) — otherwise the focused
/// app receives an orphan up/drag and starts spurious selections.
final class MouseClickTap {
    var shouldIntercept: () -> Bool = { false }
    var onIntercept: () -> Void = {}

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    fileprivate var swallowingClick = false

    fileprivate static weak var shared: MouseClickTap?

    init() {
        precondition(MouseClickTap.shared == nil,
                     "MouseClickTap must be a singleton — the CG callback has no userInfo channel")
        MouseClickTap.shared = self
    }

    deinit {
        stop()
    }

    func start() {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                guard let shared = MouseClickTap.shared else {
                    return Unmanaged.passUnretained(event)
                }
                switch type {
                case .leftMouseDown:
                    if shared.shouldIntercept() {
                        shared.swallowingClick = true
                        shared.onIntercept()
                        return nil
                    }
                case .leftMouseDragged:
                    if shared.swallowingClick { return nil }
                case .leftMouseUp:
                    if shared.swallowingClick {
                        shared.swallowingClick = false
                        return nil
                    }
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    if let tap = shared.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                default:
                    break
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            os_log("CGEvent.tapCreate failed — Accessibility permission missing?",
                   log: log, type: .error)
            return
        }
        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        os_log("Event tap installed", log: log, type: .info)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }
}
