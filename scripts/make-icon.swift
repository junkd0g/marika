// Typesets the selected rounded M icon using the macOS system font.
// Run from the repository root: swift scripts/make-icon.swift
import AppKit
import CoreText

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let descriptor = NSFont.systemFont(ofSize: 100, weight: .bold).fontDescriptor.withDesign(.rounded)!
let font = NSFont(descriptor: descriptor, size: 100)!
let ctFont = font as CTFont
var character: UniChar = 77
var glyph = CGGlyph()
guard CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1),
      let original = CTFontCreatePathForGlyph(ctFont, glyph, nil) else {
    fatalError("Cannot load the M letterform")
}
let bounds = original.boundingBoxOfPath
let letterScale = min(545 / bounds.width, 570 / bounds.height)
var placement = CGAffineTransform(a: letterScale, b: 0, c: 0, d: letterScale,
                                 tx: 512 - bounds.midX * letterScale, ty: 512 - bounds.midY * letterScale + 4)
let monogram = original.copy(using: &placement)!
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let outline = CGPath(roundedRect: tile, cornerWidth: 184, cornerHeight: 184, transform: nil)

func render(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.addPath(outline)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()
    context.addPath(outline)
    context.setStrokeColor(NSColor.black.withAlphaComponent(0.07).cgColor)
    context.setLineWidth(1)
    context.strokePath()
    context.addPath(monogram)
    context.setFillColor(NSColor(srgbRed: 0.07, green: 0.07, blue: 0.07, alpha: 1).cgColor)
    context.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

// Keep an editable, font-independent vector source alongside the packaged icon.
var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1024)
let svgGlyph = monogram.copy(using: &flip)!
var commands: [String] = []
func point(_ point: CGPoint) -> String { String(format: "%.3f %.3f", point.x, point.y) }
svgGlyph.applyWithBlock { element in
    let item = element.pointee
    switch item.type {
    case .moveToPoint: commands.append("M " + point(item.points[0]))
    case .addLineToPoint: commands.append("L " + point(item.points[0]))
    case .addQuadCurveToPoint: commands.append("Q " + point(item.points[0]) + " " + point(item.points[1]))
    case .addCurveToPoint: commands.append("C " + point(item.points[0]) + " " + point(item.points[1]) + " " + point(item.points[2]))
    case .closeSubpath: commands.append("Z")
    @unknown default: break
    }
}
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <title>Marika — rounded M</title>
  <rect x="100" y="100" width="824" height="824" rx="184" fill="white" stroke="#ededed"/>
  <path d="\(commands.joined(separator: " "))" fill="#121212"/>
</svg>
"""
try svg.write(to: root.appendingPathComponent("Resources/AppIcon-source.svg"), atomically: true, encoding: .utf8)
try render(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon-source.png"))
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Marika-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try render(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed: \(task.terminationStatus)") }
try render(size: 512).write(to: root.appendingPathComponent("Resources/AppIcon-preview.png"))
print("Wrote typographic M icon using \(font.fontName), plus vector source and all macOS sizes.")
