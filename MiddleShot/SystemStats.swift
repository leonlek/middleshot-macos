import Foundation
import IOKit
import SystemConfiguration
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "dashboard")

/// Whole-machine readings: cheap enough to take every second, which is what
/// the menu bar stats do. Each call is a single syscall or two — nothing here
/// walks the process list.
enum SystemStats {
    struct CPUTicks {
        let user: UInt64
        let system: UInt64
        let total: UInt64

        /// Fractions of total capacity between two readings.
        func load(since earlier: CPUTicks) -> (user: Double, system: Double) {
            let total = max(Double(self.total &- earlier.total), 1)
            return (Double(user &- earlier.user) / total, Double(system &- earlier.system) / total)
        }
    }

    struct Memory {
        let app: UInt64
        let wired: UInt64
        let compressed: UInt64
        let total: UInt64
        let swapUsed: UInt64
        let pressure: MemoryPressure

        /// "Memory Used" the way Activity Monitor adds it up.
        var used: UInt64 { app + wired + compressed }
    }

    struct NetworkCounters {
        let received: UInt64
        let sent: UInt64
    }

    struct DiskSpace {
        let name: String
        let total: Int64
        let available: Int64

        var used: Int64 { max(total - available, 0) }
        var freeFraction: Double { total > 0 ? Double(available) / Double(total) : 1 }
    }

    struct DiskIOCounters {
        let read: UInt64
        let written: UInt64
    }

    static func cpuTicks() -> CPUTicks {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            os_log("host_statistics failed: %d", log: log, type: .error, result)
            return CPUTicks(user: 0, system: 0, total: 0)
        }
        let user = UInt64(load.cpu_ticks.0), system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
        return CPUTicks(user: user + nice, system: system, total: user + system + idle + nice)
    }

    static func memory() -> Memory {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0
        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let anonymous = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            app = (anonymous > purgeable ? anonymous - purgeable : 0) * page
            wired = UInt64(stats.wire_count) * page
            compressed = UInt64(stats.compressor_page_count) * page
        } else {
            os_log("host_statistics64 failed: %d", log: log, type: .error, result)
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) != 0 {
            swap = xsw_usage()
        }

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)
        let pressure: MemoryPressure
        switch level {
        case 4: pressure = .critical
        case 2: pressure = .warning
        default: pressure = .normal
        }
        return Memory(app: app, wired: wired, compressed: compressed,
                      total: ProcessInfo.processInfo.physicalMemory, swapUsed: swap.xsu_used, pressure: pressure)
    }

    /// Bytes through physical Wi‑Fi and Ethernet ports (`en*`) since startup.
    /// VPN tunnels (`utun*`) are left out on purpose: their traffic already
    /// passes through a physical port, so counting both would double it.
    ///
    /// Read from `NET_RT_IFLIST2` for the 64-bit counters — the `if_data` that
    /// `getifaddrs` returns is 32-bit and wraps every 4 GB.
    static func networkCounters() -> NetworkCounters {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else {
            return NetworkCounters(received: 0, sent: 0)
        }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else {
            return NetworkCounters(received: 0, sent: 0)
        }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        let running = Int32(IFF_UP | IFF_RUNNING)
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                defer { offset += Int(header.ifm_msglen) }
                guard Int32(header.ifm_type) == RTM_IFINFO2 else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard message.ifm_flags & running == running else { continue }
                // The interface name trails the header inside a sockaddr_dl:
                // sdl_nlen is at +5 and the name bytes start at +8.
                let address = offset + MemoryLayout<if_msghdr2>.size
                guard address + 8 <= length else { continue }
                let nameLength = Int(raw[address + 5])
                guard address + 8 + nameLength <= length,
                      raw[address + 8] == UInt8(ascii: "e"), nameLength > 1, raw[address + 9] == UInt8(ascii: "n") else {
                    continue
                }
                received += message.ifm_data.ifi_ibytes
                sent += message.ifm_data.ifi_obytes
            }
        }
        return NetworkCounters(received: received, sent: sent)
    }

    /// The interface macOS routes internet traffic through, as "Wi‑Fi · en0 ·
    /// 192.168.1.24". Nil when offline.
    static func primaryInterfaceDescription() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "app.middleshot" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let bsdName = global["PrimaryInterface"] as? String else {
            return nil
        }
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let displayName = interfaces
            .first { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }
            .flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? }
        return [displayName, bsdName, ipv4Address(of: bsdName)].compactMap { $0 }.joined(separator: " · ")
    }

    private static func ipv4Address(of interface: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name) == interface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(cString: host)
        }
        return nil
    }

    // MARK: - Disk

    /// The startup volume. "Available" counts space macOS can purge on demand,
    /// the way Finder does. A fresh URL each call — resource values are cached
    /// per URL object and free space would otherwise never move.
    static func startupDisk() -> DiskSpace? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeLocalizedNameKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0 else {
            return nil
        }
        return DiskSpace(name: values.volumeLocalizedName ?? "Startup Disk", total: Int64(total),
                         available: values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// Mounted local drives that aren't built in — USB and Thunderbolt disks,
    /// SD cards. Disk images and network shares are not "drives" here.
    static func externalDisks() -> [DiskSpace] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
                                      .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                            options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsInternal == false, values.volumeIsLocal == true, values.volumeIsBrowsable == true,
                  let total = values.volumeTotalCapacity, total > 0,
                  !url.path.hasPrefix("/Library/Developer/CoreSimulator") else {
                return nil
            }
            return DiskSpace(name: values.volumeLocalizedName ?? url.lastPathComponent, total: Int64(total),
                             available: Int64(values.volumeAvailableCapacity ?? 0))
        }
    }

    /// Bytes read and written by physical disks since startup, summed over
    /// every `IOBlockStorageDriver`. Disk images are skipped: their I/O lands
    /// on a physical disk too and would be counted twice.
    static func diskIOCounters() -> DiskIOCounters {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else {
            return DiskIOCounters(read: 0, written: 0)
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var written: UInt64 = 0
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            var device: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS {
                let characteristics = IORegistryEntryCreateCFProperty(device, "Protocol Characteristics" as CFString,
                                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
                IOObjectRelease(device)
                if characteristics?["Physical Interconnect"] as? String == "Virtual Interface" { continue }
            }
            guard let statistics = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString,
                                                                   kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else {
                continue
            }
            read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return DiskIOCounters(read: read, written: written)
    }
}
