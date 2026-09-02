// Regenerates Sources/Resources/Assets.xcassets/AppIcon.appiconset.
//
// Run from the repository root:
//     swift Tools/GenerateAppIcon.swift Sources/Resources/Assets.xcassets/AppIcon.appiconset
//
// The icon is drawn in the same palette and frame idiom as the interface, so
// it stays in step with the app rather than being a separate asset.

import AppKit

/// The Plasma ramp, as a degree-6 polynomial fit — the same approximation the
/// app's palette uses, reduced to the one colormap the icon needs.
enum Plasma {
    private static let coefficients: [(Double, Double, Double)] = [
        (0.05873234392399702, 0.02333670892565664, 0.5433401826748754),
        (2.176514634195958, 0.2383834171260182, 0.7539604599784036),
        (-2.689460476458034, -7.455851135738909, 3.110799939717086),
        (6.130348345893603, 42.3461881477227, -28.51885465332158),
        (-11.10743619062271, -82.66631109428045, 60.13984767418263),
        (10.02306557647065, 71.41361770095349, -54.07218655560067),
        (-3.658713842777788, -22.93153465461149, 18.19190778539828),
    ]

    static func color(at t: Double) -> NSColor {
        var r = 0.0, g = 0.0, b = 0.0
        for c in coefficients.reversed() {
            r = r * t + c.0
            g = g * t + c.1
            b = b * t + c.2
        }
        func clamp(_ v: Double) -> CGFloat { CGFloat(Swift.min(1, Swift.max(0, v))) }
        return NSColor(calibratedRed: clamp(r), green: clamp(g), blue: clamp(b), alpha: 1)
    }
}

/// corner marks used throughout the app.
func makeIcon(size px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024

    // Big Sur plate: 824 pt of art inside a 1024 pt canvas.
    let plate = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: plate, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.current!.cgContext.saveGState()
    shape.addClip()
    let ground = NSGradient(starting: NSColor(calibratedRed: 0x18 / 255, green: 0x1C / 255,
                                              blue: 0x23 / 255, alpha: 1),
                            ending: NSColor(calibratedRed: 0x0A / 255, green: 0x0C / 255,
                                            blue: 0x0F / 255, alpha: 1))!
    ground.draw(in: plate, angle: -90)

    // Thermal plume: the Plasma ramp fading out into the plate.
    let cx = plate.midX
    let cy = plate.midY
    var colors: [NSColor] = []
    var locations: [CGFloat] = []
    var step = 0
    while step <= 16 {
        let t = CGFloat(step) / 16
        // Fades over the outer third so the plume has no visible edge.
        let alpha: CGFloat = t < 0.62 ? 1.0 : (1 - t) / 0.38
        colors.append(Plasma.color(at: Double(1 - t)).withAlphaComponent(alpha))
        locations.append(t)
        step += 1
    }
    let plume = NSGradient(colors: colors, atLocations: locations, colorSpace: .deviceRGB)!
    plume.draw(fromCenter: CGPoint(x: cx, y: cy), radius: 0,
               toCenter: CGPoint(x: cx, y: cy), radius: plate.width * 0.40, options: [])

    // Crosshair over the hot spot.
    let r = plate.width * 0.115
    NSColor.white.setStroke()
    let ring = NSBezierPath(ovalIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    ring.lineWidth = 24 * s
    ring.stroke()
    let ticks = NSBezierPath()
    let directions: [(CGFloat, CGFloat)] = [(-1, 0), (1, 0), (0, -1), (0, 1)]
    for (dx, dy) in directions {
        ticks.move(to: CGPoint(x: cx + dx * r * 1.5, y: cy + dy * r * 1.5))
        ticks.line(to: CGPoint(x: cx + dx * r * 2.15, y: cy + dy * r * 2.15))
    }
    ticks.lineWidth = 24 * s
    ticks.stroke()

    // Corner marks, the app's own frame idiom.
    let inner = plate.insetBy(dx: 96 * s, dy: 96 * s)
    let length = 78 * s
    let marks = NSBezierPath()
    let corners: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: inner.minX, y: inner.minY + length), CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.minX + length, y: inner.minY)),
        (CGPoint(x: inner.maxX - length, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY + length)),
        (CGPoint(x: inner.maxX, y: inner.maxY - length), CGPoint(x: inner.maxX, y: inner.maxY), CGPoint(x: inner.maxX - length, y: inner.maxY)),
        (CGPoint(x: inner.minX + length, y: inner.maxY), CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.minX, y: inner.maxY - length)),
    ]
    for (a, b, c) in corners {
        marks.move(to: a); marks.line(to: b); marks.line(to: c)
    }
    NSColor(calibratedRed: 0x94 / 255, green: 0xBC / 255, blue: 0xE3 / 255, alpha: 0.85).setStroke()
    marks.lineWidth = 14 * s
    marks.stroke()
    NSGraphicsContext.current!.cgContext.restoreGState()

    // Hairline edge, so the plate keeps its shape on a light background.
    NSColor.white.withAlphaComponent(0.14).setStroke()
    shape.lineWidth = 3 * s
    shape.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// macOS icon set: 16…512 pt, each at 1x and 2x.
var contents: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! makeIcon(size: pt * scale).write(to: out.appendingPathComponent(name))
        contents.append(["size": "\(pt)x\(pt)", "idiom": "mac",
                         "filename": name, "scale": "\(scale)x"])
    }
}
let json: [String: Any] = ["images": contents, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
print("icons: \(contents.count)")
