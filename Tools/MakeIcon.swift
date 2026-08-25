import AppKit

// Draws the app icon at every size macOS asks for. Small sizes get a simplified
// version — text lines and shadows turn to mush below 64px.

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawIcon(size s: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(s)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let detailed = s >= 64

    // Rounded-square base, macOS corner proportion.
    let base = rounded(NSRect(x: 0, y: 0, width: s, height: s), s * 0.2237)
    NSGradient(starting: color(0x5B8CF7), ending: color(0x1E3FB8))!.draw(in: base, angle: -90)

    // Light catch across the top.
    NSGraphicsContext.saveGraphicsState()
    base.addClip()
    NSGradient(starting: color(0xFFFFFF, 0.22), ending: color(0xFFFFFF, 0))!
        .draw(in: NSRect(x: 0, y: s * 0.55, width: s, height: s * 0.45), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The page.
    let page = NSRect(x: s * 0.215, y: s * 0.145, width: s * 0.57, height: s * 0.70)
    if detailed {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(0x000000, 0.30)
        shadow.shadowBlurRadius = s * 0.035
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        shadow.set()
        color(0xFFFFFF).setFill()
        rounded(page, s * 0.035).fill()
        NSGraphicsContext.restoreGraphicsState()
    } else {
        color(0xFFFFFF).setFill()
        rounded(page, s * 0.05).fill()
    }

    // The pasted picture sitting on the page.
    let photo = detailed
        ? NSRect(x: s * 0.275, y: s * 0.46, width: s * 0.45, height: s * 0.30)
        : NSRect(x: s * 0.275, y: s * 0.33, width: s * 0.45, height: s * 0.42)
    let photoPath = rounded(photo, s * 0.022)
    NSGradient(starting: color(0xBFE6FA), ending: color(0x7CC4EE))!.draw(in: photoPath, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    photoPath.addClip()

    // Sun.
    color(0xFFC64B).setFill()
    let sunR = photo.height * 0.17
    NSBezierPath(ovalIn: NSRect(x: photo.maxX - photo.width * 0.26 - sunR,
                                y: photo.maxY - photo.height * 0.28 - sunR,
                                width: sunR * 2, height: sunR * 2)).fill()

    // Two hills.
    let back = NSBezierPath()
    back.move(to: NSPoint(x: photo.minX, y: photo.minY))
    back.line(to: NSPoint(x: photo.minX + photo.width * 0.42, y: photo.minY + photo.height * 0.72))
    back.line(to: NSPoint(x: photo.minX + photo.width * 0.80, y: photo.minY))
    back.close()
    color(0x3E8C74).setFill()
    back.fill()

    let front = NSBezierPath()
    front.move(to: NSPoint(x: photo.minX + photo.width * 0.30, y: photo.minY))
    front.line(to: NSPoint(x: photo.minX + photo.width * 0.66, y: photo.minY + photo.height * 0.50))
    front.line(to: NSPoint(x: photo.maxX, y: photo.minY))
    front.close()
    color(0x2C6B57).setFill()
    front.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Lines of markup under the picture.
    if detailed {
        color(0xC3CBD8).setFill()
        let widths: [CGFloat] = [0.45, 0.38, 0.30]
        for (index, width) in widths.enumerated() {
            let y = photo.minY - s * (0.075 + 0.062 * CGFloat(index))
            let bar = NSRect(x: page.minX + s * 0.06, y: y, width: s * width, height: s * 0.032)
            rounded(bar, bar.height / 2).fill()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, size) in variants {
    let rep = drawIcon(size: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: outputDir.appendingPathComponent(name))
}
print("wrote \(variants.count) sizes to \(outputDir.path)")
