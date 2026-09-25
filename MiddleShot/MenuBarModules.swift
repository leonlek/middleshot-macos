import Cocoa

// MARK: - CPU

final class CPUModule: MenuBarModule {
    let id = "cpu"
    let title = "CPU"
    let symbolName = "cpu"
    let wantsProcessSnapshot = true

    private var lastTicks: SystemStats.CPUTicks?
    private var history = SampleHistory()
    /// An app has kept the CPU busy: bars turn orange and a dot appears (the
    /// dot is what shows in a monochrome menu bar).
    var isAlerting = false

    private let value = MenuSection.bigLabel()
    private let detail = MenuSection.detailLabel()
    private let chart = HistoryChartView()
    private let top = (0..<3).map { _ in MenuSection.pairRow() }
    private(set) lazy var menuSection: NSView = {
        chart.maximum = 1
        chart.maximumLabel = "100%"
        chart.onHover = { [weak self] _ in self?.refresh() }
        return MenuSection.make(title: "CPU", value: value,
                                rows: [detail, chart, MenuSection.caption("Using the most CPU")] + top.map(\.row))
    }()

    var accessibilityDescription: String { String(format: "CPU %.0f%%", history.last * 100) }

    func sample(now: TimeInterval) {
        let ticks = SystemStats.cpuTicks()
        if let lastTicks {
            let load = ticks.load(since: lastTicks)
            history.append(load.user + load.system)
        }
        lastTicks = ticks
    }

    func resetHistory() { history.removeAll() }

    func part(style: MenuBarStatsStyle, color: Bool) -> MenuBarPart {
        let values = history.values
        switch style {
        case .numbers:
            return MenuBarDrawing.numberPart(label: "CPU", value: MenuBarDrawing.percent(history.last),
                                             widest: ["100%"], color: color)
        case .graphsAndNumbers, .graphs:
            let labeled = style == .graphsAndNumbers
            let labelWidth = labeled ? MenuBarDrawing.verticalLabelWidth : 0
            let alerting = isAlerting
            let key = "cpu\(labeled)\(alerting)" + values.suffix(MenuBarDrawing.historyBarCount).map { String(MenuBarDrawing.pixelKey($0)) }.joined(separator: ",")
            // Room for the alert dot is always kept, so the width never changes.
            return MenuBarPart(width: labelWidth + MenuBarDrawing.historyBarsWidth + 5, key: key) { x in
                if labeled { MenuBarDrawing.drawVerticalLabel("CPU", x: x, color: color) }
                let barsX = x + labelWidth
                MenuBarDrawing.drawHistoryBars(values, x: barsX, tint: alerting ? .systemOrange : DashboardStyle.seriesBlue,
                                               color: color)
                if alerting {
                    MenuBarDrawing.fill(.systemOrange, color: color).setFill()
                    let dotX = barsX + MenuBarDrawing.historyBarsWidth + 1.5
                    NSBezierPath(ovalIn: NSRect(x: dotX, y: MenuBarDrawing.bandTop - 3.5, width: 3.5, height: 3.5)).fill()
                }
            }
        }
    }

    func updateMenuSection(_ timeline: MenuBarTimeline) {
        chart.timeline = timeline
        refresh()
    }

    func show(_ snapshot: ProcessSnapshot?) {
        MenuSection.showTop(top, snapshot.map { snapshot in
            snapshot.apps.sorted { $0.cpu > $1.cpu }.prefix(3).map { ($0.name, String(format: "%.0f%%", $0.cpu)) }
        })
    }

    func menuDidClose() { chart.clearHover() }

    private func refresh() {
        value.stringValue = MenuBarDrawing.percent(history.last)
        if let index = chart.hoverIndex, let past = history.values[safe: index] {
            detail.stringValue = String(format: "%.0f%% at the marked moment", past * 100)
        } else {
            detail.stringValue = "\(ProcessInfo.processInfo.activeProcessorCount) cores"
        }
        chart.series = [.init(values: history.values, color: DashboardStyle.seriesBlue)]
    }
}

// MARK: - Memory

final class MemoryModule: MenuBarModule {
    let id = "memory"
    let title = "Memory"
    let symbolName = "memorychip"
    let wantsProcessSnapshot = true

    private var memory: SystemStats.Memory?

    private let value = MenuSection.bigLabel()
    private let detail = MenuSection.detailLabel()
    private let pressureChip = ChipView(text: "—", color: .secondaryLabelColor)
    private let bar = BarView(thickness: 8)
    private let app = MenuSection.legendItem("App", color: DashboardStyle.seriesBlue)
    private let wired = MenuSection.legendItem("Wired", color: DashboardStyle.seriesOrange)
    private let compressed = MenuSection.legendItem("Compressed", color: DashboardStyle.seriesAqua)
    private let top = (0..<3).map { _ in MenuSection.pairRow() }
    private(set) lazy var menuSection: NSView = {
        bar.segmentGap = 2
        let pressureLine = NSStackView(views: [pressureChip, MenuSection.detailLabel("memory pressure")])
        pressureLine.spacing = 6
        let section = MenuSection.make(title: "Memory", value: value, rows: [
            detail, pressureLine, bar, MenuSection.legendLine([app.view, wired.view, compressed.view]),
            MenuSection.caption("Using the most memory"),
        ] + top.map(\.row))
        section.setCustomSpacing(8, after: pressureLine)
        section.setCustomSpacing(6, after: bar)
        return section
    }()

    private var usedFraction: Double {
        guard let memory, memory.total > 0 else { return 0 }
        return Double(memory.used) / Double(memory.total)
    }

    var accessibilityDescription: String { String(format: "Memory %.0f%% used", usedFraction * 100) }

    func sample(now: TimeInterval) {
        memory = SystemStats.memory()
    }

    func resetHistory() {}

    func part(style: MenuBarStatsStyle, color: Bool) -> MenuBarPart {
        let fraction = usedFraction
        let tint: NSColor
        switch memory?.pressure ?? .normal {
        case .normal: tint = .systemGreen
        case .warning: tint = .systemOrange
        case .critical: tint = .systemRed
        }
        switch style {
        case .numbers:
            return MenuBarDrawing.numberPart(label: "MEM", value: MenuBarDrawing.percent(fraction),
                                             widest: ["100%"], color: color)
        case .graphsAndNumbers, .graphs:
            let labeled = style == .graphsAndNumbers
            let labelWidth = labeled ? MenuBarDrawing.verticalLabelWidth : 0
            let key = "mem\(labeled)\(Int((fraction * 200).rounded()))\(memory?.pressure.rawValue ?? 0)"
            return MenuBarPart(width: labelWidth + MenuBarDrawing.bandHeight, key: key) { x in
                if labeled { MenuBarDrawing.drawVerticalLabel("MEM", x: x, color: color) }
                MenuBarDrawing.drawPie(fraction: fraction, x: x + labelWidth, tint: tint, color: color)
            }
        }
    }

    func updateMenuSection(_ timeline: MenuBarTimeline) {
        guard let memory else { return }
        value.stringValue = DashboardStyle.memory(memory.used)
        detail.stringValue = "of \(DashboardStyle.memory(memory.total)) · swap \(DashboardStyle.memory(memory.swapUsed))"
        switch memory.pressure {
        case .normal: pressureChip.update(text: "Normal", color: .systemGreen)
        case .warning: pressureChip.update(text: "Warning", color: .systemOrange)
        case .critical: pressureChip.update(text: "Critical", color: .systemRed)
        }
        let total = Double(max(memory.total, 1))
        bar.segments = [
            .init(fraction: Double(memory.app) / total, color: DashboardStyle.seriesBlue),
            .init(fraction: Double(memory.wired) / total, color: DashboardStyle.seriesOrange),
            .init(fraction: Double(memory.compressed) / total, color: DashboardStyle.seriesAqua),
        ]
        // One unit for the whole line — three "GB"s don't fit in the menu's width.
        app.value.stringValue = Self.gigabytes(memory.app)
        wired.value.stringValue = Self.gigabytes(memory.wired)
        compressed.value.stringValue = Self.gigabytes(memory.compressed) + " GB"
    }

    func show(_ snapshot: ProcessSnapshot?) {
        MenuSection.showTop(top, snapshot.map { snapshot in
            snapshot.apps.sorted { $0.memory > $1.memory }.prefix(3).map { ($0.name, DashboardStyle.memory($0.memory)) }
        })
    }

    private static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
}

// MARK: - Network

/// Wi‑Fi and Ethernet only — VPN tunnels would count the same bytes twice.
final class NetworkModule: MenuBarModule {
    let id = "network"
    let title = "Network"
    let symbolName = "arrow.up.arrow.down"

    private var meterDown = RateMeter()
    private var meterUp = RateMeter()
    private var down = SampleHistory()
    private var up = SampleHistory()
    private var totals: SystemStats.NetworkCounters?

    private let interfaceLabel = MenuSection.detailLabel()
    private let downloadItem = MenuSection.legendItem("↓ Download", color: DashboardStyle.seriesBlue)
    private let uploadItem = MenuSection.legendItem("↑ Upload", color: DashboardStyle.seriesOrange)
    private let chart = HistoryChartView()
    private let totalsRow = MenuSection.pairRow()
    private(set) lazy var menuSection: NSView = {
        chart.onHover = { [weak self] _ in self?.refresh() }
        totalsRow.name.stringValue = "Since startup"
        return MenuSection.make(title: "Network", value: nil, rows: [
            interfaceLabel, MenuSection.legendLine([downloadItem.view, uploadItem.view]), chart, totalsRow.row,
        ])
    }()

    var accessibilityDescription: String {
        "Download \(MenuBarDrawing.rate(down.last)), upload \(MenuBarDrawing.rate(up.last))"
    }

    func sample(now: TimeInterval) {
        let counters = SystemStats.networkCounters()
        if let rate = meterDown.rate(of: counters.received, at: now) { down.append(rate) }
        if let rate = meterUp.rate(of: counters.sent, at: now) { up.append(rate) }
        totals = counters
    }

    func resetHistory() {
        down.removeAll()
        up.removeAll()
    }

    func part(style: MenuBarStatsStyle, color: Bool) -> MenuBarPart {
        switch style {
        case .numbers:
            let font = MenuBarDrawing.numberFont
            let arrowWidth = MenuBarDrawing.maxWidth(of: ["↓"], font: font)
            let valueWidth = MenuBarDrawing.maxWidth(of: MenuBarDrawing.widestShortRates, font: font)
            let downText = MenuBarDrawing.shortRate(down.last), upText = MenuBarDrawing.shortRate(up.last)
            return MenuBarPart(width: (arrowWidth + valueWidth) * 2 + 6, key: downText + "|" + upText) { x in
                let baseline = MenuBarDrawing.centeredBaseline(for: font)
                let ink = MenuBarDrawing.ink(color)
                MenuBarDrawing.drawText("↓", x: x, baseline: baseline, font: font, color: ink)
                MenuBarDrawing.drawText(downText, right: x + arrowWidth + valueWidth, baseline: baseline, font: font, color: ink)
                let second = x + arrowWidth + valueWidth + 6
                MenuBarDrawing.drawText("↑", x: second, baseline: baseline, font: font, color: ink)
                MenuBarDrawing.drawText(upText, right: second + arrowWidth + valueWidth, baseline: baseline, font: font, color: ink)
            }
        case .graphsAndNumbers, .graphs:
            // Icons Only keeps the rates too: without them nothing is left to read.
            return MenuBarDrawing.arrowsAndTwoLines(top: MenuBarDrawing.rate(up.last), bottom: MenuBarDrawing.rate(down.last),
                                                    widest: MenuBarDrawing.widestRates, color: color)
        }
    }

    func updateMenuSection(_ timeline: MenuBarTimeline) {
        chart.timeline = timeline
        if let totals {
            totalsRow.value.stringValue = "↓ \(DashboardStyle.bytes(Int64(clamping: totals.received))) · ↑ \(DashboardStyle.bytes(Int64(clamping: totals.sent)))"
        }
        refresh()
    }

    func menuWillOpen() {
        interfaceLabel.stringValue = SystemStats.primaryInterfaceDescription() ?? "Not connected"
    }

    func menuDidClose() { chart.clearHover() }

    private func refresh() {
        let index = chart.hoverIndex
        downloadItem.value.stringValue = MenuBarDrawing.rate(index.flatMap { down.values[safe: $0] } ?? down.last)
        uploadItem.value.stringValue = MenuBarDrawing.rate(index.flatMap { up.values[safe: $0] } ?? up.last)
        let maximum = MenuSection.niceMaximum(max(down.values.max() ?? 0, up.values.max() ?? 0))
        chart.maximum = maximum
        chart.maximumLabel = MenuBarDrawing.rate(maximum)
        chart.series = [
            .init(values: down.values, color: DashboardStyle.seriesBlue),
            .init(values: up.values, color: DashboardStyle.seriesOrange),
        ]
    }
}

// MARK: - Disk

/// Free space on the startup disk in the menu bar; read/write rates, external
/// drives and the last Safe to Clean total in the dropdown.
final class DiskModule: NSObject, MenuBarModule {
    let id = "disk"
    let title = "Disk"
    let symbolName = "internaldrive"

    /// The Dashboard's latest Safe to Clean total, if it has scanned.
    var cleanupSummary: (() -> (size: Int64, finishedAt: Date)?)?
    var onOpenSafeToClean: (() -> Void)?

    /// Free space changes slowly, and "available" (purgeable space included)
    /// costs more to compute than the other readings.
    private static let spaceInterval: TimeInterval = 30

    private var space: SystemStats.DiskSpace?
    private var lastSpaceRead: TimeInterval?
    private var meterRead = RateMeter()
    private var meterWrite = RateMeter()
    private var read = SampleHistory()
    private var write = SampleHistory()

    private let value = MenuSection.bigLabel()
    private let detail = MenuSection.detailLabel()
    private let bar = BarView(thickness: 8)
    private let readItem = MenuSection.legendItem("Read", color: DashboardStyle.seriesBlue)
    private let writeItem = MenuSection.legendItem("Write", color: DashboardStyle.seriesOrange)
    private let chart = HistoryChartView()
    private let externalCaption = MenuSection.caption("External drives")
    private let externalRows = NSStackView()
    private(set) lazy var menuSection: NSView = {
        chart.onHover = { [weak self] _ in self?.refresh() }
        externalRows.orientation = .vertical
        externalRows.alignment = .leading
        externalRows.spacing = 3
        let section = MenuSection.make(title: "Disk", value: value, rows: [
            detail, bar, MenuSection.legendLine([readItem.view, writeItem.view]), chart,
            externalCaption, externalRows,
        ])
        section.setCustomSpacing(6, after: bar)
        section.setCustomSpacing(6, after: chart)
        externalCaption.isHidden = true
        externalRows.isHidden = true
        return section
    }()

    var accessibilityDescription: String {
        space.map { "Disk \(MenuBarDrawing.freeSpace($0.available)) free" } ?? "Disk"
    }

    func sample(now: TimeInterval) {
        let counters = SystemStats.diskIOCounters()
        if let rate = meterRead.rate(of: counters.read, at: now) { read.append(rate) }
        if let rate = meterWrite.rate(of: counters.written, at: now) { write.append(rate) }
        if lastSpaceRead.map({ now - $0 >= Self.spaceInterval }) ?? true {
            space = SystemStats.startupDisk()
            lastSpaceRead = now
        }
    }

    func resetHistory() {
        read.removeAll()
        write.removeAll()
    }

    func part(style: MenuBarStatsStyle, color: Bool) -> MenuBarPart {
        let freeFraction = space?.freeFraction ?? 1
        let tint: NSColor = freeFraction < 0.05 ? .systemRed : freeFraction < 0.10 ? .systemOrange : DashboardStyle.seriesBlue
        switch style {
        case .numbers:
            return MenuBarDrawing.numberPart(label: "SSD", value: space.map { MenuBarDrawing.shortFree($0.available) } ?? "—",
                                             widest: ["999G", "99.9G", "9.9T"], color: color)
        case .graphsAndNumbers, .graphs:
            // Free space stays in Icons Only too — it's the number that matters.
            // Number over unit ("8.5" / "GB") rather than "8.5 GB" over "free":
            // the slot is as wide as its widest value, and the unit on its own
            // line takes ~15 pt off that. The bar already says it's free space.
            let labeled = style == .graphsAndNumbers
            let labelWidth = labeled ? MenuBarDrawing.verticalLabelWidth : 0
            let valueFont = MenuBarDrawing.smallFont, captionFont = MenuBarDrawing.captionFont
            let textWidth = max(MenuBarDrawing.maxWidth(of: ["99.9", "999"], font: valueFont),
                                MenuBarDrawing.maxWidth(of: ["GB", "MB", "TB"], font: captionFont))
            let text = space.map { MenuBarDrawing.freeSpace($0.available) } ?? "—"
            let pieces = text.split(separator: " ", maxSplits: 1).map(String.init)
            let number = pieces.first ?? "—", unit = pieces.count > 1 ? pieces[1] : ""
            let key = "ssd\(labeled)\(text)\(MenuBarDrawing.pixelKey(1 - freeFraction))\(tint)"
            return MenuBarPart(width: labelWidth + 9 + textWidth, key: key) { x in
                if labeled { MenuBarDrawing.drawVerticalLabel("SSD", x: x, color: color) }
                MenuBarDrawing.drawLevelBar(fraction: 1 - freeFraction, x: x + labelWidth, tint: tint, color: color)
                let textX = x + labelWidth + 9
                let ink = MenuBarDrawing.ink(color)
                MenuBarDrawing.drawText(number, x: textX, baseline: MenuBarDrawing.bandTop - valueFont.capHeight,
                                        font: valueFont, color: ink)
                MenuBarDrawing.drawText(unit, x: textX, baseline: MenuBarDrawing.bandBottom, font: captionFont,
                                        color: ink.withAlphaComponent(0.7))
            }
        }
    }

    func updateMenuSection(_ timeline: MenuBarTimeline) {
        chart.timeline = timeline
        refresh()
    }

    func menuWillOpen() {
        // Opening the menu is a moment someone wants a current number.
        space = SystemStats.startupDisk()
        lastSpaceRead = ProcessInfo.processInfo.systemUptime

        externalRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let externals = SystemStats.externalDisks()
        for disk in externals {
            let row = MenuSection.pairRow()
            row.name.stringValue = disk.name
            row.value.stringValue = "\(MenuBarDrawing.freeSpace(disk.available)) free of \(DashboardStyle.bytes(disk.total))"
            externalRows.addArrangedSubview(row.row)
            row.row.widthAnchor.constraint(equalTo: externalRows.widthAnchor).isActive = true
        }
        externalCaption.isHidden = externals.isEmpty
        externalRows.isHidden = externals.isEmpty
    }

    /// "Safe to Clean · 84.2 GB (scanned 18:58)", once the Dashboard has scanned.
    func actionMenuItems() -> [NSMenuItem] {
        guard let summary = cleanupSummary?() else { return [] }
        let time = DateFormatter.localizedString(from: summary.finishedAt, dateStyle: .none, timeStyle: .short)
        let item = NSMenuItem(title: "Safe to Clean · \(DashboardStyle.bytes(summary.size)) (scanned \(time))",
                              action: #selector(openSafeToClean), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        return [item]
    }

    @objc private func openSafeToClean() {
        onOpenSafeToClean?()
    }

    func menuDidClose() { chart.clearHover() }

    private func refresh() {
        if let space {
            value.stringValue = "\(MenuBarDrawing.freeSpace(space.available)) free"
            detail.stringValue = "\(space.name) · \(DashboardStyle.bytes(space.used)) of \(DashboardStyle.bytes(space.total)) used"
            let tint: NSColor = space.freeFraction < 0.05 ? .systemRed
                : space.freeFraction < 0.10 ? .systemOrange : DashboardStyle.seriesBlue
            bar.segments = [.init(fraction: 1 - space.freeFraction, color: tint)]
        }
        let index = chart.hoverIndex
        readItem.value.stringValue = MenuBarDrawing.rate(index.flatMap { read.values[safe: $0] } ?? read.last)
        writeItem.value.stringValue = MenuBarDrawing.rate(index.flatMap { write.values[safe: $0] } ?? write.last)
        let maximum = MenuSection.niceMaximum(max(read.values.max() ?? 0, write.values.max() ?? 0))
        chart.maximum = maximum
        chart.maximumLabel = MenuBarDrawing.rate(maximum)
        chart.series = [
            .init(values: read.values, color: DashboardStyle.seriesBlue),
            .init(values: write.values, color: DashboardStyle.seriesOrange),
        ]
    }
}

// MARK: - Sensors

/// CPU temperature and fan speed in one slot; every sensor and fan in the
/// dropdown. Readings come from the SMC on a background queue (`Sensors`), so
/// the menu bar shows the previous tick's values — a second old at most.
final class SensorsModule: MenuBarModule {
    let id = "sensors"
    let title = "Temperature & Fans"
    let symbolName = "thermometer.medium"

    private let sensors = Sensors()
    private var reading: Sensors.Reading?
    /// The last full read: SSD and battery are only read then.
    private var fullReading: Sensors.Reading?
    private var isOpen = false
    private var cpu = SampleHistory()
    private var gpu = SampleHistory()

    private let value = MenuSection.bigLabel()
    private let detail = MenuSection.detailLabel()
    private let cpuItem = MenuSection.legendItem("CPU", color: DashboardStyle.seriesBlue)
    private let gpuItem = MenuSection.legendItem("GPU", color: DashboardStyle.seriesOrange)
    private let chart = HistoryChartView()
    private let temperatureRows = (0..<4).map { _ in MenuSection.pairRow() }
    private let fansCaption = MenuSection.caption("Fans")
    private let fanRows = NSStackView()
    private var fanLines: [(row: NSView, name: NSTextField, value: NSTextField, bar: BarView)] = []
    private(set) lazy var menuSection: NSView = {
        chart.maximum = 110
        chart.maximumLabel = "110°C"
        chart.onHover = { [weak self] _ in self?.refresh() }
        fanRows.orientation = .vertical
        fanRows.alignment = .leading
        fanRows.spacing = 3
        fansCaption.isHidden = true
        let section = MenuSection.make(title: "Temperature", value: value, rows: [
            detail, MenuSection.legendLine([cpuItem.view, gpuItem.view]), chart,
        ] + temperatureRows.map(\.row) + [fansCaption, fanRows])
        section.setCustomSpacing(6, after: chart)
        return section
    }()

    var accessibilityDescription: String {
        var parts = [reading?.cpuAverage.map { "CPU \(Self.degrees($0))" } ?? "Temperature unavailable"]
        if let fan = reading?.fans.max(by: { $0.current < $1.current }) { parts.append("fan \(Self.rpm(fan.current))") }
        return parts.joined(separator: ", ")
    }

    func sample(now: TimeInterval) {
        // The first read is a full one, so the dropdown knows from the start
        // which rows (SSD, battery, how many fans) this Mac has.
        let full = isOpen || fullReading == nil
        sensors.read(full: full) { [weak self] reading in
            guard let self, let reading else { return }
            self.reading = reading
            if full { self.fullReading = reading }
            if let average = reading.cpuAverage { self.cpu.append(average) }
            if let average = reading.gpuAverage { self.gpu.append(average) }
            self.buildFanRowsIfNeeded(count: reading.fans.count)
        }
    }

    func resetHistory() {
        cpu.removeAll()
        gpu.removeAll()
    }

    func part(style: MenuBarStatsStyle, color: Bool) -> MenuBarPart {
        let temperature = reading?.cpuAverage
        let tint = Self.tint(temperature)
        let degrees = temperature.map(Self.degrees) ?? "—"
        let fan = reading?.fans.max(by: { $0.current < $1.current })
        let fanText = fan.map { Self.shortRPM($0.current) }
        switch style {
        case .numbers:
            let font = MenuBarDrawing.numberFont, labelFont = MenuBarDrawing.numberLabelFont
            let degreesWidth = MenuBarDrawing.maxWidth(of: ["100°"], font: font)
            let fanLabelWidth = MenuBarDrawing.maxWidth(of: ["FAN"], font: labelFont)
            let fanWidth = MenuBarDrawing.maxWidth(of: ["9.9k", "off"], font: font)
            let hasFan = fanText != nil
            let width = degreesWidth + (hasFan ? 6 + fanLabelWidth + 4 + fanWidth : 0)
            return MenuBarPart(width: width, key: "tmp#\(degrees)|\(fanText ?? "")") { x in
                let baseline = MenuBarDrawing.centeredBaseline(for: font)
                let ink = MenuBarDrawing.ink(color)
                MenuBarDrawing.drawText(degrees, right: x + degreesWidth, baseline: baseline, font: font, color: ink)
                guard let fanText else { return }
                let fanX = x + degreesWidth + 6
                MenuBarDrawing.drawText("FAN", x: fanX, baseline: baseline, font: labelFont, color: ink.withAlphaComponent(0.7))
                MenuBarDrawing.drawText(fanText, right: fanX + fanLabelWidth + 4 + fanWidth, baseline: baseline,
                                        font: font, color: ink)
            }
        case .graphsAndNumbers, .graphs:
            // "81°C" over a fan glyph and "3.8k" beside a gauge. No stacked label
            // and no "rpm": the degree sign and the fan say what each line is,
            // and the slot is as wide as its widest line.
            let valueFont = MenuBarDrawing.smallFont, captionFont = MenuBarDrawing.captionFont
            let glyphSide = captionFont.capHeight + 3.5
            let bottom = fanText ?? "CPU"
            let textWidth = max(MenuBarDrawing.maxWidth(of: ["100°C"], font: valueFont),
                                glyphSide + 1.5 + MenuBarDrawing.maxWidth(of: ["9.9k", "off"], font: captionFont))
            let fraction = temperature.map { ($0 - 30) / 70 } ?? 0
            let key = "tmp\(degrees)|\(bottom)|\(MenuBarDrawing.pixelKey(fraction))|\(tint)"
            return MenuBarPart(width: 9 + textWidth, key: key) { x in
                MenuBarDrawing.drawLevelBar(fraction: fraction, x: x, tint: tint, color: color)
                let ink = MenuBarDrawing.ink(color)
                MenuBarDrawing.drawText(temperature.map { Self.degrees($0) + "C" } ?? "—", x: x + 9,
                                        baseline: MenuBarDrawing.bandTop - valueFont.capHeight, font: valueFont, color: ink)
                var textX = x + 9
                if fanText != nil {
                    Self.drawFan(in: NSRect(x: textX, y: MenuBarDrawing.bandBottom - 1.5,
                                            width: glyphSide, height: glyphSide),
                                 color: ink.withAlphaComponent(0.7))
                    textX += glyphSide + 1.5
                }
                MenuBarDrawing.drawText(bottom, x: textX, baseline: MenuBarDrawing.bandBottom, font: captionFont,
                                        color: ink.withAlphaComponent(0.7))
            }
        }
    }

    func updateMenuSection(_ timeline: MenuBarTimeline) {
        chart.timeline = timeline
        refresh()
    }

    func menuWillOpen() {
        isOpen = true
        buildFanRowsIfNeeded(count: reading?.fans.count ?? 0)
        let rows = temperatureRows(fullReading)
        for (index, line) in temperatureRows.enumerated() {
            line.row.isHidden = index >= rows.count
        }
    }

    func menuDidClose() {
        isOpen = false
        chart.clearHover()
    }

    private func refresh() {
        let latest = isOpen ? reading : reading ?? fullReading
        value.stringValue = latest?.cpuAverage.map { Self.degrees($0) + "C" } ?? "—"
        if let index = chart.hoverIndex, let past = cpu.values[safe: index] {
            detail.stringValue = "CPU \(Self.degrees(past))C at the marked moment"
        } else if let hottest = latest?.cpu.max() {
            detail.stringValue = "CPU average · hottest sensor \(Self.degrees(hottest))C"
        } else {
            detail.stringValue = "No temperature sensors found"
        }
        let index = chart.hoverIndex
        cpuItem.value.stringValue = (index.flatMap { cpu.values[safe: $0] } ?? latest?.cpuAverage).map(Self.degrees) ?? "—"
        gpuItem.value.stringValue = (index.flatMap { gpu.values[safe: $0] } ?? latest?.gpuAverage).map(Self.degrees) ?? "—"
        chart.series = [
            .init(values: cpu.values, color: DashboardStyle.seriesBlue),
            .init(values: gpu.values, color: DashboardStyle.seriesOrange),
        ]

        // While open every tick is a full read; closed (a hover bubble), SSD and
        // battery come from the last full one.
        var merged = latest ?? Sensors.Reading()
        if merged.ssd.isEmpty { merged.ssd = fullReading?.ssd ?? [] }
        if merged.battery.isEmpty { merged.battery = fullReading?.battery ?? [] }
        for (line, row) in zip(temperatureRows, temperatureRows(merged)) {
            line.name.stringValue = row.name
            line.value.stringValue = row.value
        }
        for (line, fan) in zip(fanLines, latest?.fans ?? []) {
            line.value.stringValue = fan.current < 1 ? "off"
                : "\(Self.rpm(fan.current)) · \(Int((fan.fraction * 100).rounded()))%"
            line.bar.segments = [.init(fraction: fan.maximum > 0 ? fan.current / fan.maximum : 0,
                                       color: DashboardStyle.seriesAqua)]
        }
    }

    private func temperatureRows(_ reading: Sensors.Reading?) -> [(name: String, value: String)] {
        guard let reading else { return [] }
        var rows: [(String, String)] = []
        if let average = reading.cpuAverage, let hottest = reading.cpu.max() {
            rows.append(("CPU (\(reading.cpu.count) sensors)", "\(Self.degrees(average))C · max \(Self.degrees(hottest))C"))
        }
        if let average = reading.gpuAverage { rows.append(("GPU", Self.degrees(average) + "C")) }
        if let ssd = reading.ssd.max() { rows.append(("SSD", Self.degrees(ssd) + "C")) }
        if let battery = reading.battery.max() { rows.append(("Battery", Self.degrees(battery) + "C")) }
        return rows
    }

    /// Fan rows are made once, when the fan count is first known — a Mac
    /// doesn't grow fans, and a menu item's view mustn't resize while shown.
    private func buildFanRowsIfNeeded(count: Int) {
        guard fanLines.isEmpty, count > 0 else { return }
        for index in 0..<count {
            let pair = MenuSection.pairRow()
            pair.name.stringValue = count == 1 ? "Fan" : "Fan \(index + 1)"
            let bar = BarView(thickness: 4)
            let line = NSStackView(views: [pair.row, bar])
            line.orientation = .vertical
            line.alignment = .leading
            line.spacing = 2
            pair.row.widthAnchor.constraint(equalTo: line.widthAnchor).isActive = true
            bar.widthAnchor.constraint(equalTo: line.widthAnchor).isActive = true
            fanRows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: fanRows.widthAnchor).isActive = true
            fanLines.append((line, pair.name, pair.value, bar))
        }
        fansCaption.isHidden = false
    }

    private static func tint(_ temperature: Double?) -> NSColor {
        guard let temperature else { return DashboardStyle.seriesBlue }
        return temperature >= 95 ? .systemRed : temperature >= 85 ? .systemOrange : DashboardStyle.seriesBlue
    }

    /// The `fan.fill` symbol in one flat color, so it tints like text (and
    /// turns black in a template image).
    private static func drawFan(in rect: NSRect, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        // Fit the symbol's own aspect inside the square, centred.
        let scale = min(rect.width / symbol.size.width, rect.height / symbol.size.height)
        let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                               width: size.width, height: size.height))
    }

    static func degrees(_ celsius: Double) -> String { "\(Int(celsius.rounded()))°" }

    static func rpm(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return (formatter.string(from: NSNumber(value: Int(value.rounded()))) ?? "\(Int(value))") + " rpm"
    }

    /// "3.8k", or "off" for a stopped fan.
    static func shortRPM(_ value: Double) -> String {
        value < 1 ? "off" : String(format: "%.1fk", value / 1000)
    }
}
