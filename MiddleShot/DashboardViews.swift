import Cocoa

/// One tab of the dashboard. Nothing in a panel refreshes on its own: the
/// window's Refresh button calls `startRefresh()`, and the panel reports back
/// through `onStateChange` so the toolbar can switch between Refresh and Stop
/// and restamp "Updated …".
protocol DashboardPanel: AnyObject {
    var lastUpdated: Date? { get }
    var isWorking: Bool { get }
    /// Stamp text before the first refresh ("Not scanned yet").
    var neverUpdatedText: String { get }
    var onStateChange: (() -> Void)? { get set }
    func startRefresh()
    /// `announce` shows the "stopped" toast — skipped when the window closes.
    func stopRefresh(announce: Bool)
}

enum DashboardStyle {
    /// Subtle card ground that reads on both the light and dark window.
    static let cardColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06)
            : NSColor(white: 0, alpha: 0.04)
    }

    /// Series colors for charts — the first three slots of a palette validated
    /// for color-vision deficiency, stepped separately for light and dark.
    static let seriesBlue = dynamic(light: 0x2a78d6, dark: 0x3987e5)
    static let seriesOrange = dynamic(light: 0xeb6834, dark: 0xd95926)
    static let seriesAqua = dynamic(light: 0x1baf7a, dark: 0x199e70)

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        func color(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        }
    }

    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    static func numberLabel(size: CGFloat = 13, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        label.textColor = color
        label.alignment = .right
        return label
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func memory(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .memory)
    }

    static func count(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    /// "Updated 14:32 · 3 min ago". The time turns orange once the numbers are
    /// ten minutes old — with no auto-refresh, staleness is the thing to see.
    static func stamp(_ date: Date?, never: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12)
        guard let date else {
            return NSAttributedString(string: never, attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        let relative: String
        switch minutes {
        case ..<1: relative = "just now"
        case ..<60: relative = "\(minutes) min ago"
        default: relative = "\(minutes / 60) hr ago"
        }
        let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        let text = NSMutableAttributedString(string: "Updated ", attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor,
        ])
        text.append(NSAttributedString(string: time, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: minutes >= 10 ? NSColor.systemOrange : NSColor.labelColor,
        ]))
        text.append(NSAttributedString(string: " · \(relative)", attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return text
    }

    /// A small bordered button whose title is red — the destructive action at
    /// the end of a row.
    static func destructiveButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.systemRed,
        ])
        return button
    }

    static func protectedLabel(reason: String, text: String = "Protected") -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        icon.contentTintColor = .tertiaryLabelColor
        let stack = NSStackView(views: [icon, label(text, size: 11.5, color: .tertiaryLabelColor)])
        stack.spacing = 3
        stack.toolTip = reason
        return stack
    }
}

/// Rounded, filled background that re-resolves its color whenever the
/// appearance changes (a CGColor captured once would stay light in dark mode).
class FillView: NSView {
    var fillColor: NSColor {
        didSet { needsDisplay = true }
    }
    private let cornerRadius: CGFloat

    init(color: NSColor, cornerRadius: CGFloat) {
        fillColor = color
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is not used")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fillColor.cgColor
        }
    }
}

/// Tinted pill with a short label: "Rebuildable", "Normal", …
final class ChipView: FillView {
    private let label = DashboardStyle.label("", size: 10.5, weight: .medium)

    init(text: String, color: NSColor) {
        super.init(color: color.withAlphaComponent(0.16), cornerRadius: 5)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1.5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1.5),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        update(text: text, color: color)
    }

    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is not used")
    }

    func update(text: String, color: NSColor) {
        label.stringValue = text
        label.textColor = color
        fillColor = color.withAlphaComponent(0.16)
    }
}

/// Horizontal bar: a track with colored segments laid end to end.
final class BarView: NSView {
    struct Segment {
        let fraction: Double
        let color: NSColor
    }

    var segments: [Segment] = [] {
        didSet { needsDisplay = true }
    }
    /// Space left between adjacent segments, so neighbours read as separate.
    var segmentGap: CGFloat = 0
    private let thickness: CGFloat

    init(thickness: CGFloat) {
        self.thickness = thickness
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is not used")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: thickness)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: bounds.minX, y: bounds.midY - thickness / 2, width: bounds.width, height: thickness)
        let radius = thickness / 2
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()

        if segments.count == 1, let only = segments.first {
            let width = rect.width * CGFloat(min(max(only.fraction, 0), 1))
            guard width > 0 else { return }
            only.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: max(width, thickness), height: thickness),
                         xRadius: radius, yRadius: radius).fill()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        var x = rect.minX
        for segment in segments {
            let width = rect.width * CGFloat(min(max(segment.fraction, 0), 1))
            segment.color.setFill()
            NSRect(x: x, y: rect.minY, width: max(width - segmentGap, 0), height: thickness).fill()
            x += width
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Three steps — green, yellow, red — lit up to the current memory pressure.
final class PressureGaugeView: NSView {
    var pressure: MemoryPressure? {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is not used")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor] = [.systemGreen, .systemYellow, .systemRed]
        let gap: CGFloat = 3
        let width = (bounds.width - gap * 2) / 3
        let y = bounds.midY - 4
        for (step, color) in colors.enumerated() {
            let rect = NSRect(x: CGFloat(step) * (width + gap), y: y, width: width, height: 8)
            let lit = pressure.map { step <= $0.rawValue } ?? false
            (lit ? color : NSColor.quaternaryLabelColor).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
    }
}

/// Fills a panel's table area before there is anything to show: either the
/// "press to start" state or the in-progress state of a first run.
final class PlaceholderView: NSView {
    var onAction: (() -> Void)?
    var onStop: (() -> Void)?

    private let imageView = NSImageView()
    private let titleLabel = DashboardStyle.label("", size: 15, weight: .semibold)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let progressBar = NSProgressIndicator()
    private let countLabel = DashboardStyle.label("", size: 12, color: .secondaryLabelColor)
    private let pathLabel = DashboardStyle.label("", size: 11.5, color: .tertiaryLabelColor)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        imageView.symbolConfiguration = .init(pointSize: 40, weight: .light)
        imageView.contentTintColor = .tertiaryLabelColor
        messageLabel.font = .systemFont(ofSize: 12.5)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.preferredMaxLayoutWidth = 340
        actionButton.bezelColor = .controlAccentColor
        actionButton.keyEquivalent = "\r"
        actionButton.target = self
        actionButton.action = #selector(actionPressed)
        progressBar.style = .bar
        progressBar.isIndeterminate = true
        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        stopButton.target = self
        stopButton.action = #selector(stopPressed)

        let stack = NSStackView(views: [imageView, titleLabel, messageLabel, progressBar,
                                        countLabel, pathLabel, actionButton, stopButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -16),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            progressBar.widthAnchor.constraint(equalToConstant: 240),
            pathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is not used")
    }

    func showEmpty(symbol: String, title: String, message: String, actionTitle: String) {
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView.isHidden = false
        titleLabel.stringValue = title
        messageLabel.stringValue = message
        messageLabel.isHidden = false
        actionButton.title = actionTitle
        actionButton.isHidden = false
        progressBar.stopAnimation(nil)
        progressBar.isHidden = true
        countLabel.isHidden = true
        pathLabel.isHidden = true
        stopButton.isHidden = true
    }

    func showWorking(title: String, message: String?) {
        imageView.isHidden = true
        titleLabel.stringValue = title
        messageLabel.stringValue = message ?? ""
        messageLabel.isHidden = message == nil
        actionButton.isHidden = true
        progressBar.isHidden = false
        progressBar.startAnimation(nil)
        countLabel.isHidden = true
        pathLabel.isHidden = true
        stopButton.isHidden = false
    }

    func updateProgress(count: String, detail: String) {
        countLabel.stringValue = count
        countLabel.isHidden = false
        pathLabel.stringValue = detail
        pathLabel.isHidden = false
    }

    @objc private func actionPressed() { onAction?() }
    @objc private func stopPressed() { onStop?() }
}

/// The strip along the bottom of a panel: what the numbers are, and anything
/// that limited them.
final class StatusLine: NSView {
    var onLink: (() -> Void)?

    private let spinner = NSProgressIndicator()
    private let leftLabel = DashboardStyle.label("", size: 11.5, color: .secondaryLabelColor)
    private let rightLabel = DashboardStyle.label("", size: 11.5, color: .secondaryLabelColor)
    private let linkButton = NSButton(title: "", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        leftLabel.lineBreakMode = .byTruncatingMiddle
        leftLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        linkButton.isBordered = false
        linkButton.target = self
        linkButton.action = #selector(linkPressed)

        let left = NSStackView(views: [spinner, leftLabel])
        left.spacing = 6
        let right = NSStackView(views: [rightLabel, linkButton])
        right.spacing = 6
        for view in [separator, left, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is not used")
    }

    func update(left: String, spinning: Bool = false, right: String? = nil,
                rightIsWarning: Bool = false, link: String? = nil) {
        leftLabel.stringValue = left
        // Hidden, not just stopped — a stopped spinner still takes its width.
        spinner.isHidden = !spinning
        spinning ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        rightLabel.stringValue = right ?? ""
        rightLabel.textColor = rightIsWarning ? .systemOrange : .secondaryLabelColor
        rightLabel.isHidden = right == nil
        linkButton.isHidden = link == nil
        linkButton.attributedTitle = NSAttributedString(string: link ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.linkColor,
        ])
    }

    @objc private func linkPressed() { onLink?() }
}

/// Transient message floating above the status line, with an optional Undo.
final class ToastView: NSVisualEffectView {
    private let label = DashboardStyle.label("", size: 12.5, color: .white)
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private var undo: (() -> Void)?
    private var dismissal: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .vibrantDark)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.masksToBounds = true
        isHidden = true

        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        undoButton.controlSize = .small
        undoButton.target = self
        undoButton.action = #selector(undoPressed)

        let stack = NSStackView(views: [label, undoButton])
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is not used")
    }

    func show(_ message: String, undo: (() -> Void)? = nil) {
        dismissal?.cancel()
        label.stringValue = message
        self.undo = undo
        undoButton.isHidden = undo == nil
        isHidden = false
        alphaValue = 1
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func dismiss() {
        dismissal?.cancel()
        undo = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.isHidden = true })
    }

    @objc private func undoPressed() {
        let action = undo
        dismiss()
        action?()
    }
}

/// Table cell that vertically centers one content view, inset from the column
/// edges.
func centeredCell(_ content: NSView, alignment: NSLayoutConstraint.Attribute = .leading) -> NSView {
    let cell = NSView()
    content.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(content)
    var constraints = [content.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]
    switch alignment {
    case .trailing:
        constraints += [
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: cell.leadingAnchor),
        ]
    case .width:
        constraints += [
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        ]
    default:
        constraints += [
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
        ]
    }
    NSLayoutConstraint.activate(constraints)
    return cell
}

/// Icon, a bold-ish name with an optional chip, and a dimmer second line.
func nameCell(icon: NSImage, name: String, chip: ChipView?, detail: String, detailToolTip: String? = nil,
              iconTint: NSColor? = nil) -> NSView {
    let iconView = NSImageView(image: icon)
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.contentTintColor = iconTint
    iconView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        iconView.widthAnchor.constraint(equalToConstant: 26),
        iconView.heightAnchor.constraint(equalToConstant: 26),
    ])

    let nameLabel = DashboardStyle.label(name, weight: .medium)
    nameLabel.lineBreakMode = .byTruncatingTail
    nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    nameLabel.toolTip = name
    let top = NSStackView(views: [nameLabel] + (chip.map { [$0] } ?? []))
    top.spacing = 6

    let detailLabel = DashboardStyle.label(detail, size: 11.5, color: .tertiaryLabelColor)
    detailLabel.lineBreakMode = .byTruncatingMiddle
    detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    detailLabel.toolTip = detailToolTip

    let texts = NSStackView(views: [top, detailLabel])
    texts.orientation = .vertical
    texts.alignment = .leading
    texts.spacing = 2
    texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let row = NSStackView(views: [iconView, texts])
    row.spacing = 10
    return centeredCell(row)
}
