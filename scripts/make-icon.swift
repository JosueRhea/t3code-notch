// Renders Resources/AppIcon.icns: a dark squircle with the notch and its three "working" dots.
// Run: swift scripts/make-icon.swift   (needs iconutil, ships with macOS)
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Body: macOS icon grid keeps ~10% margin; warm-to-dusk gradient like the wallpaper it sits on.
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.98, green: 0.58, blue: 0.38, alpha: 1),
                        NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.62, alpha: 1)])!
        .draw(in: squircle, angle: -90)

    // The notch: hangs from the top edge, flares at the top corners, rounded at the bottom.
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    let w = body.width * 0.62, h = body.height * 0.26, t = body.width * 0.06, b = body.width * 0.1
    let x0 = body.midX - w / 2, top = body.maxY, y1 = top - h
    let notch = NSBezierPath()
    notch.move(to: NSPoint(x: x0, y: top))
    notch.curve(to: NSPoint(x: x0 + t, y: top - t), controlPoint1: NSPoint(x: x0 + t, y: top), controlPoint2: NSPoint(x: x0 + t, y: top))
    notch.line(to: NSPoint(x: x0 + t, y: y1 + b))
    notch.curve(to: NSPoint(x: x0 + t + b, y: y1), controlPoint1: NSPoint(x: x0 + t, y: y1), controlPoint2: NSPoint(x: x0 + t, y: y1))
    notch.line(to: NSPoint(x: x0 + w - t - b, y: y1))
    notch.curve(to: NSPoint(x: x0 + w - t, y: y1 + b), controlPoint1: NSPoint(x: x0 + w - t, y: y1), controlPoint2: NSPoint(x: x0 + w - t, y: y1))
    notch.line(to: NSPoint(x: x0 + w - t, y: top - t))
    notch.curve(to: NSPoint(x: x0 + w, y: top), controlPoint1: NSPoint(x: x0 + w - t, y: top), controlPoint2: NSPoint(x: x0 + w - t, y: top))
    notch.close()
    NSColor.black.setFill()
    notch.fill()

    // Three dots mid-bounce.
    let r = body.width * 0.035, gap = r * 3.2, cy = y1 + h * 0.42
    let sky = NSColor(calibratedRed: 0.49, green: 0.83, blue: 0.99, alpha: 1)
    for (i, lift) in [0.0, 0.6, 0.2].enumerated() {
        let cx = body.midX + CGFloat(i - 1) * gap
        sky.withAlphaComponent(0.55 + 0.45 * lift).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r + CGFloat(lift) * r, width: r * 2, height: r * 2)).fill()
    }
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try render(512).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-preview.png"))
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
