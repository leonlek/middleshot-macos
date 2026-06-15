import Cocoa
import os
import os.log

// MultitouchSupport.framework is private. The MTTouch layout in the bridging
// header is community-derived — verify on every macOS major release before
// shipping. If contacts ever stop arriving, this is the first suspect.

private let log = OSLog(subsystem: "app.middleshot", category: "mouse")

final class MagicMouseListener {
    enum DeviceKind { case magicMouse, trackpad }

    struct Frame {
        let device: DeviceKind
        let fingerCount: Int
        let centroid: CGPoint  // normalized 0..1, average of contact positions
        let timestamp: TimeInterval
    }

    /// Invoked on the main queue.
    var onFrame: ((Frame) -> Void)?

    /// Most recent Magic Mouse contact count plus the monotonic time it was
    /// captured. The capture time lets readers reject a count that has gone
    /// stale: the MT stream stalls across sleep (the whole reason for the wake
    /// re-enumeration machinery) and freezes this sample at whatever it last
    /// held. If that frozen value is >= 3, the click tap would swallow *every*
    /// left click — including the trackpad's — until a fresh Magic Mouse frame
    /// finally arrives. A real N-finger rest-and-click streams frames the entire
    /// time, so the live sample is always fresh (<~20ms) at click time.
    private struct MouseFingerSample {
        var count: Int
        var captureTime: TimeInterval
    }
    private let mouseFingerLock =
        OSAllocatedUnfairLock(initialState: MouseFingerSample(count: 0, captureTime: 0))

    /// A Magic Mouse contact sample older than this is treated as 0 fingers.
    static let mouseFingerCountMaxAge: TimeInterval = 0.5

    /// Magic Mouse finger count, updated synchronously from the MT callback
    /// thread before the frame is dispatched to main. Read by `MouseClickTap`
    /// when a `leftMouseDown` arrives — going through `onFrame` on main would
    /// race the click event if the main runloop hadn't drained the frame yet.
    /// Returns 0 once the last sample exceeds `mouseFingerCountMaxAge`.
    var currentMouseFingerCount: Int {
        mouseFingerLock.withLock { sample in
            let age = ProcessInfo.processInfo.systemUptime - sample.captureTime
            return age <= MagicMouseListener.mouseFingerCountMaxAge ? sample.count : 0
        }
    }

    private var devices: [MTDeviceRef] = []

    // The MT callback is a `@convention(c)` function pointer with no userInfo,
    // so we route every device through one shared instance.
    fileprivate static weak var shared: MagicMouseListener?

    init() {
        precondition(MagicMouseListener.shared == nil,
                     "MagicMouseListener must be a singleton — the MT callback has no userInfo channel")
        MagicMouseListener.shared = self
    }

    deinit {
        stop()
    }

    func start() {
        guard let listRef = MTDeviceCreateList() else {
            os_log("MTDeviceCreateList returned nil — Input Monitoring permission missing?",
                   log: log, type: .error)
            return
        }
        let list = listRef.takeRetainedValue()
        let count = CFArrayGetCount(list)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            devices.append(device)
            MTRegisterContactFrameCallback(device, mtContactCallback)
            MTDeviceStart(device, 0)
        }
        os_log("Started MT listener with %{public}d device(s)", log: log, type: .info, devices.count)
    }

    func stop() {
        // We deliberately do NOT call MTDeviceStop or
        // MTUnregisterContactFrameCallback here. After system sleep the
        // device handles have stale internal state and either call crashes
        // inside MultitouchSupport's cleanup path (EXC_BAD_ACCESS at 0x8
        // in __CFCheckCFInfoPACSignature — MT tries to schedule cleanup on
        // a runloop that sleep already tore down).
        //
        // The leak is bounded — a few internal bookkeeping records per
        // reload — and process termination releases everything. Worst case
        // for hot reloads is duplicate frame callbacks if MT registers a
        // second callback for the same device on the next start(); the
        // GestureDetector state machine is idempotent on identical frames.
        devices.removeAll()
        // Drop any frozen contact sample so a stale >= 3 count can't keep the
        // click tap intercepting after a reload (e.g. the post-wake re-enumerate).
        mouseFingerLock.withLock { $0 = MouseFingerSample(count: 0, captureTime: 0) }
    }

    fileprivate func handleCallback(device: MTDeviceRef,
                                    touches: UnsafePointer<MTTouch>?,
                                    count: Int,
                                    timestamp: Double) {
        let kind: DeviceKind = MTDeviceIsBuiltIn(device) ? .trackpad : .magicMouse
        var cx: Double = 0
        var cy: Double = 0
        var contacts = 0
        if let touches = touches {
            for i in 0..<count {
                let t = touches[i]
                // States 1..4 mean "in contact or arriving"; 5..7 are lifting away.
                if t.state >= 1 && t.state <= 4 {
                    cx += Double(t.normalized.position.x)
                    cy += Double(t.normalized.position.y)
                    contacts += 1
                }
            }
            if contacts > 0 {
                cx /= Double(contacts)
                cy /= Double(contacts)
            }
        }
        if kind == .magicMouse {
            let snapshot = contacts
            let now = ProcessInfo.processInfo.systemUptime
            mouseFingerLock.withLock { $0 = MouseFingerSample(count: snapshot, captureTime: now) }
        }
        let frame = Frame(
            device: kind,
            fingerCount: contacts,
            centroid: CGPoint(x: cx, y: cy),
            timestamp: timestamp
        )
        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(frame)
        }
    }
}

private func mtContactCallback(device: MTDeviceRef?,
                               touches: UnsafeMutablePointer<MTTouch>?,
                               count: Int32,
                               timestamp: Double,
                               frame: Int32) -> Int32 {
    guard let device = device, let instance = MagicMouseListener.shared else { return 0 }
    instance.handleCallback(device: device,
                            touches: UnsafePointer(touches),
                            count: Int(count),
                            timestamp: timestamp)
    return 0
}
