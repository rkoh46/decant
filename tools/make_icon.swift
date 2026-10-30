// Renders the Decant app icon into an .iconset: one flat graphite tile, one white glyph (a phone handing its
// contents forward). No gradient tile, no glow: a flat mark in one solid colour.
// Usage: swift tools/make_icon.swift Decant.iconset
import AppKit

let outDir = CommandLine.arguments[1]

func render(_ px: Int) -> Data {
    let size = NSSize(width: px, height: px)
    let image = NSImage(size: size)
    image.lockFocus()
    let inset = CGFloat(px) * 0.09              // macOS icons sit inside a margin
    let rect = NSRect(x: inset, y: inset, width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset)
    let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
    tile.fill()
    // A single hairline on the edge reads as a machined surface without becoming a glow.
    NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
    tile.lineWidth = max(1, CGFloat(px) / 256)
    tile.stroke()
    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.5, weight: .regular)
    if let symbol = NSImage(systemSymbolName: "iphone.and.arrow.forward", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor(calibratedWhite: 0.95, alpha: 1).set()
            r.fill(using: .sourceAtop)
            return true
        }
        let s = tinted.size
        tinted.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
    }
    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
