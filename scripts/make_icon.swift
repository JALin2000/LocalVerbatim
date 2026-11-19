import AppKit

// Original geometric artwork for LocalVerbatim. No fonts, SF Symbols, downloaded
// illustrations, or third-party marks are embedded. Rebuilds every icon size
// directly from these paths, so the editable source remains in the project.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift make_icon.swift OUTPUT_DIRECTORY")
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = destination.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func render(_ size: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    let c = graphics.cgContext
    let scale = CGFloat(size) / 1024
    c.translateBy(x: 0, y: CGFloat(size)); c.scaleBy(x: scale, y: -scale)
    c.setShouldAntialias(true)
    func fill(_ path: CGPath, _ hex: UInt32, alpha: CGFloat = 1) {
        c.setFillColor(color(hex, alpha: alpha)); c.addPath(path); c.fillPath()
    }
    func gradient(_ path: CGPath, _ colors: [UInt32], from: CGPoint, to: CGPoint) {
        c.saveGState(); c.addPath(path); c.clip()
        let values = colors.map { color($0) } as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: values, locations: [0, 1])!
        c.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }
    let tile = rounded(CGRect(x: 48, y: 48, width: 928, height: 928), 216)
    gradient(tile, [0xF7FAF4, 0xE0EFE5], from: CGPoint(x: 230, y: 60), to: CGPoint(x: 830, y: 970))
    c.setStrokeColor(color(0xFFFFFF, alpha: 0.82)); c.setLineWidth(3); c.addPath(tile); c.strokePath()

    // A quiet second sheet suggests separate audio sources and saved notes.
    let back = rounded(CGRect(x: 271, y: 190, width: 565, height: 634), 118)
    gradient(back, [0xBEDDCA, 0x91C2AC], from: CGPoint(x: 300, y: 190), to: CGPoint(x: 835, y: 825))
    let front = rounded(CGRect(x: 183, y: 235, width: 600, height: 620), 122)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x123E33, alpha: 0.17))
    fill(front, 0x206B59)
    c.restoreGState()
    gradient(front, [0x2C8069, 0x185747], from: CGPoint(x: 210, y: 245), to: CGPoint(x: 755, y: 840))
    c.setStrokeColor(color(0xF5FFF5, alpha: 0.19)); c.setLineWidth(3); c.addPath(front); c.strokePath()

    let heights: [CGFloat] = [92, 178, 240, 146, 100]
    for (index, height) in heights.enumerated() {
        fill(rounded(CGRect(x: 313 + CGFloat(index) * 72, y: 470 - height / 2,
                            width: 40, height: height), 20), 0xF7FCF4)
    }
    fill(rounded(CGRect(x: 303, y: 662, width: 360, height: 30), 15), 0xF7FCF4)
    fill(rounded(CGRect(x: 303, y: 726, width: 240, height: 30), 15), 0xAEDBC6)
    return bitmap
}
func writePNG(_ size: Int, _ url: URL) throws {
    try render(size).representation(using: .png, properties: [:])!.write(to: url)
}
for points in [16, 32, 128, 256, 512] {
    try writePNG(points, iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try writePNG(points * 2, iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try writePNG(1024, destination.appendingPathComponent("AppIcon.png"))
try writePNG(256, destination.appendingPathComponent("AppIcon-preview.png"))
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" role="img" aria-label="LocalVerbatim original app icon">
<!-- Original LocalVerbatim geometric artwork. No external assets or font glyphs. -->
<defs>
 <linearGradient id="tile" gradientUnits="userSpaceOnUse" x1="230" y1="60" x2="830" y2="970"><stop stop-color="#F7FAF4"/><stop offset="1" stop-color="#E0EFE5"/></linearGradient>
 <linearGradient id="back" gradientUnits="userSpaceOnUse" x1="300" y1="190" x2="835" y2="825"><stop stop-color="#BEDDCA"/><stop offset="1" stop-color="#91C2AC"/></linearGradient>
 <linearGradient id="front" gradientUnits="userSpaceOnUse" x1="210" y1="245" x2="755" y2="840"><stop stop-color="#2C8069"/><stop offset="1" stop-color="#185747"/></linearGradient>
 <filter id="shadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#123E33" flood-opacity=".17"/></filter>
</defs>
<rect x="48" y="48" width="928" height="928" rx="216" fill="url(#tile)" stroke="#fff" stroke-opacity=".82" stroke-width="3"/>
<rect x="271" y="190" width="565" height="634" rx="118" fill="url(#back)"/>
<rect x="183" y="235" width="600" height="620" rx="122" fill="url(#front)" stroke="#F5FFF5" stroke-opacity=".19" stroke-width="3" filter="url(#shadow)"/>
<g fill="#F7FCF4">
 <rect x="313" y="424" width="40" height="92" rx="20"/>
 <rect x="385" y="381" width="40" height="178" rx="20"/>
 <rect x="457" y="350" width="40" height="240" rx="20"/>
 <rect x="529" y="397" width="40" height="146" rx="20"/>
 <rect x="601" y="420" width="40" height="100" rx="20"/>
 <rect x="303" y="662" width="360" height="30" rx="15"/>
</g>
<rect x="303" y="726" width="240" height="30" rx="15" fill="#AEDBC6"/>
</svg>
"""
try svg.write(to: destination.appendingPathComponent("AppIcon.svg"), atomically: true, encoding: .utf8)
print("Rendered original LocalVerbatim icon at 16–1024 pixels in \(destination.path)")
