import Cocoa

/// One readout in the menu bar stats item: its slice of the menu bar image and
/// its section of the dropdown.
///
/// To add a stat (say, Magic Mouse battery), write a class conforming to this
/// and add an instance to `MenuBarStatsController.modules`. Order, visibility,
/// the settings window and the Show submenu all pick it up from there.
protocol MenuBarModule: AnyObject {
    /// Remembers order and visibility in Settings — never rename one.
    var id: String { get }
    var title: String { get }
    /// SF Symbol shown beside the title in the settings list.
    var symbolName: String { get }
    /// Whether it shows before the person has made a choice.
    var isEnabledByDefault: Bool { get }
    /// Its section of the dropdown, built once and reused.
    var menuSection: NSView { get }
    /// Read by VoiceOver for the menu bar item.
    var accessibilityDescription: String { get }

    /// Takes a reading. Called on every tick, only while the module is shown.
    func sample(now: TimeInterval)
    /// Drops history — the update interval changed, so old spacing is wrong.
    func resetHistory()
    func part(style: MenuBarStatsStyle, color: Bool) -> MenuBarPart
    /// Pushes the latest readings into `menuSection`.
    func updateMenuSection(_ timeline: MenuBarTimeline)

    /// Whether the dropdown should take a one-second process sample for it.
    var wantsProcessSnapshot: Bool { get }
    /// The dropdown is about to appear: refresh anything too costly to keep
    /// current every tick. The section may change size here, not later.
    func menuWillOpen()
    /// Nil while the sample is running.
    func show(_ snapshot: ProcessSnapshot?)
    func menuDidClose()
    /// Real menu items for actions, listed above "Open Dashboard…". Clicks on
    /// views inside a menu item aren't delivered reliably, so anything
    /// clickable belongs here rather than in `menuSection`.
    func actionMenuItems() -> [NSMenuItem]
}

extension MenuBarModule {
    var isEnabledByDefault: Bool { true }
    var wantsProcessSnapshot: Bool { false }
    func menuWillOpen() {}
    func show(_ snapshot: ProcessSnapshot?) {}
    func menuDidClose() {}
    func actionMenuItems() -> [NSMenuItem] { [] }
}

/// How far back the dropdown's graphs reach.
struct MenuBarTimeline {
    let interval: TimeInterval
    let capacity: Int
}

/// A fixed-length history, oldest first.
struct SampleHistory {
    let capacity: Int
    private(set) var values: [Double] = []

    init(capacity: Int = 60) {
        self.capacity = capacity
    }

    var last: Double { values.last ?? 0 }

    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    mutating func removeAll() {
        values.removeAll()
    }
}

/// Turns an ever-growing counter (bytes since startup) into a per-second rate.
struct RateMeter {
    private var last: (value: UInt64, time: TimeInterval)?

    /// Nil on the first reading. A counter that went backwards (an interface
    /// that restarted) reads as zero rather than a huge negative rate.
    mutating func rate(of value: UInt64, at time: TimeInterval) -> Double? {
        defer { last = (value, time) }
        guard let last, time > last.time else { return nil }
        return value >= last.value ? Double(value - last.value) / (time - last.time) : 0
    }
}

// MARK: - Dropdown building blocks

enum MenuSection {
    static let contentWidth: CGFloat = StatsMenuContainerView.width - 28

    /// A titled vertical section: "Title ········ value" and rows below.
    static func make(title: String, value: NSTextField?, rows: [NSView]) -> NSStackView {
        let titleLabel = DashboardStyle.label(title, weight: .semibold)
        let header = NSStackView(views: [titleLabel, NSView()] + (value.map { [$0] } ?? []))
        header.alignment = .firstBaseline
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 3
        section.translatesAutoresizingMaskIntoConstraints = false
        section.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        for view in [header] + rows {
            section.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        return section
    }

    static func bigLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "—")
        label.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        label.alignment = .right
        return label
    }

    static func detailLabel(_ text: String = "") -> NSTextField {
        let label = DashboardStyle.label(text, size: 11.5, color: .secondaryLabelColor)
        label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    static func caption(_ text: String) -> NSView {
        let label = DashboardStyle.label(text, size: 11, weight: .semibold, color: .tertiaryLabelColor)
        let container = NSStackView(views: [label])
        container.edgeInsets = NSEdgeInsets(top: 5, left: 0, bottom: 0, right: 0)
        return container
    }

    static func pairRow() -> (row: NSView, name: NSTextField, value: NSTextField) {
        let name = DashboardStyle.label("", size: 12)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let value = DashboardStyle.label("", size: 12, color: .secondaryLabelColor)
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.alignment = .right
        value.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [name, NSView(), value])
        return (row, name, value)
    }

    /// Swatch, name and value — several share one line.
    static func legendItem(_ title: String, color: NSColor) -> (view: NSView, value: NSTextField) {
        let swatch = FillView(color: color, cornerRadius: 2)
        swatch.widthAnchor.constraint(equalToConstant: 8).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let name = DashboardStyle.label(title, size: 11, weight: .medium)
        let value = DashboardStyle.label("", size: 11, color: .secondaryLabelColor)
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for label in [name, value] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let item = NSStackView(views: [swatch, name, value])
        item.spacing = 3
        return (item, value)
    }

    /// Items spread across the full width, so three still fit side by side.
    static func legendLine(_ items: [NSView]) -> NSView {
        let line = NSStackView(views: items.count > 2 ? items : items + [NSView()])
        line.spacing = 10
        line.distribution = items.count > 2 ? .equalSpacing : .fill
        return line
    }

    /// Top-three rows fed by a process snapshot.
    static func showTop(_ rows: [(row: NSView, name: NSTextField, value: NSTextField)],
                        _ entries: [(name: String, value: String)]?) {
        for (index, row) in rows.enumerated() {
            if let entries {
                row.name.stringValue = entries[safe: index]?.name ?? ""
                row.value.stringValue = entries[safe: index]?.value ?? ""
            } else {
                row.name.stringValue = index == 0 ? "Measuring…" : ""
                row.value.stringValue = ""
            }
        }
    }

    /// A scale that leaves the busiest sample some headroom.
    static func niceMaximum(_ bytesPerSecond: Double) -> Double {
        let kilobyte = 1024.0
        for step in [64, 128, 256, 512, 1024, 2048, 5120, 10240, 25600, 51200, 102_400, 512_000, 1_048_576] {
            if bytesPerSecond <= Double(step) * kilobyte { return Double(step) * kilobyte }
        }
        return (bytesPerSecond / (1_048_576 * kilobyte)).rounded(.up) * 1_048_576 * kilobyte
    }
}

/// The dropdown's content: enabled modules' sections, in order, with
/// separators between them.
final class StatsMenuContainerView: NSView {
    static let width: CGFloat = 300

    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 4, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is not used")
    }

    /// Only call while the menu is closed or opening — a menu item's view must
    /// not change size once it is on screen.
    func show(sections: [NSView]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, section) in sections.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                stack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalToConstant: MenuSection.contentWidth).isActive = true
                stack.setCustomSpacing(9, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
                stack.setCustomSpacing(9, after: separator)
            }
            stack.addArrangedSubview(section)
        }
        resize()
    }

    func resize() {
        layoutSubtreeIfNeeded()
        setFrameSize(fittingSize)
    }
}

/// A line chart of the last minute or so, newest sample at the right edge.
/// Pointing at it marks the sample under the cursor, labels its time on the
/// chart, and reports it through `onHover`.
final class HistoryChartView: NSView {
    struct Series {
        let values: [Double]
        let color: NSColor
    }

    var series: [Series] = [] {
        didSet { needsDisplay = true }
    }
    var maximum: Double = 1
    var maximumLabel = ""
    var timeline = MenuBarTimeline(interval: 1, capacity: 60) {
        didSet { needsDisplay = true }
    }
    var onHover: ((Int?) -> Void)?
    private(set) var hoverIndex: Int?

    private let top: CGFloat = 12
    private let bottom: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 58)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .activeAlways: a menu's window is never key, but hover still has to work.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let count = series.first?.values.count ?? 0
        guard count > 0 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let fromRight = Int(((bounds.width - x) / step).rounded())
        let index = min(max(count - 1 - fromRight, 0), count - 1)
        guard index != hoverIndex else { return }
        hoverIndex = index
        needsDisplay = true
        onHover?(index)
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    func clearHover() {
        guard hoverIndex != nil else { return }
        hoverIndex = nil
        needsDisplay = true
        onHover?(nil)
    }

    private var step: CGFloat { bounds.width / CGFloat(max(timeline.capacity - 1, 1)) }

    override func draw(_ dirtyRect: NSRect) {
        let plotHeight = bounds.height - top - bottom
        func y(_ value: Double) -> CGFloat {
            top + plotHeight - CGFloat(min(max(value / max(maximum, .leastNonzeroMagnitude), 0), 1)) * plotHeight
        }
        func x(_ index: Int, of count: Int) -> CGFloat {
            bounds.width - CGFloat(count - 1 - index) * step
        }

        NSColor.separatorColor.setFill()
        for gridY in [top, top + plotHeight / 2, top + plotHeight] {
            NSRect(x: 0, y: gridY - 0.5, width: bounds.width, height: 1).fill()
        }
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        (maximumLabel as NSString).draw(at: NSPoint(x: 0, y: -1), withAttributes: labelAttributes)

        let count = series.first?.values.count ?? 0
        let index = count > 0 ? min(hoverIndex ?? count - 1, count - 1) : 0
        let markerX = count > 0 ? x(index, of: count) : bounds.width
        let labelY = bounds.height - 11
        if let hoverIndex, count > 0 {
            // The hovered time replaces the axis labels, right under the marker.
            let seconds = Double(count - 1 - hoverIndex) * timeline.interval
            let text = (seconds == 0 ? "now" : "−\(Self.duration(seconds))") as NSString
            let width = text.size(withAttributes: labelAttributes).width
            let labelX = min(max(markerX - width / 2, 0), bounds.width - width)
            text.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        } else {
            let span = "\(Self.duration(Double(timeline.capacity) * timeline.interval)) ago" as NSString
            span.draw(at: NSPoint(x: 0, y: labelY), withAttributes: labelAttributes)
            let now = "now" as NSString
            now.draw(at: NSPoint(x: bounds.width - now.size(withAttributes: labelAttributes).width, y: labelY),
                     withAttributes: labelAttributes)
        }

        for line in series where line.values.count > 1 {
            let lineCount = line.values.count
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x(0, of: lineCount), y: y(line.values[0])))
            for pointIndex in 1..<lineCount {
                path.line(to: NSPoint(x: x(pointIndex, of: lineCount), y: y(line.values[pointIndex])))
            }
            if series.count == 1, let area = path.copy() as? NSBezierPath {
                area.line(to: NSPoint(x: bounds.width, y: top + plotHeight))
                area.line(to: NSPoint(x: x(0, of: lineCount), y: top + plotHeight))
                area.close()
                line.color.withAlphaComponent(0.14).setFill()
                area.fill()
            }
            path.lineWidth = 2
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            line.color.setStroke()
            path.stroke()
        }

        guard count > 0 else { return }
        if hoverIndex != nil {
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: markerX - 0.5, y: top, width: 1, height: plotHeight).fill()
        }
        for line in series where index < line.values.count {
            let center = NSPoint(x: markerX, y: y(line.values[index]))
            line.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)).fill()
        }
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int((seconds / 60).rounded())) min"
    }
}
