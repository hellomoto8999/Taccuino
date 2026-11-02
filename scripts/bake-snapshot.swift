import AppKit

// Compose a content-view snapshot into a rounded window with a shadow.
// Usage: swift bake-snapshot.swift input.png output.png [dark]
let args = CommandLine.arguments
guard args.count >= 3,
      let image = NSImage(contentsOfFile: args[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
let dark = args.count > 3 && args[3] == "dark"
let scale: CGFloat = cg.width > 1500 ? 2 : 1
let radius: CGFloat = 12 * scale
let margin: CGFloat = 70 * scale
let width = CGFloat(cg.width) + margin * 2
let height = CGFloat(cg.height) + margin * 2

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width), pixelsHigh: Int(height),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let canvas = NSRect(x: 0, y: 0, width: width, height: height)
let colors: [NSColor] = dark
    ? [NSColor(srgbRed: 0.11, green: 0.13, blue: 0.16, alpha: 1),
       NSColor(srgbRed: 0.04, green: 0.05, blue: 0.07, alpha: 1)]
    : [NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1),
       NSColor(srgbRed: 0.88, green: 0.91, blue: 0.94, alpha: 1)]
NSGradient(colors: colors)!.draw(in: canvas, angle: -90)

let windowRect = NSRect(x: margin, y: margin, width: CGFloat(cg.width), height: CGFloat(cg.height))
let rounded = NSBezierPath(roundedRect: windowRect, xRadius: radius, yRadius: radius)

// Ombra morbida.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.22)
shadow.shadowBlurRadius = 24 * scale
shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
shadow.set()
NSColor.black.withAlphaComponent(0.01).setFill()
rounded.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
rounded.addClip()
image.draw(in: windowRect, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

NSColor.black.withAlphaComponent(dark ? 0.35 : 0.12).setStroke()
rounded.lineWidth = max(1, scale * 0.5)
rounded.stroke()

NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: args[2]))
print("✓ \(args[2])")
