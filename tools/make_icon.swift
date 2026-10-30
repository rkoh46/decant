// Renders the Offload app icon (blue gradient tile with the iPhone-and-arrow symbol) into an .iconset.
// Usage: swift tools/make_icon.swift Offload.iconset
import AppKit

let outDir = CommandLine.arguments[1]

func render(_ px: Int) -> Data {
    let size = NSSize(width: px, height: px)
    let image = NSImage(size: size)
    image.lockFocus()
    let inset = CGFloat(px) * 0.09              // macOS icons sit inside a margin
    let rect = NSRect(x: inset, y: inset, width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.00, alpha: 1),
               ending: NSColor(calibratedRed: 0.28, green: 0.22, blue: 0.85, alpha: 1))!
        .draw(in: path, angle: -60)
    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.52, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "iphone.and.arrow.forward", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.white.set()
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
