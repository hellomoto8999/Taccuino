import AppKit

// Draw the Taccuino icon: a notepad on a Fluent blue tile.
let size: CGFloat = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.setFill()
canvas.fill()

// Sfondo blu arrotondato (stile Fluent).
let bgRect = canvas.insetBy(dx: 58, dy: 58)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 210, yRadius: 210)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.24, green: 0.56, blue: 0.88, alpha: 1),
    NSColor(srgbRed: 0.06, green: 0.35, blue: 0.67, alpha: 1)
])!
gradient.draw(in: bg, angle: -90)

// Riflesso luminoso in alto.
NSGraphicsContext.saveGraphicsState()
bg.addClip()
let shine = NSBezierPath(ovalIn: NSRect(x: 90, y: 620, width: 900, height: 540))
NSColor.white.withAlphaComponent(0.13).setFill()
shine.fill()
NSGraphicsContext.restoreGraphicsState()

// Foglio bianco.
let sheetRect = NSRect(x: 288, y: 168, width: 448, height: 676)
let sheet = NSBezierPath(roundedRect: sheetRect, xRadius: 40, yRadius: 40)
NSColor.black.withAlphaComponent(0.18).setFill()
let shadow = sheet.copy() as! NSBezierPath
shadow.transform(using: AffineTransform(translationByX: 0, byY: -12))
shadow.fill()
NSColor(srgbRed: 0.99, green: 0.995, blue: 1, alpha: 1).setFill()
sheet.fill()

// Testata blu del foglio.
NSGraphicsContext.saveGraphicsState()
sheet.addClip()
let headerRect = NSRect(x: 288, y: 732, width: 448, height: 112)
NSColor(srgbRed: 0.11, green: 0.45, blue: 0.78, alpha: 1).setFill()
NSBezierPath(rect: headerRect).fill()
NSGraphicsContext.restoreGraphicsState()

// Anelli della rilegatura.
for i in 0..<3 {
    let y = 782 - CGFloat(i) * 42
    let ring = NSBezierPath(roundedRect: NSRect(x: 330, y: y, width: 96, height: 16), xRadius: 8, yRadius: 8)
    NSColor.white.withAlphaComponent(0.92).setFill()
    ring.fill()
}

// Righe di testo.
let lineWidths: [CGFloat] = [318, 350, 262, 336, 214]
for (i, w) in lineWidths.enumerated() {
    let y = 618 - CGFloat(i) * 86
    let line = NSBezierPath(roundedRect: NSRect(x: 356, y: y, width: w, height: 28), xRadius: 14, yRadius: 14)
    NSColor(srgbRed: 0.16, green: 0.49, blue: 0.80, alpha: 0.78).setFill()
    line.fill()
}


NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try png.write(to: URL(fileURLWithPath: out))
print("✓ \(out)")
