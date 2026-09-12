import AppKit

// Собственный геометрический знак: три независимых остатка лимитов.
// Рисуется локально; не содержит логотипов провайдеров.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (name, pixels) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 192, yRadius: 192).fill()
    for (index, width) in [536.0, 352.0, 432.0].enumerated() {
        let y = 636.0 - Double(index) * 160
        NSColor.white.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: NSRect(x: 244, y: y, width: 536, height: 80), xRadius: 40, yRadius: 40).fill()
        NSColor(calibratedRed: 0.61, green: 0.88, blue: 0.80, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 244, y: y, width: width, height: 80), xRadius: 40, yRadius: 40).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
}
