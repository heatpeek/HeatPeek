import SwiftUI

/// Separate window for the readings. The curve gets real room here and the
/// values are listed instead of crowding the picture.
struct StatsWindow: View {
    @Environment(CameraController.self) private var controller

    var body: some View {
        @Bindable var controller = controller

        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                chart
                    .frame(maxWidth: .infinity)
                    .padding(16)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                valueList
                    .frame(width: 288)
            }
        }
        .background(Theme.windowBackground)
        .frame(minWidth: 760, minHeight: 420)
        .background(WindowObserver(
            onOpen: { controller.statsWindowOpen = true },
            onClose: { controller.statsWindowOpen = false }))
    }

    // MARK: - Header

    private var header: some View {
        @Bindable var controller = controller
        return HStack(spacing: 14) {
            Text("MEASUREMENTS")
                .font(.hpLabel(15, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Theme.text)
            Spacer()
            Segmented(selection: $controller.trendWindow,
                      options: TemperatureHistory.Window.allCases.map { ($0, $0.label) })
                .frame(width: 210)
        }
        .padding(.horizontal, 20)
        .frame(height: Theme.titleBarHeight)
        .background {
            ZStack {
                VisualEffectBackground(material: .headerView, blending: .withinWindow)
                Theme.titleBar
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chart: some View {
        if let layout = controller.trendLayout {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    ForEach(layout.series, id: \.kind) { series in
                        HStack(spacing: 5) {
                            Rectangle()
                                .fill(Color(nsColor: OverlayCompositor.trendColor(kind: series.kind)))
                                .frame(width: 14, height: 2)
                            seriesLabel(series)
                                .font(.hpLabel(12))
                                .tracking(0.6)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    Text(verbatim: controller.unit.number(layout.minC)
                         + " – " + controller.unit.format(layout.maxC))
                        .font(.hpMono(11))
                        .foregroundStyle(Theme.label)
                }

                TrendPlot(layout: layout)
                    .background(Theme.plotBackground)
                    .blueprintFrame(opacity: 0.5, length: 7)

                HStack {
                    ForEach(axisLabels(span: layout.spanSeconds), id: \.self) { label in
                        Text(verbatim: label)
                            .font(.hpMono(10))
                            .foregroundStyle(Theme.label)
                            .frame(maxWidth: .infinity,
                                   alignment: label == axisLabels(span: layout.spanSeconds).first
                                       ? .leading
                                       : (label == axisLabels(span: layout.spanSeconds).last ? .trailing : .center))
                    }
                }
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Recording history…")
                    .font(.hpBody(13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func axisLabels(span: TimeInterval) -> [String] {
        let unitLabel = span >= 60 ? "min" : "s"
        let full = span >= 60 ? Int(span / 60) : Int(span)
        return ["\u{2212}\(full) \(unitLabel)",
                "\u{2212}\(full / 2) \(unitLabel)",
                String(localized: "now")]
    }

    /// Curves carry only their index; the readable name lives with the
    /// measurement itself.
    private func seriesLabel(_ series: TemperatureHistory.Series) -> Text {
        switch series.kind {
        case .max: return Text("Max")
        case .min: return Text("Min")
        case .average: return Text("Average")
        case .center: return Text("Crosshair")
        case .spot(let index):
            let name = controller.spots.indices.contains(index) ? controller.spots[index].name : ""
            return Text(verbatim: name.isEmpty ? String(localized: "Spot \(index + 1)") : name)
        case .region(let index):
            let name = controller.regions.indices.contains(index) ? controller.regions[index].name : ""
            return Text(verbatim: name.isEmpty ? String(localized: "Area \(index + 1)") : name)
        }
    }

    // MARK: - Values

    private var valueList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    if let frame = controller.frame {
                        row(name: Text("Max"), value: frame.maxC, color: Color(hex: 0xFF453A), isArea: false)
                        row(name: Text("Average"), value: frame.avgC, color: Theme.textSecondary, isArea: false)
                        row(name: Text("Min"), value: frame.minC, color: Color(hex: 0x0A84FF), isArea: false)
                        ForEach(controller.readoutRows) { entry in
                            row(name: Text(verbatim: entry.name), value: entry.value,
                                color: Color(nsColor: entry.color), isArea: entry.isArea,
                                inAlarm: entry.inAlarm)
                        }
                    } else {
                        Text("No image")
                            .font(.hpBody(13))
                            .foregroundStyle(Theme.label)
                            .padding(20)
                    }
                }
            }
            .scrollIndicators(.never)

            Rectangle().fill(Theme.hairline).frame(height: 1)
            GhostButton(title: "Reset history", icon: .rotateCw) {
                controller.clearHistory()
            }
            .padding(12)
        }
    }

    private func row(name: Text, value: Double, color: Color,
                     isArea: Bool, inAlarm: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Group {
                    if isArea {
                        Rectangle().stroke(color, lineWidth: 1.5)
                    } else {
                        Circle().fill(color)
                    }
                }
                .frame(width: 9, height: 9)

                name
                    .font(.hpLabel(15))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(verbatim: controller.unit.format(value))
                    .font(.hpReadout(22))
                    .monospacedDigit()
                    .foregroundStyle(inAlarm ? Color(hex: 0xFF453A) : Theme.text)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

/// The curve itself: grid lines at quarter steps, then one polyline per series.
struct TrendPlot: View {
    let layout: TemperatureHistory.Layout

    var body: some View {
        Canvas { context, size in
            var grid = Path()
            for step in 0...4 {
                let y = size.height * CGFloat(step) / 4
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(Theme.plotGrid.opacity(0.25)), lineWidth: 1)

            for series in layout.series {
                guard series.points.count >= 2 else { continue }
                var path = Path()
                for (index, point) in series.points.enumerated() {
                    let p = CGPoint(x: point.x * size.width, y: point.y * size.height)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                let isSpot: Bool
                switch series.kind {
                case .spot, .region: isSpot = true
                default: isSpot = false
                }
                let color = Color(nsColor: OverlayCompositor.trendColor(kind: series.kind))
                context.stroke(path,
                               with: .color(color.opacity(isSpot ? 1.0 : 0.8)),
                               style: StrokeStyle(lineWidth: isSpot ? 1.8 : 1.2, lineJoin: .round))
            }
        }
    }
}
