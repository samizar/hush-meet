import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let folder = root.appendingPathComponent("build/Hush.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (size, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = size * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let width = CGFloat(pixels)
    let box = NSRect(x: width * 0.08, y: width * 0.08, width: width * 0.84, height: width * 0.84)
    NSColor(red: 247/255, green: 245/255, blue: 240/255, alpha: 1).setFill()
    NSBezierPath(roundedRect: box, xRadius: width * 0.18, yRadius: width * 0.18).fill()
    NSColor(red: 26/255, green: 25/255, blue: 22/255, alpha: 1).setStroke()
    let circle = NSBezierPath(ovalIn: NSRect(x: width * 0.32, y: width * 0.32, width: width * 0.36, height: width * 0.36))
    circle.lineWidth = max(1, width * 0.022); circle.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
}
