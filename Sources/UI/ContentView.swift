import SwiftUI
import AppKit

/// Main window: the picture is the interface. Everything else floats above it
/// as glass, so the window height belongs to the sensor image.
struct ContentView: View {
    @Environment(CameraController.self) private var controller
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var showsInspector = true
    @State private var controlsAwake = true
    @State private var idleTask: Task<Void, Never>?
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    /// What a drag that began on an existing measurement is moving. Nil while
    /// a drag draws a new area.
    @State private var dragTarget: DragTarget?
    @State private var dragBegan = false
    /// Frames of the floating panels, so labels are never placed behind them.
    @State private var chromeFrames: [CGRect] = []

    var body: some View {
        // The title bar is the top layer rather than a sibling above the
        // stage: as a sibling it stopped taking mouse events once the
        // inspector was toggled while the image kept streaming.
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                stage
                if showsInspector {
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    InspectorPanel()
                        .frame(width: Theme.inspectorWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .padding(.top, Theme.titleBarHeight)
            .animation(.easeOut(duration: 0.18), value: showsInspector)

            TitleBar(showsInspector: $showsInspector) {
                openWindow(id: StatsWindowID.value)
            }
        }
        .background(Theme.windowBackground)
        .onAppear { controller.startAutoConnect() }
        .background(WindowObserver(onClose: { dismissWindow(id: StatsWindowID.value) }))
        .keyboardShortcuts(controller: controller,
                           showsInspector: $showsInspector,
                           openMeasurements: { openWindow(id: StatsWindowID.value) })
    }

    // MARK: - Stage

    private var stage: some View {
        GeometryReader { geo in
            ZStack {
                if let image = controller.image, let frame = controller.frame {
                    let stage = CoordinateSpace.named("stage")
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()

                    // Window decoration only; never burned into any output.
                    vignette

                    overlays(frame: frame, in: geo.size)
                    interaction(frame: frame, in: geo.size)

                    if controller.overlay.scaleBar, let span = controller.scaleSpan {
                        ColorScale(frame: frame, span: span)
                            .reportFrame(in: stage)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            .padding(.trailing, 22)
                    }

                    if controller.overlay.timestamp {
                        Text(verbatim: OverlayCompositor.timestampText(format: controller.timestampFormat))
                            .font(.hpMono(12))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.85), radius: 3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(20)
                            .allowsHitTesting(false)
                    }

                    // One row, so the readings and the controls cannot run
                    // into each other when the window gets narrow.
                    HStack(alignment: .bottom, spacing: 16) {
                        if controller.overlay.readout {
                            ReadoutCard(frame: frame)
                                .reportFrame(in: stage)
                        }
                        Spacer(minLength: 0)
                        ControlBar(isAwake: $controlsAwake)
                            .reportFrame(in: stage)
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                } else {
                    EmptyStateView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: "stage")
            .onPreferenceChange(ChromeFrameKey.self) { chromeFrames = $0 }
            .onContinuousHover { phase in
                if case .active = phase { wakeControls() }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var vignette: some View {
        RadialGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0.40),
                .init(color: Color.black.opacity(0.42), location: 1.0),
            ]),
            center: .center,
            startRadius: 0,
            endRadius: 900)
        .allowsHitTesting(false)
    }

    /// The image fills the stage, so screen positions come from the same
    /// aspect-fill mapping the picture itself uses.
    private func fill(_ size: CGSize, frame: ThermalFrame) -> (scale: CGFloat, origin: CGPoint) {
        let scale = max(size.width / CGFloat(frame.width), size.height / CGFloat(frame.height))
        let origin = CGPoint(x: (size.width - CGFloat(frame.width) * scale) / 2,
                             y: (size.height - CGFloat(frame.height) * scale) / 2)
        return (scale, origin)
    }

    private func point(_ x: Int, _ y: Int, frame: ThermalFrame, in size: CGSize) -> CGPoint {
        let f = fill(size, frame: frame)
        return CGPoint(x: f.origin.x + (CGFloat(x) + 0.5) * f.scale,
                       y: f.origin.y + (CGFloat(y) + 0.5) * f.scale)
    }

    private func sensorPoint(from location: CGPoint, frame: ThermalFrame, in size: CGSize) -> CGPoint? {
        let f = fill(size, frame: frame)
        let x = (location.x - f.origin.x) / f.scale
        let y = (location.y - f.origin.y) / f.scale
        guard x >= 0, y >= 0, x < CGFloat(frame.width), y < CGFloat(frame.height) else { return nil }
        return CGPoint(x: x, y: y)
    }

    // MARK: - Overlays

    @ViewBuilder
    private func overlays(frame: ThermalFrame, in size: CGSize) -> some View {
        if controller.overlay.spots {
            ForEach(controller.regionReadings) { region in
                regionShape(region, frame: frame, in: size)
            }
        }

        ForEach(placedLabels(frame: frame, in: size)) { label in
            label.marker
                .position(label.anchor)
            label.content
                .position(x: label.labelPoint.x, y: label.labelPoint.y)
        }
        .allowsHitTesting(false)

        if controller.overlay.cursor, let reading = controller.hoverReading {
            MarkerPlaque(name: String(localized: "Cursor"),
                         value: controller.unit.format(reading.tempC),
                         color: Theme.accentBright)
                .position(hoverPosition(reading: reading, frame: frame, in: size))
                .allowsHitTesting(false)
        }

        if let start = dragStart, let current = dragCurrent {
            Rectangle()
                .stroke(Theme.accentBright, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: abs(current.x - start.x), height: abs(current.y - start.y))
                .position(x: (start.x + current.x) / 2, y: (start.y + current.y) / 2)
                .allowsHitTesting(false)
        }
    }

    private func hoverPosition(reading: (x: Int, y: Int, tempC: Double),
                               frame: ThermalFrame, in size: CGSize) -> CGPoint {
        let p = point(reading.x, reading.y, frame: frame, in: size)
        return CGPoint(x: p.x, y: max(18, p.y - 20))
    }

    private func regionShape(_ region: RegionReading, frame: ThermalFrame, in size: CGSize) -> some View {
        let a = point(Int(region.rect.minX), Int(region.rect.minY), frame: frame, in: size)
        let b = point(Int(region.rect.maxX), Int(region.rect.maxY), frame: frame, in: size)
        let color = region.inAlarm ? Color(hex: 0xFF453A)
                                   : Color(nsColor: OverlayCompositor.regionColor(index: region.index - 1))
        return Rectangle()
            .stroke(color, lineWidth: 1)
            .frame(width: max(2, b.x - a.x), height: max(2, b.y - a.y))
            .blueprintFrame(color: color, opacity: 0.9, length: 5, inset: 0, showsBorder: false)
            .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            .allowsHitTesting(false)
    }

    /// A marker with its resolved label position.
    private struct PlacedLabel: Identifiable {
        let id: String
        let anchor: CGPoint
        let labelPoint: CGPoint
        let marker: AnyView
        let content: AnyView
    }

    /// Spots and areas keep their preferred position; the fixed crosshair goes
    /// next, and the min/max markers give way last because they chase noise.
    private func placedLabels(frame: ThermalFrame, in size: CGSize) -> [PlacedLabel] {
        var placer = LabelPlacer(bounds: CGRect(origin: .zero, size: size))
        for chrome in chromeFrames { placer.reserve(chrome) }
        var result: [PlacedLabel] = []
        let labelHeight: CGFloat = 20

        func place(id: String, anchor: CGPoint, width: CGFloat,
                   marker: AnyView, content: AnyView) {
            let limit = size.width - 60
            let fitsRight = anchor.x + 14 + width <= limit
            let x = fitsRight ? anchor.x + 14 : anchor.x - 14 - width
            let preferred = CGRect(x: x, y: anchor.y - labelHeight / 2,
                                   width: width, height: labelHeight)
            let rect = placer.place(preferred, step: labelHeight + 4)
            result.append(PlacedLabel(id: id, anchor: anchor,
                                      labelPoint: CGPoint(x: rect.midX, y: rect.midY),
                                      marker: marker, content: content))
        }

        if controller.overlay.spots {
            for region in controller.regionReadings {
                let anchor = point(Int(region.rect.minX), Int(region.rect.minY), frame: frame, in: size)
                let color = region.inAlarm ? Color(hex: 0xFF453A)
                                           : Color(nsColor: OverlayCompositor.regionColor(index: region.index - 1))
                let text = "\u{00F8}" + controller.unit.number(region.avgC)
                    + "  \u{25B2}" + controller.unit.format(region.maxC)
                place(id: "area-\(region.id)", anchor: anchor,
                      width: CGFloat(region.label.count) * 7 + CGFloat(text.count) * 7 + 26,
                      marker: AnyView(EmptyView()),
                      content: AnyView(MarkerPlaque(name: region.label, value: text, color: color)))
            }
            for spot in controller.spotReadings {
                let anchor = point(spot.x, spot.y, frame: frame, in: size)
                let color = spot.inAlarm ? Color(hex: 0xFF453A)
                                         : Color(nsColor: OverlayCompositor.spotColor(index: spot.index - 1))
                let text = controller.unit.format(spot.tempC)
                place(id: "spot-\(spot.id)", anchor: anchor,
                      width: CGFloat(spot.label.count) * 7 + CGFloat(text.count) * 7 + 26,
                      marker: AnyView(MarkerDot(color: color)),
                      content: AnyView(MarkerPlaque(name: spot.label, value: text, color: color)))
            }
        }

        if controller.overlay.crosshair,
           let center = frame.temperatureC(x: frame.width / 2, y: frame.height / 2) {
            let anchor = CGPoint(x: size.width / 2, y: size.height / 2)
            place(id: "crosshair", anchor: anchor, width: 74,
                  marker: AnyView(CrosshairMark()),
                  content: AnyView(MarkerText(value: controller.unit.format(center), color: .white)))
        }

        if controller.overlay.markers {
            let maxPoint = point(frame.maxIndex % frame.width, frame.maxIndex / frame.width,
                                 frame: frame, in: size)
            place(id: "max", anchor: maxPoint, width: 74,
                  marker: AnyView(MarkerDot(color: Color(hex: 0xFF453A), size: 9)),
                  content: AnyView(MarkerText(value: controller.unit.format(frame.maxC),
                                              color: Color(hex: 0xFF453A))))
            let minPoint = point(frame.minIndex % frame.width, frame.minIndex / frame.width,
                                 frame: frame, in: size)
            place(id: "min", anchor: minPoint, width: 74,
                  marker: AnyView(MarkerDot(color: Color(hex: 0x0A84FF), size: 9)),
                  content: AnyView(MarkerText(value: controller.unit.format(frame.minC),
                                              color: Color(hex: 0x0A84FF))))
        }
        return result
    }

    // MARK: - Interaction

    private func interaction(frame: ThermalFrame, in size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let p = sensorPoint(from: location, frame: frame, in: size)
                    controller.hoverPoint = p
                    if dragTarget == nil {
                        (p.flatMap(target(at:)) != nil ? NSCursor.openHand : NSCursor.arrow).set()
                    }
                    wakeControls()
                case .ended:
                    controller.hoverPoint = nil
                    NSCursor.arrow.set()
                }
            }
            // Click and drag share one gesture: a separate tap gesture would
            // win the mouse-up and cancel the drag before it ends. Where the
            // drag begins decides what it does — on a spot or an area it moves
            // that, on open picture it draws a new area.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let start = sensorPoint(from: value.startLocation, frame: frame, in: size)
                        else { return }
                        if !dragBegan {
                            dragBegan = true
                            dragTarget = target(at: start)
                        }
                        guard value.travelled >= Self.dragThreshold else { return }
                        wakeControls()
                        switch dragTarget {
                        case .spot(let id):
                            NSCursor.closedHand.set()
                            if let p = sensorPoint(from: value.location, frame: frame, in: size) {
                                controller.moveSpot(id: id, toDisplayX: Int(p.x), y: Int(p.y))
                            }
                        case .region(let id, let origin):
                            NSCursor.closedHand.set()
                            let scale = fill(size, frame: frame).scale
                            let dx = (value.location.x - value.startLocation.x) / scale
                            let dy = (value.location.y - value.startLocation.y) / scale
                            controller.moveRegion(id: id,
                                                  toDisplayX: Int((origin.x + dx).rounded()),
                                                  y0: Int((origin.y + dy).rounded()))
                        case nil:
                            if dragStart == nil { dragStart = value.startLocation }
                            dragCurrent = value.location
                        }
                    }
                    .onEnded { value in
                        defer {
                            dragStart = nil; dragCurrent = nil
                            dragTarget = nil; dragBegan = false
                            NSCursor.arrow.set()
                        }
                        guard let a = sensorPoint(from: value.startLocation, frame: frame, in: size)
                        else { return }
                        guard value.travelled >= Self.dragThreshold else {
                            controller.toggleSpot(atDisplayX: Int(a.x), y: Int(a.y))
                            return
                        }
                        guard dragTarget == nil,
                              let b = sensorPoint(from: value.location, frame: frame, in: size) else { return }
                        controller.addRegion(fromDisplayX: Int(a.x), y0: Int(a.y),
                                             toDisplayX: Int(b.x), y1: Int(b.y))
                    }
            )
    }

    private enum DragTarget: Equatable {
        case spot(UUID)
        case region(UUID, origin: CGPoint)
    }

    /// The measurement under a display point, spots before areas because they
    /// are the smaller target.
    private func target(at p: CGPoint) -> DragTarget? {
        if let id = controller.spotID(nearDisplayX: Int(p.x), y: Int(p.y)) { return .spot(id) }
        if let id = controller.regionID(containingDisplayX: Int(p.x), y: Int(p.y)),
           let reading = controller.regionReadings.first(where: { $0.id == id }) {
            return .region(id, origin: reading.rect.origin)
        }
        return nil
    }

    /// Below this travel a gesture counts as a click on a point rather than a
    /// drag for an area.
    private static let dragThreshold: CGFloat = 12

    private func wakeControls() {
        if !controlsAwake { controlsAwake = true }
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            if !controller.frozen && !controller.isRecording && !controller.isRecordingVideo {
                controlsAwake = false
            }
        }
    }
}

/// Keyboard shortcuts live on hidden buttons so they stay available without a
/// visible toolbar.
private extension View {
    func keyboardShortcuts(controller: CameraController,
                           showsInspector: Binding<Bool>,
                           openMeasurements: @escaping () -> Void) -> some View {
        background {
            VStack {
                Button("") { controller.frozen.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { controller.saveSnapshot() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("") { controller.toggleRecording() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("") { controller.toggleVideoRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("") { openMeasurements() }
                    .keyboardShortcut("m", modifiers: .command)
                Button("") { showsInspector.wrappedValue.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }
}

private extension DragGesture.Value {
    /// Straight-line distance from where the gesture started.
    var travelled: CGFloat {
        let dx = location.x - startLocation.x
        let dy = location.y - startLocation.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Collects the frames of the floating panels so overlay labels can dodge them.
private struct ChromeFrameKey: PreferenceKey {
    static var defaultValue: [CGRect] { [] }
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func reportFrame(in space: CoordinateSpace) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: ChromeFrameKey.self, value: [geo.frame(in: space)])
            }
        )
    }
}
