#!/usr/bin/env bash
# Renders Assets/AppIcon.svg into MiddleShot/AppIcon.icns (every size macOS
# asks for). Uses only what ships with macOS + Xcode: AppKit draws the SVG,
# iconutil packs the set. Run again after changing the SVG; the .icns is
# checked in so build.sh never needs to render.
set -euo pipefail
cd "$(dirname "$0")/.."

SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

swift - "$SET" <<'SWIFT'
import AppKit
let out = CommandLine.arguments[1]
guard let svg = NSImage(contentsOfFile: "Assets/AppIcon.svg") else { fatalError("Can't read Assets/AppIcon.svg") }
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    svg.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
SWIFT

iconutil -c icns "$SET" -o MiddleShot/AppIcon.icns
cp "$SET/icon_512x512@2x.png" Assets/AppIcon-1024.png
echo "Wrote MiddleShot/AppIcon.icns"
