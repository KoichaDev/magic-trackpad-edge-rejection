import AppKit

// Original vector drawing, rasterized by AppKit at every macOS icon size.
// Regenerate with: swift scripts/generate-app-icon.swift Assets
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets", isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}
func shadowed(_ draw: () -> Void, blur: CGFloat, offset: NSSize, opacity: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur; shadow.shadowOffset = offset
    shadow.shadowColor = color(0x061B17, alpha: opacity)
    shadow.set(); draw()
    NSGraphicsContext.restoreGraphicsState()
}
func drawIcon() {
    let tile = rounded(NSRect(x: 84, y: 84, width: 856, height: 856), 180)
    shadowed({
        color(0x174E40).setFill(); tile.fill()
    }, blur: 26, offset: NSSize(width: 0, height: -13), opacity: 0.3)
    NSGradient(starting: color(0x123F38), ending: color(0x48A782))!.draw(in: tile, angle: 90)
    color(0xFFFFFF, alpha: 0.16).setStroke(); tile.lineWidth = 2; tile.stroke()

    let trackpad = rounded(NSRect(x: 180, y: 295, width: 664, height: 444), 58)
    shadowed({
        color(0xD5EADF).setFill(); trackpad.fill()
    }, blur: 18, offset: NSSize(width: 0, height: -12), opacity: 0.3)
    NSGradient(starting: color(0xACCFC1), ending: color(0xF5FFF8))!.draw(in: trackpad, angle: 90)
    color(0xFFFFFF, alpha: 0.75).setStroke(); trackpad.lineWidth = 3; trackpad.stroke()
    let margin = rounded(NSRect(x: 206, y: 321, width: 612, height: 392), 39)
    color(0x96C6B2).setFill(); margin.fill()
    let center = rounded(NSRect(x: 260, y: 369, width: 504, height: 296), 26)
    NSGradient(starting: color(0x16694F), ending: color(0x3BB881))!.draw(in: center, angle: 90)
    color(0xF4FFF5, alpha: 0.85).setStroke(); center.lineWidth = 3; center.stroke()

    // Raised palm, with four fingers and an angled thumb.
    color(0xF7FFF6).setFill()
    rounded(NSRect(x: 424, y: 402, width: 176, height: 156), 62).fill()
    for (x, y, width, height) in [
        (430.0, 507.0, 34.0, 106.0), (474.0, 507.0, 36.0, 136.0),
        (520.0, 507.0, 34.0, 115.0), (560.0, 492.0, 32.0, 93.0)
    ] { rounded(NSRect(x: x, y: y, width: width, height: height), width / 2).fill() }
    let thumb = NSBezierPath()
    thumb.move(to: NSPoint(x: 454, y: 415))
    thumb.curve(to: NSPoint(x: 411, y: 456), controlPoint1: NSPoint(x: 437, y: 419), controlPoint2: NSPoint(x: 421, y: 440))
    thumb.line(to: NSPoint(x: 390, y: 486))
    thumb.curve(to: NSPoint(x: 392, y: 508), controlPoint1: NSPoint(x: 380, y: 498), controlPoint2: NSPoint(x: 381, y: 508))
    thumb.curve(to: NSPoint(x: 415, y: 505), controlPoint1: NSPoint(x: 399, y: 514), controlPoint2: NSPoint(x: 409, y: 511))
    thumb.line(to: NSPoint(x: 441, y: 480)); thumb.line(to: NSPoint(x: 461, y: 473))
    thumb.close(); thumb.fill()

    let badge = NSBezierPath(ovalIn: NSRect(x: 660, y: 294, width: 152, height: 152))
    shadowed({
        color(0x114A3B).setFill(); badge.fill()
    }, blur: 10, offset: NSSize(width: 0, height: -4), opacity: 0.2)
    color(0xFFFFFF, alpha: 0.85).setStroke(); badge.lineWidth = 4; badge.stroke()
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 736, y: 420))
    shield.line(to: NSPoint(x: 780, y: 403)); shield.line(to: NSPoint(x: 776, y: 363))
    shield.curve(to: NSPoint(x: 736, y: 326), controlPoint1: NSPoint(x: 773, y: 347), controlPoint2: NSPoint(x: 752, y: 332))
    shield.curve(to: NSPoint(x: 696, y: 363), controlPoint1: NSPoint(x: 720, y: 332), controlPoint2: NSPoint(x: 699, y: 347))
    shield.line(to: NSPoint(x: 692, y: 403)); shield.close()
    color(0xF4FFF3).setFill(); shield.fill()
    let check = NSBezierPath()
    check.move(to: NSPoint(x: 714, y: 371)); check.line(to: NSPoint(x: 730, y: 355))
    check.line(to: NSPoint(x: 759, y: 389)); check.lineWidth = 11
    check.lineCapStyle = .round; check.lineJoinStyle = .round
    color(0x23805A).setStroke(); check.stroke()
}
func png(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.cgContext.setShouldAntialias(true)
    let scale = CGFloat(size) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let file = iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png")
        try png(size: base * scale).write(to: file, options: .atomic)
    }
}
try png(size: 1024).write(to: output.appendingPathComponent("AppIcon.png"), options: .atomic)
let converter = Process()
converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
converter.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try converter.run(); converter.waitUntilExit()
guard converter.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Saved AppIcon.png, AppIcon.icns, and AppIcon.iconset to \(output.path)")
