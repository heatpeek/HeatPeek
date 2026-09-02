import Foundation
import CoreGraphics
import AppKit

/// Burns the on-screen overlays (timestamp, scale bar, markers, spots) into a
/// CGImage so external consumers like the OBS stream see the same picture the
/// app window shows.
enum OverlayCompositor {
    /// The stamp the window and the burned-in overlay both show, so the two
    /// read the same at the same moment.
    static func timestampText(_ date: Date = Date(), format: TimestampFormat = .european) -> String {
        format.string(from: date)
    }

    static func composite(frame: ThermalFrame,
                          image: CGImage,
                          palette: Palette,
                          options: OverlayOptions,
                          spots: [SpotReading],
                          regions: [RegionReading] = [],
                          hover: (x: Int, y: Int, tempC: Double)? = nil,
                          trend: TemperatureHistory.Layout? = nil,
                          unit: TemperatureUnit = .celsius,
                          span: ScaleSpan,
                          timestampFormat: TimestampFormat = .european,
                          readoutRows: [ReadoutRow] = [],
                          alarmC: Double? = nil) -> CGImage? {
        // Upscale so text stays crisp; target roughly 1000 px on the long edge.
        let scale = max(3, Int((1000.0 / Double(max(frame.width, frame.height))).rounded()))
        let w = frame.width * scale
        let h = frame.height * scale

        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Flip into top-left coordinates so the layout matches the SwiftUI overlay.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        let fontSize = CGFloat(w) / 46.0
        let dotRadius = CGFloat(w) / 150.0

        func point(sensorX x: Int, sensorY y: Int) -> CGPoint {
            CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(frame.width) * CGFloat(w),
                    y: (CGFloat(y) + 0.5) / CGFloat(frame.height) * CGFloat(h))
        }

        // Timestamp, top-left
        if options.timestamp {
            draw(text: timestampText(format: timestampFormat),
                 at: CGPoint(x: fontSize * 0.8, y: fontSize * 0.6),
                 size: fontSize, monospaced: true)
        }

        // Right edge kept clear for the scale bar; labels flip left near it.
        let labelLimit = options.scaleBar
            ? CGFloat(w) - CGFloat(w) / 60.0 - fontSize * 4.5
            : CGFloat(w) - fontSize * 0.5

        // Labels are placed in order of importance and nudged apart when they
        // would collide — e.g. a spot dropped right on the centre crosshair.
        var placer = LabelPlacer(bounds: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        if options.timestamp {
            placer.reserve(CGRect(x: 0, y: 0, width: fontSize * 12, height: fontSize * 1.6))
        }
        if options.readout {
            placer.reserve(readoutRect(rows: readoutRows.count, width: w, height: h,
                                       fontSize: fontSize,
                                       withTrend: trend != nil && options.trend)
                .insetBy(dx: -fontSize * 0.6, dy: -fontSize * 0.6))
        }

        /// Draws a marker label beside its dot, flipping to the left side when
        /// it would otherwise run past the usable width.
        func drawMarkerLabel(_ text: String, at p: CGPoint, gap: CGFloat,
                             color: NSColor = .white) {
            let width = measure(text: text, size: fontSize)
            // A marker sitting on or past the scale bar has no room to its
            // right, and flipping alone would still leave the label on the bar,
            // so the flipped position is held clear of it.
            let x = p.x + gap + width <= labelLimit
                ? p.x + gap
                : min(p.x - gap - width, labelLimit - width)
            let preferred = CGRect(x: max(fontSize * 0.3, x), y: p.y - fontSize * 0.62,
                                   width: width, height: fontSize * 1.25)
            let rect = placer.place(preferred, step: fontSize * 1.35)
            draw(text: text, at: rect.origin, size: fontSize, color: color)
        }

        /// Places a plaque beside its anchor, flipping sides near the edge.
        func drawPlaqueLabel(name: String, value: String, at p: CGPoint,
                             gap: CGFloat, color: NSColor) {
            let probe = measure(text: name.uppercased() + "  " + value, size: fontSize) + fontSize * 1.6
            let x = p.x + gap + probe <= labelLimit
                ? p.x + gap
                : min(p.x - gap - probe, labelLimit - probe)
            let preferred = CGRect(x: max(fontSize * 0.3, x), y: p.y - fontSize * 0.78,
                                   width: probe, height: fontSize * 1.5)
            let rect = placer.place(preferred, step: fontSize * 1.7)
            _ = drawPlaque(name: name, value: value, at: rect.origin,
                           color: color, size: fontSize)
        }

        // Order matters: whoever is placed first keeps its preferred spot.
        // Deliberately placed measurement points come first, then the fixed
        // crosshair, and finally the min/max markers — those chase the noise
        // around the image, so they are the ones that should give way.

        // Area measurements, drawn under the point markers
        for region in (options.spots ? regions : []) {
            let topLeft = point(sensorX: Int(region.rect.minX), sensorY: Int(region.rect.minY))
            let bottomRight = point(sensorX: Int(region.rect.maxX), sensorY: Int(region.rect.maxY))
            let box = CGRect(x: topLeft.x, y: topLeft.y,
                             width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
            let color = region.inAlarm ? alarmColor : regionColor(index: region.index - 1)
            let path = NSBezierPath(rect: box)
            color.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
            drawCornerMarks(box, length: dotRadius * 1.8, inset: 0, color: color,
                            alpha: 1.0, lineWidth: 2)
            // The label sits outside the rectangle so it never covers the area.
            drawPlaqueLabel(name: region.label,
                            value: "\u{00F8}" + unit.number(region.avgC) + "  \u{25B2}" + unit.format(region.maxC),
                            at: CGPoint(x: box.minX, y: box.minY - fontSize * 1.5),
                            gap: 0, color: color)
        }

        // Measurement spots, colour-matched to their trend curve
        for spot in (options.spots ? spots : []) {
            let p = point(sensorX: spot.x, sensorY: spot.y)
            let color = spot.inAlarm ? alarmColor : spotColor(index: spot.index - 1)
            fillCircle(at: p, radius: dotRadius, color: color, ringed: true)
            drawPlaqueLabel(name: spot.label, value: unit.format(spot.tempC),
                            at: p, gap: dotRadius * 2.2, color: color)
        }

        // Center crosshair
        if options.crosshair {
            let center = CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
            drawCrosshair(at: center, radius: dotRadius, lineWidth: dotRadius * 0.28)
            if let centerTemp = frame.temperatureC(x: frame.width / 2, y: frame.height / 2) {
                drawMarkerLabel(unit.format(centerTemp), at: center, gap: dotRadius * 3.8)
            }
        }

        // Min / max markers
        if options.markers {
            let maxPoint = point(sensorX: frame.maxIndex % frame.width, sensorY: frame.maxIndex / frame.width)
            fillCircle(at: maxPoint, radius: dotRadius, color: .systemRed, ringed: true)
            drawMarkerLabel(unit.format(frame.maxC), at: maxPoint, gap: dotRadius * 2.2)

            let minPoint = point(sensorX: frame.minIndex % frame.width, sensorY: frame.minIndex / frame.width)
            fillCircle(at: minPoint, radius: dotRadius, color: .systemBlue, ringed: true)
            drawMarkerLabel(unit.format(frame.minC), at: minPoint, gap: dotRadius * 2.2)
        }

        // Cursor readout, mirroring what the app window shows
        if let hover, options.cursor {
            let p = point(sensorX: hover.x, sensorY: hover.y)
            drawPlaqueLabel(name: String(localized: "Cursor"),
                            value: unit.format(hover.tempC),
                            at: p, gap: dotRadius * 1.6, color: .white)
        }

        if options.scaleBar {
            drawScaleBar(span: span, palette: palette, width: w, height: h,
                         fontSize: fontSize, unit: unit,
                         crosshair: options.crosshair
                             ? span.fraction(ofPixelAt: frame.width / 2, y: frame.height / 2,
                                             in: frame)
                             : nil,
                         alarm: alarmC.flatMap(span.fraction(of:)))
        }

        if options.readout {
            drawReadout(rows: readoutRows, frame: frame, width: w, height: h,
                        fontSize: fontSize, unit: unit,
                        trend: options.trend ? trend : nil)
        }

        NSGraphicsContext.current = previous
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Distinct colors for measurement spots, reused by the dot on the image
    /// and its curve in the trend, so the two can be matched by eye.
    static let spotColors: [NSColor] = [
        .systemOrange, .systemGreen, .systemTeal, .systemYellow, .systemPink,
        .systemPurple, .systemMint, .systemIndigo, .systemBrown,
    ]

    static func spotColor(index: Int) -> NSColor {
        spotColors[index % spotColors.count]
    }

    /// Colors shared with the in-window trend chart.
    static func trendColor(kind: TemperatureHistory.SeriesKind) -> NSColor {
        switch kind {
        case .max: return .systemRed
        case .min: return .systemBlue
        case .average: return NSColor(calibratedWhite: 0.62, alpha: 1)
        case .center: return .white
        case .spot(let index): return spotColor(index: index)
        case .region(let index): return regionColor(index: index)
        }
    }

    /// Areas use a separate ramp so they never look like a spot.
    static let regionColors: [NSColor] = [
        NSColor(calibratedRed: 0.45, green: 0.85, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.75, green: 1.00, blue: 0.45, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.80, blue: 0.45, alpha: 1),
        NSColor(calibratedRed: 0.95, green: 0.60, blue: 1.00, alpha: 1),
    ]

    static func regionColor(index: Int) -> NSColor {
        regionColors[index % regionColors.count]
    }

    /// Colour used wherever a measurement is outside its alarm limits.
    static let alarmColor = NSColor.systemRed

    /// The blueprint accent, used for corner marks and grid lines.
    static let accentColor = NSColor(calibratedRed: 148 / 255, green: 188 / 255,
                                     blue: 227 / 255, alpha: 1)

    /// Frosted plate behind a deliberately placed measurement's label.
    @discardableResult
    static func drawPlaque(name: String, value: String, at origin: CGPoint,
                           color: NSColor, size: CGFloat) -> CGSize {
        let nameFont = NSFont(name: "BarlowCondensed-Medium", size: size)
            ?? .systemFont(ofSize: size, weight: .medium)
        let valueFont = NSFont(name: "IBMPlexMono-Regular", size: size * 0.92)
            ?? .monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = size * 0.3
        shadow.shadowOffset = .zero

        let nameString = NSAttributedString(string: name.uppercased(), attributes: [
            .font: nameFont,
            .foregroundColor: color.blended(withFraction: 0.35, of: .white) ?? color,
            .kern: size * 0.10,
            .shadow: shadow,
        ])
        let valueString = NSAttributedString(string: value, attributes: [
            .font: valueFont, .foregroundColor: NSColor.white, .shadow: shadow,
        ])

        let gap = size * 0.5
        let padX = size * 0.66, padY = size * 0.18
        let width = nameString.size().width + gap + valueString.size().width + padX * 2
        let height = max(nameString.size().height, valueString.size().height) + padY * 2
        let box = CGRect(x: origin.x, y: origin.y, width: width, height: height)

        NSColor(calibratedRed: 10 / 255, green: 12 / 255, blue: 15 / 255, alpha: 0.62).setFill()
        NSBezierPath(rect: box).fill()
        color.withAlphaComponent(0.42).setStroke()
        let border = NSBezierPath(rect: box)
        border.lineWidth = 1
        border.stroke()

        nameString.draw(at: CGPoint(x: box.minX + padX, y: box.minY + padY))
        valueString.draw(at: CGPoint(x: box.minX + padX + nameString.size().width + gap,
                                     y: box.minY + padY))
        return box.size
    }

    /// Four corner marks, the recurring frame motif.
    static func drawCornerMarks(_ rect: CGRect, length: CGFloat, inset: CGFloat,
                                color: NSColor, alpha: CGFloat = 0.75,
                                lineWidth: CGFloat = 1) {
        let r = rect.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath()
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: r.minX, y: r.minY + length), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX + length, y: r.minY)),
            (CGPoint(x: r.maxX - length, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + length)),
            (CGPoint(x: r.maxX, y: r.maxY - length), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX - length, y: r.maxY)),
            (CGPoint(x: r.minX + length, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY - length)),
        ]
        for (a, b, c) in corners {
            path.move(to: a); path.line(to: b); path.line(to: c)
        }
        color.withAlphaComponent(alpha).setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }

    /// Trend panel along the bottom edge, showing the recent temperature curve.
    /// Where the readings block sits: bottom-left, and above the trend panel
    /// when that is drawn too.
    static func readoutRect(rows: Int, width w: Int, height h: Int, fontSize: CGFloat,
                            withTrend: Bool) -> CGRect {
        let margin = fontSize * 0.9
        let width = fontSize * 15
        let height = fontSize * 3.4 + CGFloat(rows) * fontSize * 1.6 + fontSize * 0.9
            + (withTrend ? fontSize * 3.2 : 0)
        return CGRect(x: margin, y: CGFloat(h) - margin - height, width: width, height: height)
    }

    /// The same block of readings the window shows: scene extremes across the
    /// top, then one line per measurement.
    private static func drawReadout(rows: [ReadoutRow], frame: ThermalFrame,
                                    width w: Int, height h: Int, fontSize: CGFloat,
                                    unit: TemperatureUnit,
                                    trend: TemperatureHistory.Layout?) {
        let card = readoutRect(rows: rows.count, width: w, height: h, fontSize: fontSize,
                               withTrend: trend != nil)

        NSColor(calibratedRed: 13 / 255, green: 16 / 255, blue: 20 / 255, alpha: 0.72).setFill()
        NSBezierPath(rect: card).fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        let edge = NSBezierPath(rect: card)
        edge.lineWidth = 1
        edge.stroke()
        drawCornerMarks(card, length: fontSize * 0.5, inset: fontSize * 0.18,
                        color: accentColor, alpha: 0.75)

        // Header: minimum, mean and maximum of the whole scene.
        let headerHeight = fontSize * 3.4
        let cellWidth = card.width / 3
        let cells: [(String, Double, NSColor, NSColor)] = [
            ("MIN", frame.minC, .systemBlue, .white),
            ("\u{00D8}", frame.avgC, NSColor(calibratedWhite: 0.62, alpha: 1), .white),
            ("MAX", frame.maxC, .systemRed,
             NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.84, alpha: 1)),
        ]
        for (index, cell) in cells.enumerated() {
            let x = card.minX + CGFloat(index) * cellWidth
            if index > 0 {
                NSColor.white.withAlphaComponent(0.10).setStroke()
                let divider = NSBezierPath()
                divider.move(to: CGPoint(x: x, y: card.minY))
                divider.line(to: CGPoint(x: x, y: card.minY + headerHeight))
                divider.lineWidth = 1
                divider.stroke()
            }
            draw(text: cell.0, at: CGPoint(x: x + fontSize * 0.55, y: card.minY + fontSize * 0.5),
                 size: fontSize * 0.62, face: .condensed, color: cell.2)
            draw(text: unit.number(cell.1),
                 at: CGPoint(x: x + fontSize * 0.5, y: card.minY + fontSize * 1.3),
                 size: fontSize * 1.65, face: .condensed, color: cell.3)
        }

        NSColor.white.withAlphaComponent(0.10).setStroke()
        let split = NSBezierPath()
        split.move(to: CGPoint(x: card.minX, y: card.minY + headerHeight))
        split.line(to: CGPoint(x: card.maxX, y: card.minY + headerHeight))
        split.lineWidth = 1
        split.stroke()

        var y = card.minY + headerHeight + fontSize * 0.35
        for row in rows {
            let markerSize = fontSize * 0.42
            let marker = CGRect(x: card.minX + fontSize * 0.7, y: y + fontSize * 0.5,
                                width: markerSize, height: markerSize)
            row.color.setFill()
            if row.isArea {
                row.color.setStroke()
                let outline = NSBezierPath(rect: marker)
                outline.lineWidth = max(1, markerSize * 0.28)
                outline.stroke()
            } else {
                NSBezierPath(ovalIn: marker).fill()
            }

            draw(text: row.name, at: CGPoint(x: card.minX + fontSize * 1.6, y: y + fontSize * 0.18),
                 size: fontSize * 0.9, face: .condensed, color: .white)
            let value = unit.format(row.value)
            let valueWidth = measure(text: value, size: fontSize * 0.82, face: .mono)
            draw(text: value,
                 at: CGPoint(x: card.maxX - valueWidth - fontSize * 0.6, y: y + fontSize * 0.28),
                 size: fontSize * 0.82, face: .mono,
                 color: row.inAlarm ? alarmColor : .white)
            y += fontSize * 1.6
        }

        // The curve rides along in the block, the way the window's card shows
        // it. A chart with axes is what the measurements source is for.
        if let trend {
            let plot = CGRect(x: card.minX + fontSize * 0.7, y: y + fontSize * 0.25,
                              width: card.width - fontSize * 1.4, height: fontSize * 2.5)
            NSColor.white.withAlphaComponent(0.10).setStroke()
            let split = NSBezierPath()
            split.move(to: CGPoint(x: card.minX, y: y))
            split.line(to: CGPoint(x: card.maxX, y: y))
            split.lineWidth = 1
            split.stroke()
            drawMiniTrend(trend, in: plot, fontSize: fontSize)
        }
    }

    /// Max plus the placed measurements, no axes — the compact form.
    private static func drawMiniTrend(_ layout: TemperatureHistory.Layout,
                                      in plot: CGRect, fontSize: CGFloat) {
        for series in layout.series where series.points.count >= 2 {
            let placed: Bool
            switch series.kind {
            case .spot, .region: placed = true
            case .max: placed = false
            default: continue
            }
            let path = NSBezierPath()
            for (index, point) in series.points.enumerated() {
                let p = CGPoint(x: plot.minX + point.x * plot.width,
                                y: plot.minY + point.y * plot.height)
                if index == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.lineWidth = fontSize * (placed ? 0.13 : 0.09)
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            trendColor(kind: series.kind).withAlphaComponent(placed ? 1.0 : 0.7).setStroke()
            path.stroke()
        }
    }

    // MARK: - Drawing helpers

    /// The three typefaces of the burned-in overlay. They mirror the window:
    /// condensed for labels, mono for numbers, Barlow for running text.
    enum Face {
        case body, condensed, mono

        func font(size: CGFloat) -> NSFont {
            switch self {
            case .body:
                return NSFont(name: "Barlow-Regular", size: size)
                    ?? .systemFont(ofSize: size, weight: .regular)
            case .condensed:
                return NSFont(name: "BarlowCondensed-Medium", size: size)
                    ?? .systemFont(ofSize: size, weight: .medium)
            case .mono:
                return NSFont(name: "IBMPlexMono-Regular", size: size)
                    ?? .monospacedSystemFont(ofSize: size, weight: .regular)
            }
        }

        /// Letter spacing, in fractions of the font size.
        var tracking: CGFloat { self == .condensed ? 0.09 : 0 }
    }

    /// Every piece of text carries its own shadow, so the overlay stays
    /// readable even when the panels behind it are set to fully transparent.
    static func attributes(size: CGFloat, face: Face, color: NSColor) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = size * 0.28
        shadow.shadowOffset = .zero
        return [
            .font: face.font(size: size),
            .foregroundColor: color,
            .kern: size * face.tracking,
            .shadow: shadow,
        ]
    }

    static func measure(text: String, size: CGFloat, face: Face = .body) -> CGFloat {
        NSAttributedString(string: text,
                           attributes: attributes(size: size, face: face, color: .white)).size().width
    }

    static func draw(text: String, at origin: CGPoint, size: CGFloat,
                     face: Face, color: NSColor = .white) {
        guard !text.isEmpty else { return }
        NSAttributedString(string: text,
                           attributes: attributes(size: size, face: face, color: color)).draw(at: origin)
    }

    static func draw(text: String, at origin: CGPoint, size: CGFloat,
                     monospaced: Bool = false, color: NSColor = .white) {
        draw(text: text, at: origin, size: size, face: monospaced ? .mono : .body, color: color)
    }

    static func fillCircle(at p: CGPoint, radius: CGFloat, color: NSColor, ringed: Bool = false) {
        let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        if ringed {
            NSColor.white.setStroke()
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = radius * 0.35
            path.stroke()
        }
    }

    static func strokeCircle(at p: CGPoint, radius: CGFloat, color: NSColor, lineWidth: CGFloat) {
        let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
        color.setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = lineWidth
        path.stroke()
    }

    private static func drawCrosshair(at p: CGPoint, radius: CGFloat, lineWidth: CGFloat) {
        NSColor.white.setStroke()
        let circle = NSBezierPath(ovalIn: CGRect(x: p.x - radius, y: p.y - radius,
                                                 width: radius * 2, height: radius * 2))
        circle.lineWidth = lineWidth
        circle.stroke()

        let arms = NSBezierPath()
        let inner = radius * 1.6
        let outer = radius * 3.0
        arms.move(to: CGPoint(x: p.x - outer, y: p.y)); arms.line(to: CGPoint(x: p.x - inner, y: p.y))
        arms.move(to: CGPoint(x: p.x + inner, y: p.y)); arms.line(to: CGPoint(x: p.x + outer, y: p.y))
        arms.move(to: CGPoint(x: p.x, y: p.y - outer)); arms.line(to: CGPoint(x: p.x, y: p.y - inner))
        arms.move(to: CGPoint(x: p.x, y: p.y + inner)); arms.line(to: CGPoint(x: p.x, y: p.y + outer))
        arms.lineWidth = lineWidth
        arms.stroke()
    }

    private static func drawScaleBar(span: ScaleSpan, palette: Palette,
                                     width w: Int, height h: Int, fontSize: CGFloat,
                                     unit: TemperatureUnit,
                                     crosshair: Double?, alarm: Double?) {
        let barWidth = CGFloat(w) / 60.0
        let barHeight = CGFloat(h) * 0.45
        let x = CGFloat(w) - barWidth - fontSize * 2.4
        let y = (CGFloat(h) - barHeight) / 2

        // Gradient from the palette LUT, hot at the top.
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        for i in 0...32 {
            let t = CGFloat(i) / 32.0
            let idx = Int((1.0 - t) * 255.0) * 3
            colors.append(CGColor(red: CGFloat(palette.lut[idx]) / 255.0,
                                  green: CGFloat(palette.lut[idx + 1]) / 255.0,
                                  blue: CGFloat(palette.lut[idx + 2]) / 255.0,
                                  alpha: 1))
            locations.append(t)
        }
        let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
        let path = NSBezierPath(roundedRect: rect, xRadius: barWidth * 0.25, yRadius: barWidth * 0.25)

        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors as CFArray, locations: locations),
           let ctx = NSGraphicsContext.current?.cgContext {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: rect.midX, y: rect.minY),
                                   end: CGPoint(x: rect.midX, y: rect.maxY),
                                   options: [])
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.75).setStroke()
        path.lineWidth = max(1, barWidth * 0.09)
        path.stroke()

        drawCornerMarks(rect.insetBy(dx: -barWidth * 0.5, dy: -barWidth * 0.5),
                        length: barWidth * 0.6, inset: 0, color: .init(calibratedWhite: 1, alpha: 1),
                        alpha: 0.55)

        // Ticks for the crosshair and for anything outside its limits.
        for (fraction, color) in [(crosshair, NSColor.white), (alarm, alarmColor)] {
            guard let fraction else { continue }
            color.setStroke()
            let tick = NSBezierPath()
            let y = rect.minY + CGFloat(fraction) * rect.height
            tick.move(to: CGPoint(x: rect.minX - barWidth * 0.35, y: y))
            tick.line(to: CGPoint(x: rect.maxX + barWidth * 0.35, y: y))
            tick.lineWidth = max(1, barWidth * 0.13)
            tick.stroke()
        }

        // Five readings down the ramp. Under the camera's own gain they come
        // from the curve read back out of the frame, so they describe the
        // picture rather than a straight line between its ends.
        let small = fontSize * 0.72
        for t in [0, 0.25, 0.5, 0.75, 1] as [CGFloat] {
            let text = unit.number(span.value(at: Double(t)))
            let width = measure(text: text, size: small)
            draw(text: text,
                 at: CGPoint(x: rect.minX - width - small * 0.8,
                             y: rect.minY + t * rect.height - small * 0.65),
                 size: small, monospaced: true)
        }
    }

    /// Capsule-backed readout, matching the app's hover badge.
    static func drawPill(_ text: String, centeredAt center: CGPoint, size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let padX = size * 0.5
        let padY = size * 0.22
        let box = CGRect(x: center.x - textSize.width / 2 - padX,
                         y: center.y - textSize.height / 2 - padY,
                         width: textSize.width + padX * 2,
                         height: textSize.height + padY * 2)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        string.draw(at: CGPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2))
    }

    static func drawLabel(_ text: String, centeredAt center: CGPoint, size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let padX = size * 0.4
        let padY = size * 0.2
        let box = CGRect(x: center.x - textSize.width / 2 - padX,
                         y: center.y - textSize.height / 2 - padY,
                         width: textSize.width + padX * 2,
                         height: textSize.height + padY * 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: size * 0.3, yRadius: size * 0.3).fill()
        string.draw(at: CGPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2))
    }
}
