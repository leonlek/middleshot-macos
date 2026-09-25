import Foundation
import IOKit
import os.log

private let log = OSLog(subsystem: "app.middleshot", category: "sensors")

/// Reads the System Management Controller — temperatures and fans — through
/// the `AppleSMC` user client. Needs no privileges on Apple Silicon or Intel.
///
/// Key names are undocumented and differ per chip (M1 Pro has ~30 `Tp`
/// sensors, M2+ adds `Te`, Intel uses `TC0P`…), so `Sensors` discovers which
/// ones exist by listing every key once instead of shipping per-model tables.
///
/// Every call is a kernel round trip of ~0.7 ms, so an instance is only used
/// from `Sensors`' own serial queue, never on main.
final class SMC {
    struct Key {
        let name: String
        fileprivate let code: UInt32
        fileprivate let size: UInt32
        fileprivate let type: UInt32
    }

    /// `SMCKeyData_t` from AppleSMC. The layout must match the kernel's byte
    /// for byte — note the padding after `dataAttributes` (the C `keyInfo`
    /// struct is 12 bytes), without which every read comes back empty.
    private struct Message {
        var key: UInt32 = 0
        var version = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt16(0))
        var limits = (UInt16(0), UInt16(0), UInt32(0), UInt32(0), UInt32(0))
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        var padding = (UInt8(0), UInt8(0), UInt8(0))
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var index: UInt32 = 0
        var bytes = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
    }

    private enum Command: UInt8 {
        case read = 5
        case keyAtIndex = 8
        case keyInfo = 9
    }

    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let status = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard status == kIOReturnSuccess else {
            os_log("AppleSMC open failed: %d", log: log, type: .error, status)
            return nil
        }
    }

    deinit {
        IOServiceClose(connection)
    }

    /// Every key name the SMC knows (~2,000 on an M1 Pro, ~0.7 s to list).
    func allKeyNames() -> [String] {
        guard let countKey = key("#KEY"), let count = rawBytes(countKey).map({ bytes in
            bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }) else { return [] }
        return (0..<count).compactMap { index in
            var input = Message()
            input.command = Command.keyAtIndex.rawValue
            input.index = index
            guard let output = call(&input) else { return nil }
            return Self.name(of: output.key)
        }
    }

    func key(_ name: String) -> Key? {
        var input = Message()
        input.key = Self.code(name)
        input.command = Command.keyInfo.rawValue
        guard let output = call(&input), output.dataSize > 0 else { return nil }
        return Key(name: name, code: input.key, size: output.dataSize, type: output.dataType)
    }

    /// The key's value as a number, for the encodings sensors and fans use.
    func value(_ key: Key) -> Double? {
        guard let bytes = rawBytes(key) else { return nil }
        switch Self.name(of: key.type) {
        case "flt " where bytes.count >= 4:
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "sp78" where bytes.count >= 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2" where bytes.count >= 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 ", "ui16", "ui32":
            return Double(bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        default:
            return nil
        }
    }

    private func rawBytes(_ key: Key) -> [UInt8]? {
        var input = Message()
        input.key = key.code
        input.dataSize = key.size
        input.command = Command.read.rawValue
        guard var output = call(&input) else { return nil }
        return withUnsafeBytes(of: &output.bytes) { Array($0.prefix(Int(min(key.size, 32)))) }
    }

    private func call(_ input: inout Message) -> Message? {
        var output = Message()
        var outputSize = MemoryLayout<Message>.stride
        let status = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Message>.stride,
                                               &output, &outputSize)
        guard status == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private static func code(_ name: String) -> UInt32 {
        name.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func name(of code: UInt32) -> String {
        String(decoding: withUnsafeBytes(of: code.bigEndian) { Array($0) }, as: UTF8.self)
    }
}

/// Temperatures and fans, read on a background queue.
///
/// A tick reads only what the menu bar and the dropdown's graph need — a few
/// CPU and GPU sensors and the fans (~14 keys, ~10 ms off the main thread);
/// the full set (every core, SSD, battery) is read when the dropdown opens.
final class Sensors {
    struct Fan {
        let current: Double
        let minimum: Double
        let maximum: Double

        /// Where the fan sits between its idle and full speed.
        var fraction: Double {
            maximum > minimum ? min(max((current - minimum) / (maximum - minimum), 0), 1) : 0
        }
    }

    struct Reading {
        var cpu: [Double] = []
        var gpu: [Double] = []
        var ssd: [Double] = []
        var battery: [Double] = []
        var fans: [Fan] = []

        var cpuAverage: Double? { Self.average(cpu) }
        var gpuAverage: Double? { Self.average(gpu) }

        static func average(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
    }

    private struct Layout {
        var cpu: [SMC.Key] = []
        var gpu: [SMC.Key] = []
        var ssd: [SMC.Key] = []
        var battery: [SMC.Key] = []
        /// A fan's idle and full speeds are fixed, so only its current speed is
        /// read per tick.
        var fans: [(current: SMC.Key, minimum: Double, maximum: Double)] = []

        var isEmpty: Bool { cpu.isEmpty && gpu.isEmpty && fans.isEmpty }
    }

    /// Sensors read on every tick, per group. Cores sit close together, so an
    /// even spread of eight tracks the average of thirty within a degree.
    private static let tickSampleCount = 8

    private let queue = DispatchQueue(label: "app.middleshot.sensors", qos: .utility)
    private var smc: SMC?
    private var layout: Layout?
    private var busy = false

    /// Calls back on main. `full` reads every sensor, not just the tick subset.
    /// A request while the previous one is still running is dropped.
    func read(full: Bool, completion: @escaping (Reading?) -> Void) {
        guard !busy else { return }
        busy = true
        queue.async { [self] in
            let reading = readNow(full: full)
            DispatchQueue.main.async {
                self.busy = false
                completion(reading)
            }
        }
    }

    // MARK: - Queue only

    private func readNow(full: Bool) -> Reading? {
        if layout == nil {
            smc = SMC()
            layout = smc.map(discover) ?? Layout()
        }
        guard let smc, let layout, !layout.isEmpty else { return nil }

        func values(_ keys: [SMC.Key]) -> [Double] {
            let chosen = full ? keys : Self.spread(keys, count: Self.tickSampleCount)
            // A sensor that is asleep reads 0 or garbage; only plausible
            // temperatures count toward an average.
            return chosen.compactMap { smc.value($0) }.filter { $0 > 1 && $0 < 130 }
        }
        var reading = Reading()
        reading.cpu = values(layout.cpu)
        reading.gpu = values(layout.gpu)
        if full {
            reading.ssd = values(layout.ssd)
            reading.battery = values(layout.battery)
        }
        reading.fans = layout.fans.compactMap { fan in
            guard let current = smc.value(fan.current) else { return nil }
            return Fan(current: max(current, 0), minimum: fan.minimum, maximum: fan.maximum)
        }
        return reading
    }

    private func discover(_ smc: SMC) -> Layout {
        let names = smc.allKeyNames()
        func keys(_ matches: (String) -> Bool) -> [SMC.Key] {
            names.filter(matches).compactMap(smc.key).filter { key in
                smc.value(key).map { $0 > 1 && $0 < 130 } ?? false
            }
        }
        var layout = Layout()
        // Apple Silicon: Tp = CPU performance cores, Te = efficiency cores.
        // Intel has neither and names its package TC0P/TC0D/TCXC instead.
        layout.cpu = keys { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }
        if layout.cpu.isEmpty {
            layout.cpu = keys { $0.hasPrefix("TC") && ($0.hasSuffix("P") || $0.hasSuffix("D") || $0.hasSuffix("C")) }
        }
        layout.gpu = keys { $0.hasPrefix("Tg") }
        if layout.gpu.isEmpty { layout.gpu = keys { $0.hasPrefix("TG") } }
        layout.ssd = keys { $0.hasPrefix("TH0") }
        layout.battery = keys { $0.count == 4 && $0.hasPrefix("TB") && $0.hasSuffix("T") }

        let fanCount = smc.key("FNum").flatMap { smc.value($0) }.map { Int($0) } ?? 0
        layout.fans = (0..<min(fanCount, 4)).compactMap { index in
            guard let current = smc.key("F\(index)Ac") else { return nil }
            func speed(_ suffix: String) -> Double {
                smc.key("F\(index)\(suffix)").flatMap { smc.value($0) } ?? 0
            }
            return (current, speed("Mn"), speed("Mx"))
        }
        os_log("Sensors: %d CPU, %d GPU, %d SSD, %d battery, %d fans (of %d keys)",
               log: log, type: .info, layout.cpu.count, layout.gpu.count, layout.ssd.count,
               layout.battery.count, layout.fans.count, names.count)
        return layout
    }

    /// `count` keys spread evenly across `keys`, so a subset still covers
    /// every cluster rather than only the first one.
    private static func spread(_ keys: [SMC.Key], count: Int) -> [SMC.Key] {
        guard keys.count > count else { return keys }
        return (0..<count).map { keys[$0 * keys.count / count] }
    }
}
