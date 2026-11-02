import AppKit

// Compose a window screenshot on a neutral background (for documentation).
// Usage: swift bake-screenshot.swift input.png output.png [dark]
let args = CommandLine.arguments
guard args.count >= 3,
      let image = NSImage(contentsOfFile: args[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    exit(1)
}
let dark = args.count > 3 && args[3] == "dark"
let margin = 80
let width = cg.width + margin * 2
let height = cg.height + margin * 2
let w = CGFloat(width)
let h = CGFloat(height)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let canvas = NSRect(x: 0, y: 0, width: w, height: h)

let colors: [NSColor] = dark
    ? [NSColor(srgbRed: 0.11, green: 0.13, blue: 0.16, alpha: 1),
       NSColor(srgbRed: 0.04, green: 0.05, blue: 0.07, alpha: 1)]
    : [NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1),
       NSColor(srgbRed: 0.88, green: 0.91, blue: 0.94, alpha: 1)]
let gradient = NSGradient(colors: colors)!
gradient.draw(in: canvas, angle: -90)

// Alone luminoso morbido al centro.
NSGraphicsContext.saveGraphicsState()
let glowRect = NSRect(x: w * 0.1, y: h * 0.15, width: w * 0.8, height: h * 0.7)
let glow = NSBezierPath(ovalIn: glowRect)
glow.addClip()
NSColor.white.withAlphaComponent(dark ? 0.025 : 0.4).setFill()
glowRect.fill()
NSGraphicsContext.restoreGraphicsState()

let imageRect = NSRect(x: CGFloat(margin), y: CGFloat(margin), width: CGFloat(cg.width), height: CGFloat(cg.height))
image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: args[2]))
print("✓ \(args[2])")
