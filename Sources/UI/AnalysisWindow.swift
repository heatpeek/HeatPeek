import SwiftUI
import AppKit

/// What the analysis window has open: a recorded time series, or the
/// temperature matrix of a single saved frame.
enum AnalysisDocument {
    case recording(RecordingDocument)
    case snapshot(SnapshotDocument)

    var name: String {
        switch self {
        case .recording(let d): return d.name
        case .snapshot(let d): return d.name
        }
    }

    var sourceUnit: TemperatureUnit {
        switch self {
        case .recording(let d): return d.sourceUnit
        case .snapshot(let d): return d.sourceUnit
        }
    }
}

/// Holds the file currently open for analysis. A single shared store, so the
/// menu command and the inspector button reach the same window.
@Observable
final class AnalysisStore {
    static let shared = AnalysisStore()

    private(set) var document: AnalysisDocument?
    private(set) var errorMessage: String?

    /// Series the viewer hides, by column index.
    var hidden: Set<Int> = []

    func open(url: URL) {
        do {
            // A snapshot names itself in its first line; anything else is read
            // as a recording, which fails with its own explanation.
            if let snapshot = try SnapshotDocument.read(contentsOf: url) {
                document = .snapshot(snapshot)
            } else {
                document = .recording(try RecordingDocument.read(contentsOf: url))
            }
            errorMessage = nil
            hidden = []
        } catch {
            document = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Asks for a file and loads it. The picker is the one system panel the
    /// app cannot replace. Returns false when the user cancelled, so the
    /// caller can leave the window closed.
    @discardableResult
    func chooseFile() -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Open a recording or a saved snapshot")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        open(url: url)
        return true
    }

    func close() {
        document = nil
        errorMessage = nil
        hidden = []
    }
}

/// Reads a saved file back: a recording as one curve per column with a
/// scrubber, a snapshot as its picture with the distribution of its
/// temperatures.
struct AnalysisWindow: View {
    @Environment(CameraController.self) private var controller
    @State private var store = AnalysisStore.shared
    @State private var cursor: Int?
    @State private var pixel: (x: Int, y: Int)?

    /// Width reserved for the reading beside the crosshair, so it can be
    /// centred without measuring the text.
    private static let labelLane: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            switch store.document {
            case .recording(let document): content(document)
            case .snapshot(let document): snapshotContent(document)
            case nil: empty
            }
        }
        .background(Theme.windowBackground)
        .frame(minWidth: 760, minHeight: 460)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Text("ANALYSIS")
                .font(.hpLabel(15, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Theme.text)

            if let document = store.document {
                Text(verbatim: document.name)
                    .font(.hpMono(11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Text(verbatim: shape(of: document))
                    .font(.hpMono(10))
                    .foregroundStyle(Theme.label)
                if document.sourceUnit != controller.unit {
                    Text("Written in \(document.sourceUnit.suffix)")
                        .font(.hpLabel(11))
                        .foregroundStyle(Theme.label)
                }
            }

            Spacer(minLength: 12)

            if store.document != nil {
                GhostButton(title: "Close", icon: .x) { store.close() }
            }
            GhostButton(title: "Open…", icon: .chartLine) { store.chooseFile() }
        }
        .padding(.horizontal, 20)
        .frame(height: Theme.titleBarHeight)
        .background {
            ZStack {
                VisualEffectBackground(material: .headerView, blending: .withinWindow)
                Theme.titleBar
            }
        }
    }

    // MARK: - Empty state

    private var empty: some View {
        ZStack {
            Theme.emptyBackground
            BlueprintGrid()
            VStack(spacing: 20) {
                Icon(shape: .chartLine, size: 40)
                    .foregroundStyle(Theme.accentLine)
                    .frame(width: 108, height: 108)
                    .blueprintFrame(length: 8, inset: 0)
                VStack(spacing: 8) {
                    Text(store.errorMessage == nil ? "Nothing open" : "Could not open the file")
                        .font(.hpLabel(26))
                        .tracking(1.1)
                        .foregroundStyle(Theme.text)
                    Text(store.errorMessage ?? String(localized: "Open a recording to see every column as a curve, or a saved snapshot to see its picture and how its temperatures are distributed."))
                        .font(.hpBody(14))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                PrimaryButton(title: "Open file…") { store.chooseFile() }
            }
            .padding(40)
        }
    }

    // MARK: - Content

    private func content(_ document: RecordingDocument) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                legend(document)
                plot(document)
            }
            Rectangle().fill(Theme.hairline).frame(width: 1)
            values(document)
                .frame(width: 300)
        }
    }

    private func legend(_ document: RecordingDocument) -> some View {
        FlowLayout(spacing: 10) {
            ForEach(document.series) { series in
                let isHidden = store.hidden.contains(series.id)
                Button {
                    if isHidden { store.hidden.remove(series.id) } else { store.hidden.insert(series.id) }
                } label: {
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(color(series))
                            .frame(width: 14, height: 2)
                            .opacity(isHidden ? 0.3 : 1)
                        Text(verbatim: series.name)
                            .font(.hpLabel(12))
                            .foregroundStyle(isHidden ? Theme.label : Theme.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isHidden ? String(localized: "Show this curve") : String(localized: "Hide this curve"))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private func plot(_ document: RecordingDocument) -> some View {
        let range = document.valueRange
        return GeometryReader { geo in
            let inset = EdgeInsets(top: 10, leading: 54, bottom: 26, trailing: 18)
            let area = CGRect(x: inset.leading, y: inset.top,
                              width: max(1, geo.size.width - inset.leading - inset.trailing),
                              height: max(1, geo.size.height - inset.top - inset.bottom))
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    draw(document, range: range, in: area, context: &context)
                }
                Color.clear
                    .frame(width: area.width, height: area.height)
                    .blueprintFrame(opacity: 0.5, length: 7)
                    .offset(x: area.minX, y: area.minY)
                    .allowsHitTesting(false)
                axisLabels(document, range: range, area: area)
                if let index = cursor {
                    scrubber(document, index: index, area: area)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let t = (point.x - area.minX) / area.width
                    guard t >= 0, t <= 1 else { cursor = nil; return }
                    cursor = min(document.rowCount - 1,
                                 max(0, Int((t * CGFloat(document.rowCount - 1)).rounded())))
                case .ended:
                    cursor = nil
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    private func draw(_ document: RecordingDocument, range: (low: Double, high: Double),
                      in area: CGRect, context: inout GraphicsContext) {
        let span = max(0.01, range.high - range.low)

        // Grid at quarter steps, the same division the measurements use.
        for step in 0...4 {
            let y = area.minY + area.height * CGFloat(step) / 4
            var line = Path()
            line.move(to: CGPoint(x: area.minX, y: y))
            line.addLine(to: CGPoint(x: area.maxX, y: y))
            context.stroke(line, with: .color(Theme.accentLine.opacity(step == 0 || step == 4 ? 0.28 : 0.14)),
                           lineWidth: 1)
        }

        for series in document.series where !store.hidden.contains(series.id) {
            var path = Path()
            var started = false
            for (index, value) in series.values.enumerated() {
                guard let value else { started = false; continue }
                let x = area.minX + area.width * CGFloat(index) / CGFloat(max(1, document.rowCount - 1))
                let y = area.maxY - area.height * CGFloat((value - range.low) / span)
                let point = CGPoint(x: x, y: y)
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
            }
            context.stroke(path, with: .color(color(series)),
                           style: StrokeStyle(lineWidth: placed(series) ? 1.8 : 1.2,
                                              lineCap: .round, lineJoin: .round))
        }
    }

    private func axisLabels(_ document: RecordingDocument, range: (low: Double, high: Double),
                            area: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<5, id: \.self) { step in
                let value = range.high - (range.high - range.low) * Double(step) / 4
                Text(verbatim: controller.unit.number(value))
                    .font(.hpMono(10))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: area.minX - 10, alignment: .trailing)
                    .offset(y: area.minY + area.height * CGFloat(step) / 4 - 7)
            }
            ForEach(0..<3, id: \.self) { step in
                let fraction = CGFloat(step) / 2
                Text(verbatim: timeLabel(document, at: fraction))
                    .font(.hpMono(10))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 90, alignment: step == 0 ? .leading : (step == 2 ? .trailing : .center))
                    .offset(x: area.minX + area.width * fraction - (step == 0 ? 0 : (step == 2 ? 90 : 45)),
                            y: area.maxY + 6)
            }
        }
        .allowsHitTesting(false)
    }

    private func scrubber(_ document: RecordingDocument, index: Int, area: CGRect) -> some View {
        let x = area.minX + area.width * CGFloat(index) / CGFloat(max(1, document.rowCount - 1))
        return Rectangle()
            .fill(Theme.accentBright.opacity(0.7))
            .frame(width: 1, height: area.height)
            .offset(x: x, y: area.minY)
            .allowsHitTesting(false)
    }

    // MARK: - Snapshot

    private func snapshotContent(_ document: SnapshotDocument) -> some View {
        HStack(spacing: 0) {
            snapshotImage(document)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            snapshotValues(document)
                .frame(width: 300)
        }
    }

    private func snapshotImage(_ document: SnapshotDocument) -> some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / CGFloat(document.width),
                            geo.size.height / CGFloat(document.height))
            let size = CGSize(width: CGFloat(document.width) * scale,
                              height: CGFloat(document.height) * scale)
            let origin = CGPoint(x: (geo.size.width - size.width) / 2,
                                 y: (geo.size.height - size.height) / 2)
            ZStack(alignment: .topLeading) {
                // Holds the stack at full size. The crosshair uses .position,
                // which claims all offered space, so without this the stack
                // would shrink to the picture the moment the cursor leaves it
                // and everything inside would shift.
                Color.clear

                if let image = document.image(palette: controller.palette) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .offset(x: origin.x, y: origin.y)
                }
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .blueprintFrame(opacity: 0.5, length: 7)
                    .offset(x: origin.x, y: origin.y)
                    .allowsHitTesting(false)
                if let pixel, let value = document.temperature(x: pixel.x, y: pixel.y) {
                    let point = CGPoint(x: origin.x + (CGFloat(pixel.x) + 0.5) * scale,
                                        y: origin.y + (CGFloat(pixel.y) + 0.5) * scale)
                    // Both are centred on their own point, the way the main
                    // window places its markers. Offsetting a stack instead
                    // would move the crosshair by half its own width.
                    CrosshairMark()
                        .position(point)
                        .allowsHitTesting(false)
                    // Measured against the pane, not the picture: the reading
                    // is legible over the surrounding ground too, so it only
                    // needs to flip when it would leave the view.
                    let fitsRight = point.x + 18 + Self.labelLane <= geo.size.width
                    MarkerPlaque(name: String(localized: "Cursor"),
                                 value: controller.unit.format(value),
                                 color: .white)
                        .frame(width: Self.labelLane, alignment: fitsRight ? .leading : .trailing)
                        .position(x: fitsRight ? point.x + 18 + Self.labelLane / 2
                                               : point.x - 18 - Self.labelLane / 2,
                                  y: point.y)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    // Truncation would fold a position just outside the left
                    // or top edge onto pixel zero.
                    let fx = (point.x - origin.x) / scale
                    let fy = (point.y - origin.y) / scale
                    guard fx >= 0, fy >= 0 else { pixel = nil; return }
                    let x = Int(fx), y = Int(fy)
                    pixel = document.temperature(x: x, y: y) == nil ? nil : (x, y)
                case .ended:
                    pixel = nil
                }
            }
        }
        .padding(18)
    }

    private func snapshotValues(_ document: SnapshotDocument) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(pixel == nil ? "Whole picture" : "At the cursor")
                    .font(.hpLabel(11))
                    .tracking(1.4)
                    .foregroundStyle(Theme.label)
                Spacer()
                if let pixel {
                    Text(verbatim: "\(pixel.x), \(pixel.y)")
                        .font(.hpMono(10))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 34)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            // Always present, so the rows below it never move.
            snapshotRow(String(localized: "Cursor"),
                        pixel.flatMap { document.temperature(x: $0.x, y: $0.y) },
                        color: .white)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            snapshotRow(String(localized: "Min"), document.minC,
                        color: Color(nsColor: OverlayCompositor.trendColor(kind: .min)))
            Rectangle().fill(Theme.hairline).frame(height: 1)
            snapshotRow(String(localized: "Average"), document.meanC,
                        color: Color(nsColor: OverlayCompositor.trendColor(kind: .average)))
            Rectangle().fill(Theme.hairline).frame(height: 1)
            snapshotRow(String(localized: "Max"), document.maxC,
                        color: Color(nsColor: OverlayCompositor.trendColor(kind: .max)))
            Rectangle().fill(Theme.hairline).frame(height: 1)

            Text("DISTRIBUTION")
                .font(.hpLabel(11))
                .tracking(1.4)
                .foregroundStyle(Theme.label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)

            histogram(document)
                .frame(height: 120)
                .padding(.horizontal, 16)
                .padding(.top, 6)

            HStack {
                Text(verbatim: controller.unit.number(document.minC))
                Spacer()
                Text(verbatim: controller.unit.number(document.maxC))
            }
            .font(.hpMono(10))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 16)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
    }

    private func snapshotRow(_ title: String, _ value: Double?, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
                .opacity(value == nil ? 0.4 : 1)
            Text(verbatim: title)
                .font(.hpLabel(14))
                .foregroundStyle(value == nil ? Theme.textSecondary : Theme.text)
            Spacer(minLength: 6)
            Text(verbatim: value.map { controller.unit.format($0) } ?? "\u{2014}")
                .font(.hpMono(13))
                .foregroundStyle(value == nil ? Theme.label : Theme.text)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    /// How many pixels sit at each temperature, over the picture's own range.
    private func histogram(_ document: SnapshotDocument) -> some View {
        let bins = document.histogram(bins: 64)
        let peak = max(1, bins.max() ?? 1)
        return Canvas { context, size in
            let width = size.width / CGFloat(bins.count)
            for (index, count) in bins.enumerated() {
                let height = size.height * CGFloat(count) / CGFloat(peak)
                guard height > 0 else { continue }
                let bar = CGRect(x: CGFloat(index) * width, y: size.height - height,
                                 width: max(1, width - 1), height: height)
                // Each bar wears the colour its temperature has in the picture.
                let t = Double(index) / Double(bins.count - 1)
                let lut = controller.palette.lut
                let i = min(255, max(0, Int(t * 255))) * 3
                context.fill(Path(bar), with: .color(Color(red: Double(lut[i]) / 255,
                                                           green: Double(lut[i + 1]) / 255,
                                                           blue: Double(lut[i + 2]) / 255)))
            }
        }
    }

    // MARK: - Values

    private func values(_ document: RecordingDocument) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(cursor == nil ? "Whole recording" : "At the cursor")
                    .font(.hpLabel(11))
                    .tracking(1.4)
                    .foregroundStyle(Theme.label)
                Spacer()
                if let index = cursor {
                    Text(verbatim: Self.timeText(document.seconds[index]))
                        .font(.hpMono(10))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 34)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(document.series) { series in
                        row(series, document: document)
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                }
            }
        }
    }

    private func row(_ series: RecordingDocument.Series, document: RecordingDocument) -> some View {
        let hidden = store.hidden.contains(series.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(color(series)).frame(width: 7, height: 7)
                Text(verbatim: series.name)
                    .font(.hpLabel(14))
                    .foregroundStyle(hidden ? Theme.label : Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(verbatim: headline(series, document: document))
                    .font(.hpMono(13))
                    .foregroundStyle(hidden ? Theme.label : Theme.text)
            }
            if cursor == nil {
                HStack(spacing: 10) {
                    detail("MIN", series.minValue, document: document)
                    detail("\u{00D8}", series.meanValue, document: document)
                    detail("MAX", series.maxValue, document: document)
                }
                .padding(.leading, 15)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if hidden { store.hidden.remove(series.id) } else { store.hidden.insert(series.id) }
        }
    }

    private func detail(_ title: String, _ value: Double?, document: RecordingDocument) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: title)
                .font(.hpLabel(9))
                .tracking(1)
                .foregroundStyle(Theme.label)
            Text(verbatim: value.map { controller.unit.number($0) } ?? "\u{2014}")
                .font(.hpMono(10.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func headline(_ series: RecordingDocument.Series, document: RecordingDocument) -> String {
        if let index = cursor, let value = series.values[index] {
            return controller.unit.format(value)
        }
        if cursor != nil { return "\u{2014}" }
        return series.meanValue.map { controller.unit.format($0) } ?? "\u{2014}"
    }

    // MARK: - Helpers

    private func color(_ series: RecordingDocument.Series) -> Color {
        Color(nsColor: OverlayCompositor.trendColor(kind: series.kind))
    }

    /// Measurements the user placed draw heavier than the fixed readings.
    private func placed(_ series: RecordingDocument.Series) -> Bool {
        switch series.kind {
        case .spot, .region: return true
        default: return false
        }
    }

    private func timeLabel(_ document: RecordingDocument, at fraction: CGFloat) -> String {
        let index = Int((CGFloat(document.rowCount - 1) * fraction).rounded())
        return Self.timeText(document.seconds[min(max(0, index), document.rowCount - 1)])
    }

    private func shape(of document: AnalysisDocument) -> String {
        switch document {
        case .recording(let d): return "\(d.rowCount) \u{00B7} \(durationText(d.duration))"
        case .snapshot(let d): return "\(d.width) \u{00D7} \(d.height)"
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func timeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? String(format: "%d:%02d", total / 60, total % 60) : "\(total) s"
    }
}
