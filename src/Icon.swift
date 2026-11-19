import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
var encodedSizes: [Int: Data] = [:]
for (name, size) in variants {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let shape = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 222, yRadius: 222)
    NSGradient(starting: NSColor(srgbRed: 0.19, green: 0.38, blue: 0.90, alpha: 1), ending: NSColor(srgbRed: 0.42, green: 0.23, blue: 0.77, alpha: 1))!.draw(in: shape, angle: 60)
    let arrow = NSBezierPath()
    arrow.lineWidth = 74
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 292, y: 633))
    arrow.line(to: NSPoint(x: 744, y: 633))
    arrow.move(to: NSPoint(x: 644, y: 733))
    arrow.line(to: NSPoint(x: 744, y: 633))
    arrow.line(to: NSPoint(x: 644, y: 533))
    arrow.move(to: NSPoint(x: 732, y: 391))
    arrow.line(to: NSPoint(x: 280, y: 391))
    arrow.move(to: NSPoint(x: 380, y: 491))
    arrow.line(to: NSPoint(x: 280, y: 391))
    arrow.line(to: NSPoint(x: 380, y: 291))
    NSColor.white.setStroke()
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    encodedSizes[size] = png
    try png.write(to: directory.appendingPathComponent(name))
}
if CommandLine.arguments.count > 2 {
    func bigEndian(_ value: Int) -> Data {
        var number = UInt32(value).bigEndian
        return withUnsafeBytes(of: &number) { Data($0) }
    }
    var chunks = Data()
    for (type, size) in [("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
        let png = encodedSizes[size]!
        chunks.append(Data(type.utf8))
        chunks.append(bigEndian(png.count + 8))
        chunks.append(png)
    }
    var icon = Data("icns".utf8)
    icon.append(bigEndian(chunks.count + 8))
    icon.append(chunks)
    try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
