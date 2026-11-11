// Renders the Tuck app icon into an .iconset and converts it with iconutil.
// Usage: swift Tools/make_icon.swift Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = s / 1024

    // macOS icon grid: 824pt squircle centered in 1024 canvas.
    let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let path = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24 * k
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Monochrome: graphite → black, white glyphs.
    NSGradient(colors: [NSColor(white: 0.24, alpha: 1), NSColor(white: 0.04, alpha: 1)])!
        .draw(in: path, angle: -90)

    // Menu bar strip across the top of the squircle.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSColor.white.withAlphaComponent(0.12).setFill()
    NSRect(x: body.minX, y: body.maxY - 150 * k, width: body.width, height: 150 * k).fill()
    // Hidden-icon dots + chevron in the strip.
    NSColor.white.withAlphaComponent(0.9).setFill()
    for i in 0..<3 {
        let x = body.minX + 470 * k + CGFloat(i) * 70 * k
        NSBezierPath(ovalIn: NSRect(x: x, y: body.maxY - 95 * k, width: 40 * k, height: 40 * k)).fill()
    }
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: body.minX + 420 * k, y: body.maxY - 50 * k))
    chevron.line(to: NSPoint(x: body.minX + 385 * k, y: body.maxY - 75 * k))
    chevron.line(to: NSPoint(x: body.minX + 420 * k, y: body.maxY - 100 * k))
    chevron.lineWidth = 14 * k
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    NSColor.white.setStroke()
    chevron.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Tray symbol.
    let cfg = NSImage.SymbolConfiguration(pointSize: 380 * k, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let sz = sym.size
        sym.draw(in: NSRect(x: (s - sz.width) / 2, y: body.minY + (body.height - 150 * k - sz.height) / 2,
                            width: sz.width, height: sz.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try? fm.createDirectory(at: URL(fileURLWithPath: out).deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run()
p.waitUntilExit()
try! render(1024).write(to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("png"))
print(p.terminationStatus == 0 ? "Wrote \(out)" : "iconutil failed")
