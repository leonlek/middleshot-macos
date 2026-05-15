import Foundation
import IOKit
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "device")

/// Watches IOKit for `AppleMultitouchDevice` services entering the registry.
/// Both built-in trackpads and Magic Mouse terminate on this class, so a
/// single matching notification covers all multitouch hardware.
///
/// Complements the staggered wake reload: that handles MT-framework
/// readiness for devices already present at wake; this fires reactively when
/// a device arrives later (Magic Mouse re-pairing via Bluetooth often lands
/// well after the 8s wake window).
final class DeviceWatcher {
    /// Fired on the main queue when a new device matches after `start()`.
    /// Bursts of arrivals are debounced into a single call.
    var onDeviceAppeared: (() -> Void)?

    private var notificationPort: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var debounceWorkItem: DispatchWorkItem?
    private var primed = false

    func start() {
        guard notificationPort == nil else { return }

        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let matching = IOServiceMatching("AppleMultitouchDevice")
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            matching,
            { refcon, _ in
                guard let refcon = refcon else { return }
                Unmanaged<DeviceWatcher>.fromOpaque(refcon)
                    .takeUnretainedValue()
                    .drain()
            },
            selfPtr,
            &iterator
        )

        guard result == KERN_SUCCESS else {
            os_log("IOServiceAddMatchingNotification failed: %{public}d",
                   log: log, type: .error, result)
            IONotificationPortDestroy(port)
            return
        }

        notificationPort = port
        // First drain enumerates devices already present. The listener has
        // already picked these up via MTDeviceCreateList during launch, so we
        // suppress the reload for this pass. The drain itself is required —
        // without it, subsequent matching notifications never fire.
        drain()
        primed = true
        os_log("DeviceWatcher armed", log: log, type: .info)
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if iterator != 0 {
            IOObjectRelease(iterator)
            iterator = 0
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
        primed = false
    }

    private func drain() {
        var sawDevice = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            sawDevice = true
            IOObjectRelease(service)
        }
        guard sawDevice, primed else { return }
        os_log("MT device matched in IOKit", log: log, type: .info)
        scheduleReload()
    }

    private func scheduleReload() {
        // Devices can match in bursts (trackpad + Magic Mouse arriving within
        // a few hundred ms after wake). Coalesce so MT re-enumeration runs
        // once with the steady-state device set.
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onDeviceAppeared?()
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}
