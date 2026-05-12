import Cocoa
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
        for device in devices {
            MTUnregisterContactFrameCallback(device, mtContactCallback)
            MTDeviceStop(device)
        }
        devices.removeAll()
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
