import SwiftUI

/// Fixed-width panel, grouped into three tabs: what the picture looks like,
/// what produces numbers, and what leaves the house.
struct InspectorPanel: View {
    enum Tab: String, CaseIterable {
        case image, measure, output

        var title: String {
            switch self {
            case .image: return String(localized: "Image")
            case .measure: return String(localized: "Measure")
            case .output: return String(localized: "Output")
            }
        }
    }

    @Environment(CameraController.self) private var controller
    @Environment(\.openWindow) private var openWindow
    // The chosen tab is remembered, so the panel opens where it was left.
    @AppStorage("inspectorTab") private var tab: Tab = .image

    var body: some View {
        VStack(spacing: 0) {
            Segmented(selection: $tab, options: Tab.allCases.map { ($0, $0.title) })
                .padding(12)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch tab {
                    case .image: imageTab
                    case .measure: measureTab
                    case .output: outputTab
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
        .background(Theme.windowBackground)
    }

    // MARK: - Image

    @ViewBuilder
    private var imageTab: some View {
        @Bindable var controller = controller

        group("Palette") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
                ForEach(Palette.all) { palette in
                    PaletteSwatch(palette: palette, isActive: palette == controller.palette) {
                        controller.palette = palette
                    }
                }
            }
        }

        group("Temperature range") {
            Segmented(selection: $controller.scaleMode,
                      options: ScaleMode.allCases.map { ($0, $0.shortTitle) })
            if controller.scaleMode == .manual {
                HStack(spacing: 10) {
                    labelled("From") { TemperatureField(value: $controller.manualLowC, unit: controller.unit) }
                    labelled("To") { TemperatureField(value: $controller.manualHighC, unit: controller.unit) }
                }
                GhostButton(title: "Take from current image", icon: .scan) {
                    controller.adoptCurrentRangeAsManual()
                }
            }
        }

        group("Local contrast") {
            HStack(spacing: 10) {
                BlueprintSlider(value: $controller.contrast)
                Text(verbatim: controller.contrast < 0.01
                     ? String(localized: "off")
                     : String(format: "%.0f%%", controller.contrast * 100))
                    .font(.hpMono(11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }

        group("Geometry & unit") {
            HStack(spacing: 10) {
                iconField(.rotateCw, help: "Rotate 90° clockwise",
                          disabled: controller.isRecordingVideo) {
                    controller.quarterTurns = (controller.quarterTurns + 1) % 4
                }
                iconField(.flipHorizontal, help: "Mirror horizontally",
                          active: controller.mirrored,
                          disabled: controller.isRecordingVideo) {
                    controller.mirrored.toggle()
                }
                Spacer()
                Segmented(selection: $controller.unit,
                          options: TemperatureUnit.allCases.map { ($0, $0.suffix) })
                    .frame(width: 96)
            }
            if controller.isRecordingVideo {
                hint("Orientation is locked while a video is recording — the file has one fixed geometry.")
            }
        }

        group("Burned-in overlay") {
            VStack(spacing: 0) {
                overlayRow(("Timestamp", $controller.overlay.timestamp),
                           ("Scale bar", $controller.overlay.scaleBar))
                Rectangle().fill(Theme.hairline).frame(height: 1)
                overlayRow(("Crosshair", $controller.overlay.crosshair),
                           ("Min/max markers", $controller.overlay.markers))
                Rectangle().fill(Theme.hairline).frame(height: 1)
                overlayRow(("Measurement spots", $controller.overlay.spots),
                           ("Trend curve", $controller.overlay.trend))
                Rectangle().fill(Theme.hairline).frame(height: 1)
                overlayRow(("Readings block", $controller.overlay.readout),
                           ("Cursor reading", $controller.overlay.cursor))
            }
            .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))
            hint("Applies to the window and the OBS source. Photos and video follow the capture setting under Output.")
        }
    }

    private func overlayRow(_ left: (LocalizedStringKey, Binding<Bool>),
                            _ right: (LocalizedStringKey, Binding<Bool>)) -> some View {
        HStack(spacing: 0) {
            OverlayCell(title: left.0, isOn: left.1)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            OverlayCell(title: right.0, isOn: right.1)
        }
    }

    // MARK: - Measure

    @ViewBuilder
    private var measureTab: some View {
        @Bindable var controller = controller

        group("Spots & areas", trailing: "\(controller.spots.count + controller.regions.count) / 13") {
            if controller.spots.isEmpty && controller.regions.isEmpty {
                hint("Click the image for a point, drag for an area. Drag a point or an area to move it.")
            } else {
                ForEach(Array(controller.spots.enumerated()), id: \.element.id) { index, spot in
                    MeasurementCard(
                        color: Color(nsColor: OverlayCompositor.spotColor(index: index)),
                        placeholder: String(localized: "Spot \(index + 1)"),
                        coordinate: "\(spot.rawX), \(spot.rawY)",
                        isArea: false,
                        unit: controller.unit,
                        value: controller.spotReadings.first { $0.id == spot.id }?.tempC,
                        inAlarm: controller.spotReadings.first { $0.id == spot.id }?.inAlarm ?? false,
                        name: Binding(get: { spot.name },
                                      set: { controller.renameSpot(id: spot.id, to: $0) }),
                        alarm: Binding(get: { spot.alarm },
                                       set: { controller.setSpotAlarm(id: spot.id, to: $0) }),
                        onRemove: { controller.removeSpot(id: spot.id) })
                }
                ForEach(Array(controller.regions.enumerated()), id: \.element.id) { index, region in
                    MeasurementCard(
                        color: Color(nsColor: OverlayCompositor.regionColor(index: index)),
                        placeholder: String(localized: "Area \(index + 1)"),
                        coordinate: "\(region.rawMaxX - region.rawMinX)\u{00D7}\(region.rawMaxY - region.rawMinY)",
                        isArea: true,
                        unit: controller.unit,
                        value: controller.regionReadings.first { $0.id == region.id }?.avgC,
                        inAlarm: controller.regionReadings.first { $0.id == region.id }?.inAlarm ?? false,
                        name: Binding(get: { region.name },
                                      set: { controller.renameRegion(id: region.id, to: $0) }),
                        alarm: Binding(get: { region.alarm },
                                       set: { controller.setRegionAlarm(id: region.id, to: $0) }),
                        onRemove: { controller.removeRegion(id: region.id) })
                }
            }
        }

        group("Emissivity") {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: String(format: "%.2f", controller.emissivity.value))
                    .font(.hpReadout(34))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(verbatim: presetName)
                    .font(.hpLabel(12))
                    .tracking(0.8)
                    .foregroundStyle(Theme.accentLine)
            }
            BlueprintSlider(value: $controller.emissivity.value, range: 0.05...1.0)
            // A single-choice list rather than chips: it carries the value each
            // surface stands for, and "No correction" leads it so the neutral
            // setting is one of the choices instead of a slider position.
            VStack(spacing: 0) {
                emissivityChoice(String(localized: "No correction"), 1.0)
                ForEach(Emissivity.presets, id: \.value) { preset in
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    emissivityChoice(preset.name, preset.value)
                }
            }
            .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))
            hint("Shiny surfaces radiate less and read too cold. 1.00 means no correction.")
            if let warning = emissivityWarning {
                Text(verbatim: warning)
                    .font(.hpBody(12))
                    .foregroundStyle(Color(hex: 0xFFD9D6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if !controller.emissivity.isIdentity {
            group("Ambient") {
                TemperatureField(value: $controller.emissivity.reflectedC, unit: controller.unit)
            }
        }

        group("History") {
            Segmented(selection: $controller.trendWindow,
                      options: TemperatureHistory.Window.allCases.map { ($0, $0.label) })
        }

        group("Camera") {
            Segmented(selection: $controller.highGain,
                      options: [(true, gainRange(-20, 150)), (false, gainRange(0, 550))])
            GhostButton(title: "Calibrate shutter", icon: .aperture) {
                controller.triggerShutter()
            }
        }
    }

    private func emissivityChoice(_ title: String, _ value: Double) -> some View {
        ChoiceCell(title: title,
                   detail: String(format: "%.2f", value),
                   isOn: abs(controller.emissivity.value - value) < 0.005) {
            controller.emissivity.value = value
        }
    }

    /// The camera's two ranges are fixed in °C; the labels follow the unit
    /// the rest of the interface is showing.
    private func gainRange(_ low: Double, _ high: Double) -> String {
        controller.unit.number(low, decimals: 0) + "…"
            + controller.unit.format(high, decimals: 0)
    }

    private var presetName: String {
        if controller.emissivity.isIdentity { return String(localized: "No correction") }
        return Emissivity.presets.first { abs($0.value - controller.emissivity.value) < 0.005 }?.name
            ?? String(localized: "Custom")
    }

    /// Shown once the correction's blind spot reaches into temperatures the
    /// camera actually sees, which is where a low emissivity stops being a
    /// refinement and starts dominating the picture.
    private var emissivityWarning: String? {
        let settings = controller.emissivity
        guard let limit = settings.undefinedBelowC, limit > settings.floorC else { return nil }
        let factor = String(format: "%.0f", settings.noiseGain)
        let apparent = controller.unit.format(limit)
        return String(localized: "At this emissivity the correction multiplies any error in the reading about \(factor)×. Below \(apparent) apparent it has no solution at all, and those pixels are held at the end of the measuring range.")
    }

    // MARK: - Output

    @ViewBuilder
    private var outputTab: some View {
        @Bindable var controller = controller

        group("Syphon sources") {
            outputCard(name: "HeatPeek",
                       detail: "Camera picture, carrying whichever image information is switched on.",
                       isOn: $controller.syphonEnabled)
            outputCard(name: "HeatPeek Stats",
                       detail: "Readings and curve on a transparent background.",
                       isOn: $controller.statsSyphonEnabled)
            if controller.statsSyphonEnabled {
                labelled("Stats panel opacity") {
                    BlueprintSlider(value: $controller.statsOpacity, range: 0...0.9)
                        .frame(width: 120)
                }
            }
        }

        group("MJPEG fallback") {
            if controller.mjpegUnavailable {
                Text("The port is already taken — another copy of the app is probably still running.")
                    .font(.hpBody(12))
                    .foregroundStyle(Color(hex: 0xFFD9D6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            outputCard(name: MJPEGServer.displayAddress,
                       detail: "For browsers and tools without Syphon.",
                       isOn: $controller.obsEnabled,
                       mono: true)
        }

        group("Captures") {
            Segmented(selection: $controller.captureWithOverlay,
                      options: [(false, String(localized: "Plain picture")),
                                (true, String(localized: "With overlay"))])
            hint("Applies to saved photos and recorded video.")
        }

        group("Date & time") {
            // The samples run on the clock, so both notations show the same
            // moment and match the stamp the picture is carrying right now.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Segmented(selection: $controller.timestampFormat,
                          options: TimestampFormat.allCases.map {
                              ($0, $0.string(from: context.date))
                          })
            }
            hint("Used for the timestamp drawn into the picture.")
        }

        group("CSV number format") {
            Segmented(selection: $controller.csvFormat,
                      options: SessionRecorder.NumberFormat.allCases.map { ($0, $0.sample) })
        }

        group("Analysis") {
            GhostButton(title: "Open for analysis…", icon: .chartLine) {
                if AnalysisStore.shared.chooseFile() {
                    openWindow(id: AnalysisWindowID.value)
                }
            }
            hint("Reads a recording back as curves, or a saved snapshot as its picture.")
        }

        group("Shortcuts") {
            VStack(spacing: 0) {
                ForEach(Shortcut.all, id: \.keys) { shortcut in
                    HStack {
                        Text(verbatim: shortcut.keys)
                            .font(.hpMono(11))
                            .foregroundStyle(Theme.accentLine)
                            .frame(width: 62, alignment: .leading)
                        Text(shortcut.action)
                            .font(.hpBody(12.5))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                    }
                    .frame(height: 22)
                }
            }
        }
    }

    private func outputCard(name: String, detail: LocalizedStringKey,
                            isOn: Binding<Bool>, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name)
                    .font(mono ? .hpMono(12) : .hpLabel(14))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                Text(detail)
                    .font(.hpBody(12))
                    .foregroundStyle(Theme.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            BlueprintSwitch(isOn: isOn)
        }
        .padding(10)
        .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func group<Content: View>(_ title: LocalizedStringKey, trailing: String? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: title, trailing: trailing)
            content()
        }
    }

    private func labelled<Content: View>(_ title: LocalizedStringKey,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.hpLabel(12))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            content()
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.hpBody(12))
            .foregroundStyle(Theme.label)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func iconField(_ shape: IconShape, help: LocalizedStringKey,
                           active: Bool = false, disabled: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(shape: shape, size: 15)
                .foregroundStyle(disabled ? Theme.label.opacity(0.4)
                                 : (active ? Theme.accentBright : Theme.textSecondary))
                .frame(width: 38, height: 32)
                .background(active ? Theme.accentTint : Color.clear)
                .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// One spot or area: name and current value on top, limits and origin below.
struct MeasurementCard: View {
    let color: Color
    let placeholder: String
    let coordinate: String
    let isArea: Bool
    let unit: TemperatureUnit
    let value: Double?
    let inAlarm: Bool
    @Binding var name: String
    @Binding var alarm: AlarmLimits
    let onRemove: () -> Void

    @State private var showsLimits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Group {
                    if isArea {
                        Rectangle().stroke(color, lineWidth: 1.5)
                    } else {
                        Circle().fill(color)
                    }
                }
                .frame(width: 9, height: 9)

                TextField(placeholder, text: $name)
                    .textFieldStyle(.plain)
                    .font(.hpLabel(14))
                    .foregroundStyle(Theme.text)

                if let value {
                    Text(verbatim: unit.format(value))
                        .font(.hpMono(12))
                        .foregroundStyle(inAlarm ? Color(hex: 0xFF453A) : Theme.text)
                }
            }

            HStack(spacing: 8) {
                Chip(title: alarm.isActive ? limitsText : String(localized: "Limits"),
                     isActive: alarm.isActive,
                     isAlarm: inAlarm) { showsLimits.toggle() }
                Text(verbatim: coordinate)
                    .font(.hpMono(10))
                    .foregroundStyle(Theme.label)
                Spacer()
                Button(action: onRemove) {
                    Icon(shape: .circleMinus, size: 14).foregroundStyle(Theme.label)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }

            if showsLimits {
                HStack(spacing: 8) {
                    LimitField(title: String(localized: "below"), value: $alarm.low, unit: unit)
                    LimitField(title: String(localized: "above"), value: $alarm.high, unit: unit)
                }
            }
        }
        .padding(9)
        .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private var limitsText: String {
        let low = alarm.low.map { unit.number($0) } ?? "—"
        let high = alarm.high.map { unit.number($0) } ?? "—"
        return "\(low) / \(high)"
    }
}

/// Keyboard shortcuts as shown in the inspector.
struct Shortcut {
    let keys: String
    let action: LocalizedStringKey

    static let all: [Shortcut] = [
        Shortcut(keys: "Space", action: "Freeze image"),
        Shortcut(keys: "\u{2318}S", action: "Save snapshot"),
        Shortcut(keys: "\u{2318}R", action: "Record readings"),
        Shortcut(keys: "\u{21E7}\u{2318}R", action: "Record video"),
        Shortcut(keys: "\u{2318}M", action: "Measurements window"),
        Shortcut(keys: "\u{21E7}\u{2318}O", action: "Open for analysis…"),
        Shortcut(keys: "\u{2325}\u{2318}I", action: "Toggle settings"),
    ]
}
