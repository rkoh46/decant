// Renders Decant's Windows icon from the same flat mark as the Mac icon: one graphite tile, one white glyph.
// Windows icons fill their square (a 4 % margin instead of macOS's 9 %). Also writes the top-bar mark as a plain
// glyph in two tones, since XAML cannot recolour a bitmap the way SwiftUI tints a symbol.
// Usage: swift tools/make_icon_windows.swift windows/Decant/Assets
import AppKit

let outDir = CommandLine.arguments[1]

func png(_ image: NSImage) -> Data {
    NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
}

func symbol(_ name: String, points: CGFloat, white: CGFloat) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: points, weight: .regular)
    let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    return NSImage(size: s.size, flipped: false) { r in
        s.draw(in: r)
        NSColor(calibratedWhite: white, alpha: 1).set()
        r.fill(using: .sourceAtop)
        return true
    }
}

func tile(_ px: Int) -> Data {
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocus()
    let inset = CGFloat(px) * 0.04
    let rect = NSRect(x: inset, y: inset, width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2, yRadius: rect.width * 0.2)
    NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
    path.fill()
    NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
    path.lineWidth = max(1, CGFloat(px) / 256)
    path.stroke()
    let glyph = symbol("iphone.and.arrow.forward", points: rect.width * 0.5, white: 0.95)
    let s = glyph.size
    glyph.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
    image.unlockFocus()
    return png(image)
}

for px in [16, 20, 24, 32, 40, 48, 64, 128, 256] {
    try! tile(px).write(to: URL(fileURLWithPath: "\(outDir)/icon-\(px).png"))
}
// Top-bar mark at 2x (20 pt): light glyph for the dark theme, dark glyph for the light theme.
for (name, white) in [("mark-dark", 0.92), ("mark-light", 0.12)] {
    let g = symbol("iphone.and.arrow.forward", points: 40, white: CGFloat(white))
    let canvas = NSImage(size: NSSize(width: 48, height: 48))
    canvas.lockFocus()
    g.draw(in: NSRect(x: 24 - g.size.width / 2, y: 24 - g.size.height / 2, width: g.size.width, height: g.size.height))
    canvas.unlockFocus()
    try! png(canvas).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
