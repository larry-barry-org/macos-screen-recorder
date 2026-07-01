import AppKit

// Renders a 1024×1024 macOS-style app icon: a red squircle with a white
// video-camera glyph. Output path is argv[1].

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }

// Rounded-rect (squircle-ish) background with a vertical red gradient.
let inset: CGFloat = 44
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius: CGFloat = (size - inset * 2) * 0.235
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
path.addClip()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.28, alpha: 1),
    NSColor(calibratedRed: 0.78, green: 0.13, blue: 0.13, alpha: 1),
])!
gradient.draw(in: rect, angle: -90)

// Subtle top highlight.
NSColor.white.withAlphaComponent(0.10).setFill()
NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: rect.height * 0.5), xRadius: radius, yRadius: radius).fill()

// White video-camera glyph, centered.
ctx.resetClip()
let cfg = NSImage.SymbolConfiguration(pointSize: 520, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let s = symbol.size
    let glyphRect = NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height)

    // Colorize the (template) glyph white.
    let white = NSImage(size: s)
    white.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: s))
    NSColor.white.set()
    NSRect(origin: .zero, size: s).fill(using: .sourceAtop)
    white.unlockFocus()
    white.draw(in: glyphRect)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to encode PNG")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
