import Foundation
import CoreGraphics
import AppKit

/// Renders the measurements as a standalone 16:9 image: a trend chart and a
/// table of current values. Published as its own Syphon source so a scene can
/// place and size the numbers independently of the camera picture.
enum StatsRenderer {
    static let width = 1280
    static let height = 720

    /// One row of the value table.
    struct Row {
        let label: String
        let value: Double
        let color: NSColor
        var inAlarm = false
    }

    private static let nameSize: CGFloat = 19
    private static let valueSize: CGFloat = 28
    private static let legendSize: CGFloat = 15
    private static let margin: CGFloat = 34
    private static let tableWidth: CGFloat = 360
    private static let accent = NSColor(calibratedRed: 148 / 255, green: 188 / 255,
                                        blue: 227 / 255, alpha: 1)

    /// Secondary text is held back against the dark card, but goes to nearly
    /// full strength once the card is transparent and an unknown scene shows
    /// through instead.
    private static func secondary(_ opacity: Double) -> NSColor {
        NSColor(calibratedWhite: 1, alpha: opacity > 0.05 ? 0.62 : 0.95)
    }

    /// - Parameter opacity: ground opacity of the two cards. At zero only the
    ///   text and curves remain, so the source can be layered over any scene.
    static func render(layout: TemperatureHistory.Layout?,
                       rows: [Row],
                       opacity: Double = 0.45,
                       unit: TemperatureUnit = .celsius) -> CGImage? {
        let w = width, h = height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        let chart = CGRect(x: margin, y: margin,
                           width: CGFloat(w) - tableWidth - margin * 2.4,
                           height: CGFloat(h) - margin * 2)
        let table = CGRect(x: chart.maxX + margin * 0.6, y: margin,
                           width: tableWidth, height: CGFloat(h) - margin * 2)

        drawChart(layout, in: chart, opacity: opacity, unit: unit)
        drawTable(rows, in: table, opacity: opacity, unit: unit)

        NSGraphicsContext.current = previous
        ctx.restoreGState()
        return ctx.makeImage()
    }

    // MARK: - Cards

    /// Square card with a hairline edge and corner marks — the same frame the
    /// window uses around its panels.
    private static func drawCard(_ rect: CGRect, opacity: Double) {
        NSColor(calibratedRed: 13 / 255, green: 16 / 255, blue: 20 / 255,
                alpha: opacity).setFill()
        NSBezierPath(rect: rect).fill()
        guard opacity > 0.01 else { return }
        NSColor.white.withAlphaComponent(0.10).setStroke()
        let edge = NSBezierPath(rect: rect)
        edge.lineWidth = 1
        edge.stroke()
        OverlayCompositor.drawCornerMarks(rect, length: 12, inset: 5,
                                          color: accent, alpha: 0.75)
    }

    private static func drawTable(_ rows: [Row], in rect: CGRect,
                                  opacity: Double, unit: TemperatureUnit) {
        drawCard(rect, opacity: opacity)

        let inset = rect.insetBy(dx: 22, dy: 22)
        OverlayCompositor.draw(text: String(localized: "MEASUREMENTS"),
                               at: CGPoint(x: inset.minX, y: inset.minY),
                               size: legendSize, face: .condensed,
                               color: opacity > 0.05
                                   ? NSColor(calibratedRed: 107 / 255, green: 115 / 255,
                                             blue: 124 / 255, alpha: 1)
                                   : NSColor(calibratedWhite: 1, alpha: 0.8))

        // Name and value share a baseline; the smaller name is pushed down by
        // the difference of the two ascents.
        let nameDrop = (valueSize - nameSize) * 0.78
        let rowHeight = valueSize * 1.75
        var y = inset.minY + legendSize * 2.4
        for row in rows {
            drawDot(at: CGPoint(x: inset.minX + 6, y: y + nameDrop + nameSize * 0.55),
                    radius: 5, color: row.color)

            let value = unit.format(row.value)
            let valueWidth = OverlayCompositor.measure(text: value, size: valueSize, face: .mono)
            let name = truncate(row.label.uppercased(),
                                toWidth: inset.width - valueWidth - 40,
                                size: nameSize, face: .condensed)
            OverlayCompositor.draw(text: name,
                                   at: CGPoint(x: inset.minX + 20, y: y + nameDrop),
                                   size: nameSize, face: .condensed,
                                   color: secondary(opacity))
            OverlayCompositor.draw(text: value,
                                   at: CGPoint(x: inset.maxX - valueWidth, y: y),
                                   size: valueSize, face: .mono,
                                   color: row.inAlarm ? OverlayCompositor.alarmColor : .white)

            y += rowHeight
        }
    }

    /// Marker dot with a soft glow, so it survives a bright scene underneath.
    private static func drawDot(at p: CGPoint, radius: CGFloat, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.9)
        glow.shadowBlurRadius = 10
        glow.shadowOffset = .zero
        glow.set()
        OverlayCompositor.fillCircle(at: p, radius: radius, color: color)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Shortens a label with an ellipsis so a long name can never run into the
    /// value column.
    private static func truncate(_ text: String, toWidth limit: CGFloat,
                                 size: CGFloat, face: OverlayCompositor.Face) -> String {
        guard limit > 0,
              OverlayCompositor.measure(text: text, size: size, face: face) > limit else { return text }
        var result = text
        while !result.isEmpty,
              OverlayCompositor.measure(text: result + "…", size: size, face: face) > limit {
            result.removeLast()
        }
        return result.isEmpty ? "…" : result + "…"
    }

    // MARK: - Chart

    private static func drawChart(_ layout: TemperatureHistory.Layout?, in rect: CGRect,
                                  opacity: Double, unit: TemperatureUnit) {
        drawCard(rect, opacity: opacity)

        guard let layout else {
            let text = String(localized: "stats.waiting", defaultValue: "Recording history…")
            let width = OverlayCompositor.measure(text: text, size: valueSize, face: .body)
            OverlayCompositor.draw(text: text,
                                   at: CGPoint(x: rect.midX - width / 2, y: rect.midY - valueSize * 0.6),
                                   size: valueSize, face: .body,
                                   color: secondary(opacity))
            return
        }

        let plot = rect.insetBy(dx: 74, dy: 46)

        // Horizontal grid at quarter steps of the temperature span.
        for i in 0...4 {
            let t = CGFloat(i) / 4.0
            let lineY = plot.minY + t * plot.height
            accent.withAlphaComponent((i == 0 || i == 4 ? 0.28 : 0.16) * (opacity > 0.05 ? 1 : 2)).setStroke()
            let path = NSBezierPath()
            path.move(to: CGPoint(x: plot.minX, y: lineY))
            path.line(to: CGPoint(x: plot.maxX, y: lineY))
            path.lineWidth = 1
            path.stroke()

            let label = unit.degrees(layout.maxC - Double(t) * (layout.maxC - layout.minC))
            let labelWidth = OverlayCompositor.measure(text: label, size: legendSize, face: .mono)
            OverlayCompositor.draw(text: label,
                                   at: CGPoint(x: plot.minX - labelWidth - 12, y: lineY - legendSize * 0.7),
                                   size: legendSize, face: .mono,
                                   color: secondary(opacity))
        }

        // Deliberately placed measurements draw thicker and fully opaque; the
        // fixed series stay behind them.
        for series in layout.series {
            guard series.points.count >= 2 else { continue }
            let path = NSBezierPath()
            for (i, p) in series.points.enumerated() {
                let point = CGPoint(x: plot.minX + p.x * plot.width,
                                    y: plot.minY + p.y * plot.height)
                if i == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            let placed: Bool
            switch series.kind {
            case .spot, .region: placed = true
            default: placed = false
            }
            path.lineWidth = placed ? 2.6 : 1.8
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            OverlayCompositor.trendColor(kind: series.kind)
                .withAlphaComponent(placed ? 1.0 : 0.8).setStroke()
            path.stroke()
        }

        // Time axis under the plot.
        let axisY = plot.maxY + legendSize * 0.5
        let axisColor = secondary(opacity)
        let span = layout.spanSeconds >= 60
            ? "\u{2212}\(Int(layout.spanSeconds / 60)) min"
            : "\u{2212}\(Int(layout.spanSeconds)) s"
        OverlayCompositor.draw(text: span, at: CGPoint(x: plot.minX, y: axisY),
                               size: legendSize, face: .mono, color: axisColor)
        let now = String(localized: "now")
        OverlayCompositor.draw(text: now,
                               at: CGPoint(x: plot.maxX - OverlayCompositor.measure(text: now, size: legendSize, face: .mono),
                                           y: axisY),
                               size: legendSize, face: .mono, color: axisColor)
    }
}
