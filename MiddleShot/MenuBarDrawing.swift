import Cocoa

enum MenuBarStatsStyle: String, CaseIterable {
    case graphsAndNumbers = "classic"
    case numbers = "compact"
    case graphs

    var title: String {
        switch self {
        case .graphsAndNumbers: return "Graphs & Numbers"
        case .numbers: return "Numbers Only"
        case .graphs: return "Icons Only"
        }
    }
}

/// One module's slice of the menu bar image.
///
/// The width is fixed for a given style — measured against the widest value the
/// module can show — so "4 KB/s" turning into "12.5 MB/s" never shoves the
/// neighbouring menu bar icons around.
struct MenuBarPart {
    let width: CGFloat
    /// Everything that decides how the part looks (rounded to what a pixel can
    /// show). Two ticks with the same keys skip the redraw entirely.
    let key: String
    /// Draws at horizontal offset `x`, in a context `MenuBarDrawing.height` tall.
    let draw: (_ x: CGFloat) -> Void
}

/// The shared geometry, colors and primitives modules draw their parts with.
enum MenuBarDrawing {
    static let height: CGFloat = 22
    static let partGap: CGFloat = 11
    /// Every icon, graph and line of text shares this one vertical band: icon
    /// tops and capital tops meet `bandTop`; icon bottoms and the lowest
    /// baselines meet `bandBottom`.
    static let bandBottom: CGFloat = 2.5
    static let bandTop: CGFloat = 19.5
    static var bandHeight: CGFloat { bandTop - bandBottom }
    /// Width taken by a stacked "M / E / M" label plus its gap.
    static let verticalLabelWidth: CGFloat = 8

    static let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    static let captionFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    static let numberLabelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    /// Lays the parts out left to right into one bitmap, drawn once.
    ///
    /// A drawing-handler image would be cheaper to create but AppKit re-runs the
    /// handler on every redraw of the status button, and text layout is the
    /// costly part of a frame; a bitmap makes each redraw a plain copy. The
    /// price is that colors are resolved now, so the caller redraws when the
    /// menu bar's appearance changes.
    static func image(parts: [MenuBarPart], color: Bool, appearance: NSAppearance, scale: CGFloat) -> NSImage {
        let width = parts.reduce(0) { $0 + $1.width } + partGap * CGFloat(max(parts.count - 1, 0))
        let size = NSSize(width: ceil(max(width, 1)), height: height)
        let image = NSImage(size: size)
        if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) {
            // The point size has to be on the rep *before* the context is made:
            // the context takes its unit from the rep's size as it stands then,
            // so setting it afterwards leaves 1 unit = 1 pixel and the whole
            // image is drawn at half size in the bottom-left of a 2x bitmap.
            bitmap.size = size
            if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                appearance.performAsCurrentDrawingAppearance {
                    var x: CGFloat = 0
                    for part in parts {
                        part.draw(x)
                        x += part.width + partGap
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
                image.addRepresentation(bitmap)
            }
        }
        // Monochrome is a template image, so macOS tints it exactly like its own
        // icons (including the highlighted state while the menu is open).
        image.isTemplate = !color
        return image
    }

    /// A bar height rounded to the half point a Retina pixel can show.
    static func pixelKey(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * Double(bandHeight) * 2).rounded())
    }

    // MARK: - Colors

    static func ink(_ color: Bool) -> NSColor { color ? .labelColor : .black }
    static func track(_ color: Bool) -> NSColor {
        color ? NSColor.labelColor.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.22)
    }
    /// `tint` when colored; plain ink in a template image.
    static func fill(_ tint: NSColor, color: Bool) -> NSColor { color ? tint : .black }

    // MARK: - Formatting

    static func rate(_ bytesPerSecond: Double) -> String {
        let kilobytes = bytesPerSecond / 1024
        if kilobytes < 999.5 { return "\(Int(kilobytes.rounded())) KB/s" }
        let megabytes = kilobytes / 1024
        return megabytes < 99.95 ? String(format: "%.1f MB/s", megabytes) : String(format: "%.0f MB/s", megabytes)
    }

    static func shortRate(_ bytesPerSecond: Double) -> String {
        let kilobytes = bytesPerSecond / 1024
        if kilobytes < 999.5 { return "\(Int(kilobytes.rounded()))K" }
        let megabytes = kilobytes / 1024
        return megabytes < 99.95 ? String(format: "%.1fM", megabytes) : String(format: "%.0fM", megabytes)
    }

    static let widestRates = ["999 KB/s", "99.9 MB/s", "999 MB/s"]
    static let widestShortRates = ["999K", "99.9M", "999M"]

    /// Free space in Finder's decimal units: "850 MB", "37.1 GB", "437 GB", "1.2 TB".
    static func freeSpace(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        switch gigabytes {
        case ..<1: return "\(Int((gigabytes * 1000).rounded())) MB"
        case ..<99.95: return String(format: "%.1f GB", gigabytes)
        case ..<999.5: return String(format: "%.0f GB", gigabytes)
        default: return String(format: "%.1f TB", gigabytes / 1000)
        }
    }

    static func shortFree(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        switch gigabytes {
        case ..<9.95: return String(format: "%.1fG", gigabytes)
        case ..<999.5: return String(format: "%.0fG", gigabytes)
        default: return String(format: "%.1fT", gigabytes / 1000)
        }
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    // MARK: - Ready-made parts

    /// "CPU 42%": label and value in one size, so every letter is as tall as
    /// the next. The value is right-aligned in room for the widest `widest`.
    static func numberPart(label: String, value: String, widest: [String], color: Bool) -> MenuBarPart {
        let labelWidth = maxWidth(of: [label], font: numberLabelFont)
        let valueWidth = maxWidth(of: widest, font: numberFont)
        return MenuBarPart(width: labelWidth + 4 + valueWidth, key: label + value) { x in
            let baseline = centeredBaseline(for: numberFont)
            drawText(label, x: x, baseline: baseline, font: numberLabelFont, color: ink(color).withAlphaComponent(0.7))
            drawText(value, right: x + labelWidth + 4 + valueWidth, baseline: baseline, font: numberFont, color: ink(color))
        }
    }

    /// Up/down arrows beside two right-aligned lines (network rates, disk I/O).
    static func arrowsAndTwoLines(top: String, bottom: String, widest: [String], color: Bool) -> MenuBarPart {
        let textWidth = maxWidth(of: widest, font: smallFont)
        return MenuBarPart(width: 7 + 3 + textWidth, key: top + "|" + bottom) { x in
            // Each arrow is exactly as tall as the capitals on its line.
            let upBottom = bandTop - smallFont.capHeight, downTop = bandBottom + smallFont.capHeight
            let arrows = NSBezierPath()
            arrows.lineWidth = 1.2
            arrows.lineCapStyle = .round
            arrows.lineJoinStyle = .round
            arrows.move(to: NSPoint(x: x + 3.5, y: upBottom)); arrows.line(to: NSPoint(x: x + 3.5, y: bandTop))
            arrows.move(to: NSPoint(x: x + 1, y: bandTop - 2.5)); arrows.line(to: NSPoint(x: x + 3.5, y: bandTop))
            arrows.line(to: NSPoint(x: x + 6, y: bandTop - 2.5))
            arrows.move(to: NSPoint(x: x + 3.5, y: downTop)); arrows.line(to: NSPoint(x: x + 3.5, y: bandBottom))
            arrows.move(to: NSPoint(x: x + 1, y: bandBottom + 2.5)); arrows.line(to: NSPoint(x: x + 3.5, y: bandBottom))
            arrows.line(to: NSPoint(x: x + 6, y: bandBottom + 2.5))
            ink(color).setStroke()
            arrows.stroke()

            let right = x + 10 + textWidth
            drawText(top, right: right, baseline: upBottom, font: smallFont, color: ink(color))
            drawText(bottom, right: right, baseline: bandBottom, font: smallFont, color: ink(color))
        }
    }

    /// A ring with a pie wedge for `fraction`, the ring's outer edge on the band.
    static func drawPie(fraction: Double, x: CGFloat, tint: NSColor, color: Bool) {
        let radius = bandHeight / 2
        let center = NSPoint(x: x + radius, y: bandBottom + radius)
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius + 0.55, y: center.y - radius + 0.55,
                                               width: bandHeight - 1.1, height: bandHeight - 1.1))
        ring.lineWidth = 1.1
        ink(color).setStroke()
        ring.stroke()
        guard fraction > 0 else { return }
        let wedge = NSBezierPath()
        if fraction >= 0.999 {
            wedge.appendOval(in: NSRect(x: center.x - radius + 2.2, y: center.y - radius + 2.2,
                                        width: bandHeight - 4.4, height: bandHeight - 4.4))
        } else {
            wedge.move(to: center)
            wedge.appendArc(withCenter: center, radius: radius - 2.2, startAngle: 90,
                            endAngle: 90 - 360 * CGFloat(fraction), clockwise: true)
            wedge.close()
        }
        fill(tint, color: color).setFill()
        wedge.fill()
    }

    static let historyBarCount = 10
    static var historyBarsWidth: CGFloat { CGFloat(historyBarCount) * 3.6 - 1 }

    /// The last ten values (0…1) as bars, oldest first, each on its own track.
    static func drawHistoryBars(_ values: [Double], x: CGFloat, tint: NSColor, color: Bool) {
        let tail = values.suffix(historyBarCount)
        let bars = Array(repeating: 0, count: historyBarCount - tail.count) + tail
        for (index, value) in bars.enumerated() {
            let barX = x + CGFloat(index) * 3.6
            track(color).setFill()
            NSBezierPath(roundedRect: NSRect(x: barX, y: bandBottom, width: 2.6, height: bandHeight),
                         xRadius: 0.6, yRadius: 0.6).fill()
            fill(tint, color: color).setFill()
            NSBezierPath(roundedRect: NSRect(x: barX, y: bandBottom, width: 2.6,
                                             height: max(1, bandHeight * CGFloat(min(max(value, 0), 1)))),
                         xRadius: 0.6, yRadius: 0.6).fill()
        }
    }

    /// A 6 pt wide level gauge filling from the bottom (disk capacity, battery).
    static func drawLevelBar(fraction: Double, x: CGFloat, tint: NSColor, color: Bool) {
        track(color).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: bandBottom, width: 6, height: bandHeight), xRadius: 1.2, yRadius: 1.2).fill()
        fill(tint, color: color).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: bandBottom, width: 6,
                                         height: max(1, bandHeight * CGFloat(min(max(fraction, 0), 1)))),
                     xRadius: 1.2, yRadius: 1.2).fill()
    }

    // MARK: - Text

    static func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static var widestCache: [String: CGFloat] = [:]

    /// The widest of `texts` — the fixed room a changing value is given.
    /// Measured once per font and list; every tick asks again.
    static func maxWidth(of texts: [String], font: NSFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)|" + texts.joined(separator: "\u{1f}")
        if let cached = widestCache[key] { return cached }
        let measured = texts.map { width(of: $0, font: font) }.max() ?? 0
        widestCache[key] = measured
        return measured
    }

    /// Draws `text` with its baseline at `baseline`, starting at `x` or ending
    /// at `right`. `draw(at:)` takes the line box's bottom, a descender below
    /// the baseline.
    static func drawText(_ text: String, x: CGFloat? = nil, right: CGFloat? = nil, baseline: CGFloat,
                         font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = text as NSString
        let originX = right.map { $0 - string.size(withAttributes: attributes).width } ?? x ?? 0
        string.draw(at: NSPoint(x: originX, y: baseline + font.descender), withAttributes: attributes)
    }

    /// The baseline that centres capital letters in the band.
    static func centeredBaseline(for font: NSFont) -> CGFloat {
        bandBottom + (bandHeight - font.capHeight) / 2
    }

    /// "M / E / M" stacked in a 6 pt column, like iStat Menus' labels: the top
    /// letter's cap meets the band's top, the bottom letter sits on its floor.
    static func drawVerticalLabel(_ text: String, x: CGFloat, color: Bool) {
        let font = NSFont.systemFont(ofSize: 7, weight: .bold)
        let letters = Array(text)
        let pitch = (bandHeight - font.capHeight) / CGFloat(max(letters.count - 1, 1))
        for (index, letter) in letters.enumerated() {
            let glyph = String(letter)
            let glyphWidth = (glyph as NSString).size(withAttributes: [.font: font]).width
            drawText(glyph, x: x + (6 - glyphWidth) / 2, baseline: bandTop - font.capHeight - pitch * CGFloat(index),
                     font: font, color: ink(color))
        }
    }
}
