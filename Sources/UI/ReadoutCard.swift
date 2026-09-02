import SwiftUI

/// The only permanently visible field of numbers. Three blocks separated by
/// hairlines: scene extremes, the list of measurements, and a miniature curve.
struct ReadoutCard: View {
    @Environment(CameraController.self) private var controller
    let frame: ThermalFrame

    var body: some View {
        GlassPanel(padding: 0) {
            VStack(spacing: 0) {
                header
                divider
                list
                if controller.overlay.trend, let layout = controller.trendLayout {
                    divider
                    MiniTrend(layout: layout)
                        .frame(height: 44)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
        }
        .frame(width: Theme.readoutWidth)
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    private var header: some View {
        HStack(spacing: 0) {
            cell("MIN", value: frame.minC, color: Color(hex: 0x0A84FF), tint: Theme.text)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            cell("\u{00D8}", value: frame.avgC, color: Theme.textSecondary, tint: Theme.text)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            cell("MAX", value: frame.maxC, color: Color(hex: 0xFF453A), tint: Theme.warmValue)
        }
        .frame(height: 62)
    }

    private func cell(_ title: String, value: Double, color: Color, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title)
                .font(.hpLabel(11))
                .tracking(1.6)
                .foregroundStyle(color)
            Text(verbatim: controller.unit.number(value))
                .font(.hpReadout(30))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(controller.readoutRows) { row in
                HStack(spacing: 8) {
                    Group {
                        if row.isArea {
                            Rectangle().stroke(Color(nsColor: row.color), lineWidth: 1.5)
                        } else {
                            Circle().fill(Color(nsColor: row.color))
                        }
                    }
                    .frame(width: 8, height: 8)

                    Text(verbatim: row.name)
                        .font(.hpLabel(14))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(verbatim: controller.unit.format(row.value))
                        .font(.hpMono(12.5))
                        .foregroundStyle(row.inAlarm ? Color(hex: 0xFF453A) : Theme.text)
                }
                .padding(.horizontal, 12)
                .frame(height: 24)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Max plus the measurement spots, no axes — the compact form of the trend.
struct MiniTrend: View {
    let layout: TemperatureHistory.Layout

    var body: some View {
        Canvas { context, size in
            for series in layout.series {
                guard series.points.count >= 2 else { continue }
                let isSpot: Bool
                switch series.kind {
                case .spot, .region: isSpot = true
                case .max: isSpot = false
                default: continue
                }
                var path = Path()
                for (index, point) in series.points.enumerated() {
                    let p = CGPoint(x: point.x * size.width, y: point.y * size.height)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                let color = Color(nsColor: OverlayCompositor.trendColor(kind: series.kind))
                context.stroke(path, with: .color(color.opacity(isSpot ? 1 : 0.7)),
                               lineWidth: isSpot ? 1.4 : 1.0)
            }
        }
    }
}
