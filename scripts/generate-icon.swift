import AppKit

// Original vector artwork, rendered with AppKit. No external assets or runtime dependency.
let output = CommandLine.arguments.dropFirst().first ?? "Resources"
let root = URL(fileURLWithPath: output, isDirectory: true)
let iconset = root.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func drawIcon(pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let silhouette = NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 204, yRadius: 204)
    NSGradient(starting: NSColor(srgbRed: 0.09, green: 0.19, blue: 0.35, alpha: 1),
               ending: NSColor(srgbRed: 0.025, green: 0.065, blue: 0.15, alpha: 1))!.draw(in: silhouette, angle: -55)
    NSColor(white: 1, alpha: 0.12).setStroke()
    silhouette.lineWidth = 3; silhouette.stroke()
    let current = NSBezierPath()
    current.move(to: NSPoint(x: 340, y: 278))
    current.line(to: NSPoint(x: 340, y: 746))
    current.lineWidth = 62; current.lineCapStyle = .round
    NSColor(srgbRed: 0.30, green: 0.78, blue: 0.96, alpha: 1).setStroke(); current.stroke()
    let incoming = NSBezierPath()
    incoming.move(to: NSPoint(x: 692, y: 746))
    incoming.curve(to: NSPoint(x: 340, y: 406), controlPoint1: NSPoint(x: 692, y: 478), controlPoint2: NSPoint(x: 340, y: 630))
    incoming.lineWidth = 62; incoming.lineCapStyle = .round
    NSColor(srgbRed: 0.57, green: 0.91, blue: 0.73, alpha: 1).setStroke(); incoming.stroke()
    for point in [NSPoint(x: 340, y: 278), NSPoint(x: 340, y: 746), NSPoint(x: 692, y: 746)] {
        NSColor(srgbRed: 0.92, green: 0.97, blue: 1, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 82, y: point.y - 82, width: 164, height: 164)).fill()
        NSColor(srgbRed: 0.07, green: 0.16, blue: 0.29, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 34, y: point.y - 34, width: 68, height: 68)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let data = try drawIcon(pixels: size * scale)
        try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        if size == 512 && scale == 2 { try data.write(to: root.appendingPathComponent("AppIcon-1024.png")) }
    }
}
