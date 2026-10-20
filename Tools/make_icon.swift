// Génère Resources/AppIcon.icns : swift Tools/make_icon.swift <dossier-temporaire>
import AppKit

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowBlurRadius = 24 * s; shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.set()
    NSColor.black.setFill(); path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 1.0, green: 0.52, blue: 0.32, alpha: 1), NSColor(srgbRed: 0.84, green: 0.20, blue: 0.47, alpha: 1)])!
        .draw(in: path, angle: -55)
    // Trois tirettes de console, à des hauteurs différentes.
    let xs: [CGFloat] = [330, 512, 694], knobs: [CGFloat] = [610, 380, 520]
    for (x, k) in zip(xs, knobs) {
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: NSRect(x: (x - 18) * s, y: 270 * s, width: 36 * s, height: 484 * s), xRadius: 18 * s, yRadius: 18 * s).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: (x - 18) * s, y: 270 * s, width: 36 * s, height: (k - 270) * s), xRadius: 18 * s, yRadius: 18 * s).fill()
        NSBezierPath(roundedRect: NSRect(x: (x - 68) * s, y: (k - 40) * s, width: 136 * s, height: 80 * s), xRadius: 28 * s, yRadius: 28 * s).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(base * scale).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }
}
