import Foundation
import SwiftUI
import Observation

/// Minimal thread-safe boolean, shared between the UI and the capture thread.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ initial: Bool = false) { value = initial }
    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ newValue: Bool) {
        lock.lock(); value = newValue; lock.unlock()
    }
}

/// Camera commands queued by the UI and executed on the capture thread, so
/// every USB access happens on the one thread that owns the device. This also
/// removes the race where a command could touch an interface that teardown had
/// already released.
final class CameraCommandQueue: @unchecked Sendable {
    enum Command {
        case shutter
        case gain(high: Bool)
    }

    private let lock = NSLock()
    private var pending: [Command] = []

    func push(_ command: Command) {
        lock.lock(); pending.append(command); lock.unlock()
    }

    /// Removes and returns everything queued so far.
    func drain() -> [Command] {
        lock.lock(); defer { lock.unlock() }
        let commands = pending
        pending.removeAll()
        return commands
    }
}


/// Everything the capture thread needs to turn a raw frame into a finished
/// picture. Kept in a lock-protected box so no MainActor state is read from
/// the capture thread.
struct FrameRenderConfig: Equatable {
    var quarterTurns = 0
    var mirrored = false
    var paletteID = Palette.plasma.id
    var scaleMode = ScaleMode.camera
    var manualLowC = 20.0
    var manualHighC = 60.0
    var emissivity = Emissivity()
    var contrast = 0.0

    var palette: Palette {
        Palette.all.first { $0.id == paletteID } ?? .plasma
    }
}

final class RenderConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = FrameRenderConfig()

    var current: FrameRenderConfig {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: FrameRenderConfig) {
        lock.lock(); value = newValue; lock.unlock()
    }
}

/// A frame after all pixel work is done — produced on the capture thread.
struct RenderedFrame: @unchecked Sendable {
    /// Emissivity-corrected, still in sensor orientation (for measurements).
    let raw: ThermalFrame
    /// Rotated/mirrored, as displayed.
    let display: ThermalFrame
    let image: CGImage?
    /// The camera gain's mapping, recovered from this frame. Only built under
    /// that mode, and here rather than on the main actor: it is a pass over
    /// every pixel.
    let scaleCurve: [Double]?
}


/// What the capture thread needs to burn the overlay in and publish, captured
/// on the main actor after each frame. The stream therefore shows labels from
/// the previous frame — 40 ms old, invisible in practice, and it keeps the
/// expensive compositing off the main thread.
struct OverlaySnapshot: @unchecked Sendable {
    var options = OverlayOptions()
    var paletteID = Palette.plasma.id
    var spots: [SpotReading] = []
    var regions: [RegionReading] = []
    var hover: (x: Int, y: Int, tempC: Double)?
    var trend: TemperatureHistory.Layout?
    var wantsSyphon = false
    var wantsMJPEG = false
    var wantsStats = false
    var wantsVideo = false
    /// Overlay options for the video; may differ from the stream's.
    var videoOptions = OverlayOptions()
    var videoTrend = false
    var unit = TemperatureUnit.celsius
    var statsOpacity = 0.55
    var statsRows: [StatsRenderer.Row] = []
    /// The readings block, when it is burned into the picture.
    var readoutRows: [ReadoutRow] = []
    /// What the burned-in scale bar should be labelled with.
    var scale = ScaleSpan(lowC: 0, highC: 1, curve: nil)
    var timestampFormat = TimestampFormat.european
    /// The reading that tripped an alarm, marked on the scale bar.
    var alarmC: Double?

    var palette: Palette { Palette.all.first { $0.id == paletteID } ?? .plasma }
    var needsComposite: Bool { wantsSyphon || wantsMJPEG || wantsVideo }
}

final class OverlaySnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = OverlaySnapshot()
    var current: OverlaySnapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ newValue: OverlaySnapshot) {
        lock.lock(); value = newValue; lock.unlock()
    }
}

/// One line of the readout card.
/// One line of the readings block. Shared by the window's card and the
/// burned-in overlay, so the two cannot drift apart.
struct ReadoutRow: Identifiable {
    let id: String
    let name: String
    let value: Double
    let color: NSColor
    let isArea: Bool
    let inAlarm: Bool
}

/// Connection state machine and capture loop; publishes frames to the UI.
@MainActor
@Observable
final class CameraController {
    static let shared = CameraController()

    enum State: Equatable {
        case disconnected
        case connecting
        case streaming
        case error(String)

        var label: String {
            switch self {
            case .disconnected: return String(localized: "Not connected")
            case .connecting: return String(localized: "Connecting…")
            case .streaming: return String(localized: "Live")
            case .error(let msg): return msg
            }
        }
    }

    private(set) var state: State = .disconnected
    private(set) var frame: ThermalFrame?
    private(set) var image: CGImage?
    private(set) var deviceInfo: P3DeviceInfo?
    private(set) var modelName: String = ""
    private(set) var fps: Double = 0

    var palette: Palette = .plasma {
        didSet {
            UserDefaults.standard.set(palette.id, forKey: "paletteID")
            rerender()
            syncRenderConfig()
        }
    }
    var highGain: Bool = true {
        didSet {
            setGain(high: highGain)
            emissivity.floorC = Self.measuringFloorC(highGain: highGain)
        }
    }

    /// Lower end of the camera's measuring range for the selected gain.
    private static func measuringFloorC(highGain: Bool) -> Double {
        highGain ? -20 : 0
    }
    var frozen: Bool = false

    /// Clockwise 90° rotation steps applied to the displayed image.
    var quarterTurns: Int = 0 {
        didSet {
            UserDefaults.standard.set(quarterTurns, forKey: "quarterTurns")
            retransform()
            syncRenderConfig()
        }
    }
    /// Horizontal mirror, applied after rotation.
    var mirrored: Bool = false {
        didSet {
            UserDefaults.standard.set(mirrored, forKey: "mirrored")
            retransform()
            syncRenderConfig()
        }
    }
    /// How far back the trend overlay reaches.
    var trendWindow: TemperatureHistory.Window = .m2 {
        didSet {
            UserDefaults.standard.set(trendWindow.rawValue, forKey: "trendWindow")
            refreshTrendLayout()
        }
    }
    /// Whether saved photos and recorded video carry the overlay or show the
    /// plain picture. One setting for both — it is the same decision.
    /// How the burned-in timestamp is written.
    var timestampFormat: TimestampFormat = .european {
        didSet {
            UserDefaults.standard.set(timestampFormat.rawValue, forKey: "timestampFormat")
        }
    }
    var captureWithOverlay: Bool = false {
        didSet { UserDefaults.standard.set(captureWithOverlay, forKey: "captureWithOverlay") }
    }
    /// Decimal separator used by both CSV exports.
    var csvFormat: SessionRecorder.NumberFormat = .german {
        didSet { UserDefaults.standard.set(csvFormat.rawValue, forKey: "csvFormat") }
    }

    /// The trend curve, recomputed only when a new sample arrives (5 Hz).
    /// Deriving it inside the view body would rebuild it at the full frame
    /// rate over hundreds of samples.
    private(set) var trendLayout: TemperatureHistory.Layout?
    private(set) var isRecording = false
    private(set) var recordedRows = 0
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var recordingFileName: String?
    /// True while the separate measurements window is open — the panel under
    /// the image is then redundant and gets hidden.
    var statsWindowOpen = false
    private(set) var isRecordingVideo = false
    private(set) var videoDuration: TimeInterval = 0
    private(set) var videoFrameCount = 0

    let history = TemperatureHistory()
    private let recorder = SessionRecorder()
    /// User-placed measurement spots (raw sensor coordinates).
    var spots: [MeasureSpot] = [] {
        didSet { refreshReadings() }
    }
    /// Cursor position in display sensor coordinates, or nil when not hovering.
    var hoverPoint: CGPoint?
    /// Publish the live image as a Syphon server — the low-latency path into
    /// OBS (shared GPU texture, no encode/decode).
    var syphonEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(syphonEnabled, forKey: "syphonEnabled")
            if syphonEnabled { syphonPublisher.start() } else { syphonPublisher.stop() }
        }
    }
    /// Publish the statistics as a second Syphon source, so OBS can place the
    /// numbers independently of the camera picture.
    var statsSyphonEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(statsSyphonEnabled, forKey: "statsSyphonEnabled")
            if statsSyphonEnabled { statsPublisher.start() } else { statsPublisher.stop() }
        }
    }
    /// Serve the live image as MJPEG on localhost — fallback for browsers and
    /// anything that cannot consume Syphon.
    var obsEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(obsEnabled, forKey: "obsEnabled")
            if obsEnabled {
                mjpegUnavailable = false
                mjpegServer.start()
            } else {
                mjpegServer.stop()
            }
        }
    }
    /// Surface emissivity applied to the whole frame.
    var emissivity = Emissivity() {
        didSet {
            let d = UserDefaults.standard
            d.set(emissivity.value, forKey: "emissivity")
            d.set(emissivity.reflectedC, forKey: "reflectedC")
            emissivityTable.update(emissivity)
            syncRenderConfig()
            refreshReadings()
        }
    }
    /// How temperatures are mapped to colours.
    var scaleMode: ScaleMode = .camera {
        didSet {
            UserDefaults.standard.set(scaleMode.rawValue, forKey: "scaleMode")
            rerender()
            syncRenderConfig()
        }
    }
    var manualLowC: Double = 20 {
        didSet {
            UserDefaults.standard.set(manualLowC, forKey: "manualLowC")
            rerender(); syncRenderConfig()
        }
    }
    var manualHighC: Double = 60 {
        didSet {
            UserDefaults.standard.set(manualHighC, forKey: "manualHighC")
            rerender(); syncRenderConfig()
        }
    }
    /// Area measurements (raw sensor coordinates).
    var regions: [MeasureRegion] = [] {
        didSet { refreshReadings() }
    }

    private let emissivityTable = EmissivityTable()

    /// Display unit for every temperature shown or written out.
    var unit: TemperatureUnit = .celsius {
        didSet {
            UserDefaults.standard.set(unit.rawValue, forKey: "unit")
            syncRenderConfig()
        }
    }
    /// CLAHE strength, 0 = off.
    var contrast: Double = 0 {
        didSet {
            UserDefaults.standard.set(contrast, forKey: "contrast")
            syncRenderConfig()
            rerender()
        }
    }

    /// The one set of overlay options. What is set here applies to the app
    /// window, the OBS source, saved snapshots and recorded video alike.
    /// Separate per-output views would be a later feature, not a second set of
    /// switches for the same thing.
    var overlay = OverlayOptions() {
        didSet {
            overlay.save(withPrefix: "overlay")
            refreshTrendLayout()
        }
    }
    /// Panel opacity of the stats source, so it can sit over the picture.
    var statsOpacity: Double = 0.55 {
        didSet { UserDefaults.standard.set(statsOpacity, forKey: "statsOpacity") }
    }
    /// True while the user has explicitly powered the camera off in the app.
    private(set) var userWantsOff = false

    private let mjpegServer = MJPEGServer()

    /// Set when the stream could not take its port — almost always another
    /// copy of the app still holding it.
    private(set) var mjpegUnavailable = false
    private let syphonPublisher = SyphonPublisher(name: "HeatPeek")
    private let statsPublisher = SyphonPublisher(name: "HeatPeek Stats")
    private let commandQueue = CameraCommandQueue()
    private let videoRecorder = VideoRecorder()
    private let renderConfig = RenderConfigBox()
    private let overlaySnapshot = OverlaySnapshotBox()

    /// The camera gain's mapping for the frame on screen, when that mode is
    /// active. Recovered on the capture thread.
    private var scaleCurve: [Double]?

    /// Last frame as delivered by the sensor, before rotation/mirroring.
    private var rawFrame: ThermalFrame?
    private var camera: P3Camera?
    private var captureThread: Thread?
    private var retryTimer: Timer?

    /// Owned by the capture thread; the UI only signals through these flags so
    /// USB teardown always happens on the thread that is doing the reading.
    private let stopFlag = AtomicFlag()
    private let resetOnStopFlag = AtomicFlag()
    private let captureFinishedFlag = AtomicFlag(true)
    /// Guards against queueing frames faster than the UI consumes them.
    private let deliveryInFlight = AtomicFlag()
    private let statsRenderInFlight = AtomicFlag()
    /// True once a stream has run, i.e. the camera is in acquire mode.
    private var everStreamed = false

    private var fpsWindowStart = Date()
    private var fpsFrameCount = 0

    init() {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "paletteID"),
           let saved = Palette.all.first(where: { $0.id == id }) {
            palette = saved
        }
        quarterTurns = defaults.integer(forKey: "quarterTurns")
        mirrored = defaults.bool(forKey: "mirrored")
        mjpegServer.onFailure = { [weak self] in
            Task { @MainActor in
                self?.mjpegUnavailable = true
                self?.obsEnabled = false
            }
        }
        obsEnabled = defaults.bool(forKey: "obsEnabled")
        syphonEnabled = defaults.object(forKey: "syphonEnabled") as? Bool ?? true
        if let raw = defaults.string(forKey: "trendWindow"),
           let w = TemperatureHistory.Window(rawValue: raw) {
            trendWindow = w
        }
        if let raw = defaults.string(forKey: "csvFormat"),
           let f = SessionRecorder.NumberFormat(rawValue: raw) {
            csvFormat = f
        }
        // didSet does not fire during init
        statsSyphonEnabled = defaults.bool(forKey: "statsSyphonEnabled")
        overlay = OverlayOptions(loadingWithPrefix: "overlay")
        emissivity = Emissivity(
            value: defaults.object(forKey: "emissivity") as? Double ?? 1.0,
            reflectedC: defaults.object(forKey: "reflectedC") as? Double ?? 20.0,
            floorC: Self.measuringFloorC(highGain: highGain))
        emissivityTable.update(emissivity)
        if let raw = defaults.string(forKey: "scaleMode"), let m = ScaleMode(rawValue: raw) {
            scaleMode = m
        }
        manualLowC = defaults.object(forKey: "manualLowC") as? Double ?? 20
        manualHighC = defaults.object(forKey: "manualHighC") as? Double ?? 60
        if let raw = defaults.string(forKey: "unit"), let u = TemperatureUnit(rawValue: raw) {
            unit = u
        }
        contrast = defaults.object(forKey: "contrast") as? Double ?? 0
        captureWithOverlay = defaults.bool(forKey: "captureWithOverlay")
        if let raw = defaults.string(forKey: "timestampFormat"),
           let f = TimestampFormat(rawValue: raw) {
            timestampFormat = f
        }
        statsOpacity = defaults.object(forKey: "statsOpacity") as? Double ?? 0.55
        if obsEnabled { mjpegServer.start() }
        if syphonEnabled { syphonPublisher.start() }
        if statsSyphonEnabled { statsPublisher.start() }
        syncRenderConfig()
    }

    // MARK: - Connection

    func startAutoConnect() {
        // Connecting with nothing attached would surface a USB error where the
        // honest answer is simply that no camera is plugged in yet.
        if P3Camera.isDevicePresent() { connect() } else { state = .disconnected }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.userWantsOff else { return }
                if case .streaming = self.state { return }
                if case .connecting = self.state { return }
                if P3Camera.isDevicePresent() { self.connect() }
            }
        }
    }

    /// Power button: stop the stream and reset the USB device so the camera
    /// leaves acquire mode (that is what actually stops the shutter clicking),
    /// or reconnect.
    func powerToggle() {
        if userWantsOff {
            userWantsOff = false
            connect()
        } else {
            userWantsOff = true
            disconnect(resetDevice: true)
        }
    }

    func connect() {
        guard state != .connecting, captureFinishedFlag.isSet else { return }
        state = .connecting
        stopFlag.set(false)
        resetOnStopFlag.set(false)
        captureFinishedFlag.set(false)

        let thread = Thread { [weak self] in
            self?.captureLoop()
        }
        thread.name = "P3 Capture"
        thread.qualityOfService = .userInteractive
        captureThread = thread
        thread.start()
    }

    /// Signals the capture thread to tear down. USB teardown (and the optional
    /// device reset) runs on the capture thread, never here.
    func disconnect(resetDevice: Bool = false) {
        resetOnStopFlag.set(resetDevice)
        stopFlag.set(true)
        camera = nil
        state = .disconnected
    }

    /// Blocking shutdown for app termination: stop the stream, wait for the
    /// capture thread to release the USB interfaces, then reset the device so
    /// the camera stops clicking after the app is gone.
    func shutdownSynchronously() {
        let wasRunning = !captureFinishedFlag.isSet
        if wasRunning {
            resetOnStopFlag.set(everStreamed)
            stopFlag.set(true)
            let deadline = Date().addingTimeInterval(3.0)
            while !captureFinishedFlag.isSet && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
        } else if everStreamed {
            try? P3Camera.resetAttachedDevice()
        }
        if isRecordingVideo {
            isRecordingVideo = false
            let done = DispatchSemaphore(value: 0)
            videoRecorder.finish { _ in done.signal() }
            _ = done.wait(timeout: .now() + 5)
        }
        mjpegServer.stop()
        syphonPublisher.stop()
        statsPublisher.stop()
    }

    // MARK: - Camera actions

    func triggerShutter() {
        commandQueue.push(.shutter)
    }

    private func setGain(high: Bool) {
        commandQueue.push(.gain(high: high))
    }

    /// Runs queued commands on the capture thread, between frame reads.
    private nonisolated func applyPendingCommands(to cam: P3Camera) {
        for command in commandQueue.drain() {
            switch command {
            case .shutter: try? cam.triggerShutter()
            case .gain(let high): try? cam.setGain(high: high)
            }
        }
    }

    // MARK: - Capture loop (runs on capture thread)

    private nonisolated func captureLoop() {
        var openedCamera: P3Camera?
        do {
            let cam = try P3Camera.open()
            openedCamera = cam
            try cam.readDeviceInfo()
            try cam.startStreaming()

            Task { @MainActor in
                self.camera = cam
                self.deviceInfo = cam.info
                self.modelName = cam.model.name
                self.everStreamed = true
                self.state = .streaming
                self.fpsWindowStart = Date()
                self.fpsFrameCount = 0
            }

            _ = commandQueue.drain() // discard anything queued while disconnected

            var buffer = [UInt8](repeating: 0, count: cam.model.frameReadSize)
            // All per-pixel work happens here, on the capture thread. Doing it
            // on the main actor saturated it and froze the UI.
            let localTable = EmissivityTable()

            while !stopFlag.isSet {
                // A manually created Thread has no autorelease pool of its own.
                // Rendering and compositing create CoreGraphics and AppKit
                // objects on every frame, so without draining a pool here they
                // pile up until the process runs out of memory — roughly
                // 180 MB per minute, which a long recording would not survive.
                try autoreleasepool {
                    applyPendingCommands(to: cam)
                    guard try cam.readFrame(into: &buffer) else { return }
                    let parsed = ThermalFrame.parse(buffer: buffer, model: cam.model)

                    let config = renderConfig.current
                    localTable.update(config.emissivity)
                    let corrected = correctedFrame(parsed, table: localTable)
                    let display = corrected.transformed(quarterTurns: config.quarterTurns,
                                                        mirrored: config.mirrored)
                    let rendered = RenderedFrame(
                        raw: corrected,
                        display: display,
                        image: ThermalRenderer.render(frame: display, palette: config.palette,
                                                      mode: config.scaleMode,
                                                      manualRange: config.manualLowC...config.manualHighC,
                                                      contrast: config.contrast),
                        scaleCurve: config.scaleMode == .camera ? display.brightnessCurve() : nil)

                    publishToStreams(rendered, snapshot: overlaySnapshot.current)

                    // Skip the hand-off while the UI is still busy with the
                    // previous frame instead of letting the queue grow.
                    if !deliveryInFlight.isSet {
                        deliveryInFlight.set(true)
                        Task { @MainActor in
                            self.receive(rendered)
                            self.deliveryInFlight.set(false)
                        }
                    }
                }
            }
        } catch {
            Task { @MainActor in
                guard !self.stopFlag.isSet else { return } // deliberate disconnect
                self.camera = nil
                self.state = .error(error.localizedDescription)
            }
        }

        // Teardown always happens here, on the thread that owns the USB I/O.
        openedCamera?.close()
        openedCamera = nil
        if resetOnStopFlag.isSet {
            try? P3Camera.resetAttachedDevice()
        }
        captureFinishedFlag.set(true)
    }

    // MARK: - Measurement spots

    /// Resolves all spots against the current frame (display coordinates + live temperature).
    /// Cached so the per-pixel area statistics run once per frame instead of
    /// on every call site that reads them.
    private(set) var spotReadings: [SpotReading] = []
    private(set) var regionReadings: [RegionReading] = []

    private func computeSpotReadings() -> [SpotReading] {
        guard let raw = rawFrame else { return [] }
        return spots.enumerated().compactMap { index, spot in
            guard spot.rawX >= 0, spot.rawX < raw.width,
                  spot.rawY >= 0, spot.rawY < raw.height else { return nil }
            var temp = ThermalFrame.celsius(fromRaw: raw.tempRaw[spot.rawY * raw.width + spot.rawX])
            // A per-spot emissivity re-does the correction for that pixel only,
            // starting from the value the global setting already produced.
            if let own = spot.emissivity, abs(own - emissivity.value) > 0.001 {
                var local = emissivity
                local.value = own
                temp = ThermalFrame.celsius(fromRaw: local.correct(
                    raw: raw.tempRaw[spot.rawY * raw.width + spot.rawX]))
            }
            let (dx, dy) = displayCoord(rawX: spot.rawX, rawY: spot.rawY, rawW: raw.width, rawH: raw.height)
            return SpotReading(id: spot.id, index: index + 1, name: spot.name,
                               x: dx, y: dy, tempC: temp,
                               inAlarm: spot.alarm.triggered(by: temp))
        }
    }

    /// Area measurements resolved against the current frame.
    private func computeRegionReadings() -> [RegionReading] {
        guard let raw = rawFrame, let display = frame else { return [] }
        return regions.enumerated().compactMap { index, region in
            guard let stats = raw.statistics(inX: region.rawMinX, y0: region.rawMinY,
                                             x1: region.rawMaxX, y1: region.rawMaxY) else { return nil }
            // Both corners go through the same transform as the spots, then the
            // rectangle is rebuilt from whichever corners ended up where.
            let a = displayCoord(rawX: region.rawMinX, rawY: region.rawMinY,
                                 rawW: raw.width, rawH: raw.height)
            let b = displayCoord(rawX: region.rawMaxX, rawY: region.rawMaxY,
                                 rawW: raw.width, rawH: raw.height)
            let rect = CGRect(x: CGFloat(min(a.0, b.0)), y: CGFloat(min(a.1, b.1)),
                              width: CGFloat(abs(b.0 - a.0)), height: CGFloat(abs(b.1 - a.1)))
            _ = display
            return RegionReading(id: region.id, index: index + 1, name: region.name,
                                 rect: rect, minC: stats.minC, maxC: stats.maxC, avgC: stats.avgC,
                                 inAlarm: region.alarm.triggered(by: stats.maxC)
                                       || region.alarm.triggered(by: stats.minC))
        }
    }

    /// Sensor geometry as shown in the title bar.
    var sensorDescription: String {
        guard let raw = rawFrame else { return "" }
        return "\(raw.width)x\(raw.height)"
    }

    /// Elapsed time of the running CSV recording, mm:ss.
    var recordingClock: String {
        let total = Int(recordingDuration)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Elapsed time of the running video recording, mm:ss.
    var videoClock: String {
        let total = Int(videoDuration)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// The value that tripped an alarm, used to place a mark on the scale.
    var alarmValue: Double? {
        if let spot = spotReadings.first(where: \.inAlarm) { return spot.tempC }
        if let region = regionReadings.first(where: \.inAlarm) { return region.maxC }
        return nil
    }

    /// One row per measurement for the readout card, in display order.
    var readoutRows: [ReadoutRow] {
        guard let frame else { return [] }
        var rows: [ReadoutRow] = []
        if overlay.crosshair,
           let center = frame.temperatureC(x: frame.width / 2, y: frame.height / 2) {
            rows.append(ReadoutRow(id: "crosshair", name: String(localized: "Crosshair"),
                                   value: center, color: .white, isArea: false, inAlarm: false))
        }
        for reading in spotReadings {
            rows.append(ReadoutRow(
                id: "spot-\(reading.id)",
                name: reading.name.isEmpty ? String(localized: "Spot \(reading.index)") : reading.name,
                value: reading.tempC,
                color: OverlayCompositor.spotColor(index: reading.index - 1),
                isArea: false,
                inAlarm: reading.inAlarm))
        }
        for reading in regionReadings {
            rows.append(ReadoutRow(
                id: "area-\(reading.id)",
                name: reading.name.isEmpty ? String(localized: "Area \(reading.index)") : reading.name,
                value: reading.avgC,
                color: OverlayCompositor.regionColor(index: reading.index - 1),
                isArea: true,
                inAlarm: reading.inAlarm))
        }
        return rows
    }

    /// Recomputes the resolved measurements. Call whenever the frame, the
    /// measurement list, the orientation or the emissivity changed.
    /// Mirrors the render-relevant settings into the box the capture thread reads.
    private func syncRenderConfig() {
        renderConfig.set(FrameRenderConfig(
            quarterTurns: quarterTurns,
            mirrored: mirrored,
            paletteID: palette.id,
            scaleMode: scaleMode,
            manualLowC: min(manualLowC, manualHighC),
            manualHighC: max(manualLowC, manualHighC) + 0.5,
            emissivity: emissivity,
            contrast: contrast))
    }

    private func refreshReadings() {
        spotReadings = computeSpotReadings()
        regionReadings = computeRegionReadings()
    }

    /// True while any measurement is outside its limits.
    var hasAlarm: Bool {
        spotReadings.contains(where: \.inAlarm) || regionReadings.contains(where: \.inAlarm)
    }

    /// Live temperature under the cursor, in display sensor coordinates.
    var hoverReading: (x: Int, y: Int, tempC: Double)? {
        guard let p = hoverPoint, let display = frame,
              let temp = display.temperatureC(x: Int(p.x), y: Int(p.y)) else { return nil }
        return (Int(p.x), Int(p.y), temp)
    }

    /// Adds a spot at the clicked position, or removes an existing one nearby.
    func toggleSpot(atDisplayX x: Int, y: Int) {
        guard let raw = rawFrame else { return }
        if let existing = spots.firstIndex(where: { spot in
            let (dx, dy) = displayCoord(rawX: spot.rawX, rawY: spot.rawY, rawW: raw.width, rawH: raw.height)
            return abs(dx - x) <= 10 && abs(dy - y) <= 10
        }) {
            spots.remove(at: existing)
            return
        }
        guard spots.count < 9 else { return }
        let (rx, ry) = rawCoord(displayX: x, displayY: y, rawW: raw.width, rawH: raw.height)
        spots.append(MeasureSpot(rawX: rx, rawY: ry))
    }

    /// The spot under a display point, within the same reach a click uses.
    func spotID(nearDisplayX x: Int, y: Int) -> UUID? {
        guard let raw = rawFrame else { return nil }
        return spots.first { spot in
            let (dx, dy) = displayCoord(rawX: spot.rawX, rawY: spot.rawY, rawW: raw.width, rawH: raw.height)
            return abs(dx - x) <= 10 && abs(dy - y) <= 10
        }?.id
    }

    /// The area containing a display point. The last one drawn wins where
    /// areas overlap, since it sits on top.
    func regionID(containingDisplayX x: Int, y: Int) -> UUID? {
        regionReadings.last { $0.rect.contains(CGPoint(x: CGFloat(x), y: CGFloat(y))) }?.id
    }

    /// Display-space size of the frame, which swaps with a quarter turn.
    private var displaySize: (width: Int, height: Int)? {
        guard let raw = rawFrame else { return nil }
        return normalizedTurns % 2 == 0 ? (raw.width, raw.height) : (raw.height, raw.width)
    }

    func moveSpot(id: UUID, toDisplayX x: Int, y: Int) {
        guard let raw = rawFrame, let size = displaySize,
              let index = spots.firstIndex(where: { $0.id == id }) else { return }
        let cx = min(max(0, x), size.width - 1)
        let cy = min(max(0, y), size.height - 1)
        let (rx, ry) = rawCoord(displayX: cx, displayY: cy, rawW: raw.width, rawH: raw.height)
        spots[index].rawX = rx
        spots[index].rawY = ry
    }

    /// Moves an area so its display-space rectangle starts at the given
    /// corner. It is held inside the frame rather than clipped, so dragging
    /// against an edge never shrinks it.
    func moveRegion(id: UUID, toDisplayX x0: Int, y0: Int) {
        guard let raw = rawFrame, let size = displaySize,
              let index = regions.firstIndex(where: { $0.id == id }),
              let reading = regionReadings.first(where: { $0.id == id }) else { return }
        let w = Int(reading.rect.width), h = Int(reading.rect.height)
        let nx = min(max(0, x0), size.width - 1 - w)
        let ny = min(max(0, y0), size.height - 1 - h)
        let a = rawCoord(displayX: nx, displayY: ny, rawW: raw.width, rawH: raw.height)
        let b = rawCoord(displayX: nx + w, displayY: ny + h, rawW: raw.width, rawH: raw.height)
        regions[index].rawX0 = a.0; regions[index].rawY0 = a.1
        regions[index].rawX1 = b.0; regions[index].rawY1 = b.1
    }

    func clearSpots() {
        spots.removeAll()
    }

    /// Creates an area from a drag in display coordinates.
    func addRegion(fromDisplayX x0: Int, y0: Int, toDisplayX x1: Int, y1: Int) {
        guard let raw = rawFrame, regions.count < 4 else { return }
        let a = rawCoord(displayX: x0, displayY: y0, rawW: raw.width, rawH: raw.height)
        let b = rawCoord(displayX: x1, displayY: y1, rawW: raw.width, rawH: raw.height)
        let region = MeasureRegion(rawX0: a.0, rawY0: a.1, rawX1: b.0, rawY1: b.1)
        guard region.isUsable else { return }
        regions.append(region)
    }

    func removeRegion(id: UUID) {
        regions.removeAll { $0.id == id }
    }

    func clearRegions() {
        regions.removeAll()
    }

    func renameRegion(id: UUID, to name: String) {
        guard let index = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[index].name = sanitized(name)
    }

    private func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: ";", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    func renameSpot(id: UUID, to name: String) {
        guard let index = spots.firstIndex(where: { $0.id == id }) else { return }
        // Semicolons and newlines would break the CSV layout.
        spots[index].name = sanitized(name)
    }

    func setSpotAlarm(id: UUID, to alarm: AlarmLimits) {
        guard let index = spots.firstIndex(where: { $0.id == id }) else { return }
        spots[index].alarm = alarm
    }

    func setRegionAlarm(id: UUID, to alarm: AlarmLimits) {
        guard let index = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[index].alarm = alarm
    }

    /// Copies the current frame's span into the manual range, as a starting point.
    func adoptCurrentRangeAsManual() {
        guard let frame else { return }
        manualLowC = (frame.minC * 2).rounded(.down) / 2
        manualHighC = (frame.maxC * 2).rounded(.up) / 2
    }

    func removeSpot(id: UUID) {
        spots.removeAll { $0.id == id }
    }

    private var normalizedTurns: Int { ((quarterTurns % 4) + 4) % 4 }

    /// Display sensor coordinates → raw sensor coordinates (inverse of the frame transform).
    private func rawCoord(displayX x: Int, displayY y: Int, rawW w: Int, rawH h: Int) -> (Int, Int) {
        let turns = normalizedTurns
        let nw = turns % 2 == 0 ? w : h
        let mx = mirrored ? nw - 1 - x : x
        switch turns {
        case 1: return (y, h - 1 - mx)
        case 2: return (w - 1 - mx, h - 1 - y)
        case 3: return (w - 1 - y, mx)
        default: return (mx, y)
        }
    }

    /// Raw sensor coordinates → display sensor coordinates.
    private func displayCoord(rawX sx: Int, rawY sy: Int, rawW w: Int, rawH h: Int) -> (Int, Int) {
        let turns = normalizedTurns
        let nw = turns % 2 == 0 ? w : h
        let mx: Int
        let y: Int
        switch turns {
        case 1: y = sx; mx = h - 1 - sy
        case 2: mx = w - 1 - sx; y = h - 1 - sy
        case 3: y = w - 1 - sx; mx = sy
        default: mx = sx; y = sy
        }
        return (mirrored ? nw - 1 - mx : mx, y)
    }

    private func receive(_ rendered: RenderedFrame) {
        fpsFrameCount += 1
        let elapsed = Date().timeIntervalSince(fpsWindowStart)
        if elapsed >= 1.0 {
            fps = Double(fpsFrameCount) / elapsed
            fpsFrameCount = 0
            fpsWindowStart = Date()
        }
        if !frozen {
            rawFrame = rendered.raw
            scaleCurve = rendered.scaleCurve
            let display = rendered.display
            frame = display
            image = rendered.image
            refreshReadings()

            // Trend history and recording both run off the live frame, so a
            // frozen picture does not create a flat line in the data.
            let spotTemps = spotReadings.map(\.tempC)
            let regionTemps = regionReadings.map(\.avgC)
            if history.record(frame: display, spots: spotTemps, regions: regionTemps) {
                refreshTrendLayout()
                publishStatsIfNeeded()
                if let sample = history.samples.last {
                    recorder.append(sample)
                    recordedRows = recorder.rowCount
                    if isRecordingVideo {
                        videoDuration = videoRecorder.duration
                        videoFrameCount = videoRecorder.frameCount
                    }
                    if let started = recorder.startedAt {
                        recordingDuration = Date().timeIntervalSince(started)
                    }
                }
            }
        }
        // Hand everything the capture thread needs for the next frame's
        // overlay over; the compositing itself no longer runs here.
        overlaySnapshot.set(OverlaySnapshot(
            options: overlay,
            paletteID: palette.id,
            spots: spotReadings,
            regions: regionReadings,
            hover: hoverReading,
            trend: trendLayout,
            wantsSyphon: syphonEnabled && syphonPublisher.hasClients,
            wantsMJPEG: obsEnabled && mjpegServer.hasClients,
            wantsStats: statsSyphonEnabled && statsPublisher.hasClients,
            wantsVideo: isRecordingVideo,
            videoOptions: captureWithOverlay ? overlay : .none,
            videoTrend: captureWithOverlay && overlay.trend,
            unit: unit,
            statsOpacity: statsOpacity,
            statsRows: statsRows,
            readoutRows: readoutRows,
            scale: scaleSpan ?? ScaleSpan(lowC: 0, highC: 1, curve: nil),
            timestampFormat: timestampFormat,
            alarmC: hasAlarm ? alarmValue : nil))
    }

    /// Runs on the capture thread: burns in the overlay and feeds the outputs.
    private nonisolated func publishToStreams(_ rendered: RenderedFrame, snapshot: OverlaySnapshot) {
        guard let image = rendered.image else { return }
        if snapshot.needsComposite {
            let composite = OverlayCompositor.composite(frame: rendered.display,
                                                       image: image,
                                                       palette: snapshot.palette,
                                                       options: snapshot.options,
                                                       spots: snapshot.spots,
                                                       regions: snapshot.regions,
                                                       hover: snapshot.hover,
                                                       trend: snapshot.options.trend ? snapshot.trend : nil,
                                                       unit: snapshot.unit,
                                                       span: snapshot.scale,
                                                       timestampFormat: snapshot.timestampFormat,
                                                       readoutRows: snapshot.readoutRows,
                                                       alarmC: snapshot.alarmC)
                ?? image
            if snapshot.wantsSyphon { syphonPublisher.publish(composite) }
            if snapshot.wantsMJPEG { mjpegServer.publish(composite) }
            if snapshot.wantsVideo {
                // Reuse the picture when the options match, otherwise render a
                // second one — the video may deliberately stay clean while the
                // OBS source shows the overlay.
                if snapshot.videoOptions == snapshot.options,
                   snapshot.videoTrend == snapshot.options.trend {
                    videoRecorder.append(composite)
                } else {
                    let forVideo = OverlayCompositor.composite(
                        frame: rendered.display, image: image, palette: snapshot.palette,
                        options: snapshot.videoOptions, spots: snapshot.spots,
                        regions: snapshot.regions, hover: nil,
                        trend: snapshot.videoTrend ? snapshot.trend : nil,
                        unit: snapshot.unit, span: snapshot.scale,
                        timestampFormat: snapshot.timestampFormat,
                        readoutRows: snapshot.readoutRows,
                        alarmC: snapshot.alarmC) ?? image
                    videoRecorder.append(forVideo)
                }
            }
        }
    }

    /// Re-derives the displayed frame from the raw frame after a rotation/mirror change.
    private func retransform() {
        guard let rawFrame else { return }
        let display = rawFrame.transformed(quarterTurns: quarterTurns, mirrored: mirrored)
        frame = display
        image = renderImage(of: display)
        refreshReadings()
    }

    private func rerender() {
        guard let frame else { return }
        image = renderImage(of: frame)
    }

    private func renderImage(of frame: ThermalFrame) -> CGImage? {
        return ThermalRenderer.render(frame: frame, palette: palette,
                                      mode: scaleMode, manualRange: manualRange,
                                      contrast: contrast)
    }

    /// The manual bounds, ordered and never degenerate.
    private var manualRange: ClosedRange<Double> {
        let low = min(manualLowC, manualHighC)
        let high = max(manualLowC, manualHighC)
        return low...max(low + 0.5, high)
    }

    /// What the colour ramp covers for the frame on screen, so the scale bar
    /// can be labelled with the range the picture was actually mapped over.
    var scaleSpan: ScaleSpan? {
        guard let frame else { return nil }
        return ScaleSpan.of(mode: scaleMode, frame: frame, manualRange: manualRange,
                            curve: scaleCurve)
    }

    /// Applies the global emissivity correction to a freshly parsed frame.
    /// At ε = 1 the frame is passed straight through.
    private nonisolated func correctedFrame(_ frame: ThermalFrame, table: EmissivityTable) -> ThermalFrame {
        guard !table.settings.isIdentity else { return frame }
        var temps = frame.tempRaw
        table.apply(to: &temps)
        var minRaw = UInt16.max, maxRaw = UInt16.min, minIdx = 0, maxIdx = 0
        var sum: UInt64 = 0
        for (i, raw) in temps.enumerated() {
            sum += UInt64(raw)
            if raw < minRaw { minRaw = raw; minIdx = i }
            if raw > maxRaw { maxRaw = raw; maxIdx = i }
        }
        return ThermalFrame(width: frame.width, height: frame.height, ir: frame.ir, tempRaw: temps,
                            minC: ThermalFrame.celsius(fromRaw: minRaw),
                            maxC: ThermalFrame.celsius(fromRaw: maxRaw),
                            avgC: ThermalFrame.celsius(fromRaw: UInt16(sum / UInt64(temps.count))),
                            minIndex: minIdx, maxIndex: maxIdx)
    }

    private func corrected(_ frame: ThermalFrame) -> ThermalFrame {
        correctedFrame(frame, table: emissivityTable)
    }

    // MARK: - History & recording

    func clearHistory() {
        history.clear()
        refreshTrendLayout()
    }

    /// Current values for the stats panel, in display order.
    var statsRows: [StatsRenderer.Row] {
        guard let frame else { return [] }
        var rows: [StatsRenderer.Row] = [
            .init(label: String(localized: "Max"), value: frame.maxC, color: .systemRed),
            .init(label: String(localized: "Average"), value: frame.avgC, color: .lightGray),
            .init(label: String(localized: "Min"), value: frame.minC, color: .systemBlue),
        ]
        // No crosshair on the picture means no crosshair reading to report.
        if overlay.crosshair,
           let center = frame.temperatureC(x: frame.width / 2, y: frame.height / 2) {
            rows.append(.init(label: String(localized: "Crosshair"), value: center, color: .white))
        }
        for reading in spotReadings {
            rows.append(.init(label: reading.name.isEmpty
                                  ? String(localized: "Spot \(reading.index)")
                                  : reading.name,
                              value: reading.tempC,
                              color: reading.inAlarm
                                  ? OverlayCompositor.alarmColor
                                  : OverlayCompositor.spotColor(index: reading.index - 1),
                              inAlarm: reading.inAlarm))
        }
        for reading in regionReadings {
            rows.append(.init(label: reading.name.isEmpty
                                  ? String(localized: "Area \(reading.index)")
                                  : reading.name,
                              value: reading.avgC,
                              color: reading.inAlarm
                                  ? OverlayCompositor.alarmColor
                                  : OverlayCompositor.regionColor(index: reading.index - 1),
                              inAlarm: reading.inAlarm))
        }
        return rows
    }

    /// The stats image is rendered on a background queue; at 5 Hz it is not
    /// hot, but it has no business on the main thread either.
    private func publishStatsIfNeeded() {
        guard statsSyphonEnabled, statsPublisher.hasClients else { return }
        // One render at a time; the global queue is concurrent, so without this
        // a slow render would spawn ever more parallel ones.
        guard !statsRenderInFlight.isSet else { return }
        statsRenderInFlight.set(true)
        let layout = trendLayout
        let rows = statsRows
        let opacity = statsOpacity
        let unit = self.unit
        let publisher = statsPublisher
        let flag = statsRenderInFlight
        DispatchQueue.global(qos: .userInitiated).async {
            autoreleasepool {
                if let image = StatsRenderer.render(layout: layout, rows: rows, opacity: opacity, unit: unit) {
                    publisher.publish(image)
                }
            }
            flag.set(false)
        }
    }

    /// Always kept up to date: the separate stats window and Syphon source
    /// show the curve even when it is hidden on the camera image.
    private func refreshTrendLayout() {
        trendLayout = history.layout(window: trendWindow, includeCenter: overlay.crosshair)
    }

    /// Starts or stops recording the picture to an MP4.
    func toggleVideoRecording() {
        if isRecordingVideo {
            isRecordingVideo = false
            videoRecorder.finish { _ in }
            return
        }
        guard let frame, let image else { return }
        _ = frame
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = String(localized: "file.video", defaultValue: "heatpeek") + "-\(Self.fileStamp()).mp4"
        panel.message = String(localized: "Record the picture as a video")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // The video keeps one fixed geometry, matching the composited picture.
        let scale = max(3, Int((1000.0 / Double(max(image.width, image.height))).rounded()))
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        do {
            try videoRecorder.start(url: url, size: size)
            videoDuration = 0
            videoFrameCount = 0
            isRecordingVideo = true
        } catch {
            state = .error(String(localized: "Video recording failed: \(error.localizedDescription)"))
        }
    }

    /// Starts or stops a time-series recording.
    func toggleRecording() {
        if isRecording {
            recorder.stop()
            isRecording = false
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = String(localized: "file.recording", defaultValue: "heatpeek-history") + "-\(Self.fileStamp()).csv"
        panel.message = String(localized: "Record temperature over time")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try recorder.start(url: url, spotNames: spots.map(\.name),
                               regionNames: regions.map(\.name), format: csvFormat, unit: unit)
            recordingFileName = url.lastPathComponent
            recordedRows = 0
            recordingDuration = 0
            isRecording = true
        } catch {
            state = .error(String(localized: "Recording failed: \(error.localizedDescription)"))
        }
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }

    private func formatNumber(_ value: Double) -> String {
        let text = String(format: "%.2f", value)
        return csvFormat == .german ? text.replacingOccurrences(of: ".", with: ",") : text
    }

    // MARK: - Export

    /// Saves the current view as PNG and the temperature matrix as CSV next to it.
    func saveSnapshot() {
        guard let frame, let image else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = String(localized: "file.snapshot", defaultValue: "heatpeek") + "-\(Self.fileStamp()).png"
        panel.message = String(localized: "Save image as PNG and temperature matrix as CSV")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // PNG — plain picture or with the overlay, per the capture setting.
        let composite = OverlayCompositor.composite(frame: frame,
                                                    image: image,
                                                    palette: palette,
                                                    options: captureWithOverlay ? overlay : .none,
                                                    spots: spotReadings,
                                                    regions: regionReadings,
                                                    trend: captureWithOverlay && overlay.trend
                                                        ? trendLayout : nil,
                                                    unit: unit,
                                                    span: scaleSpan ?? ScaleSpan(lowC: frame.minC,
                                                                                 highC: frame.maxC,
                                                                                 curve: nil),
                                                    timestampFormat: timestampFormat,
                                                    readoutRows: readoutRows,
                                                    alarmC: hasAlarm ? alarmValue : nil)
            ?? image
        let rep = NSBitmapImageRep(cgImage: composite)
        rep.size = NSSize(width: composite.width, height: composite.height)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }

        // CSV: a header naming the geometry and unit, then one row per image
        // row. Without it the file is an anonymous block of numbers that
        // nothing — including this app — could read back.
        var csv = "# HeatPeek snapshot \(frame.width)x\(frame.height) \(unit.csvSuffix)\n"
        csv.reserveCapacity(frame.width * frame.height * 7)
        for y in 0..<frame.height {
            var row = [String]()
            row.reserveCapacity(frame.width)
            for x in 0..<frame.width {
                row.append(formatNumber(unit.value(fromCelsius: frame.temperatureC(x: x, y: y) ?? 0)))
            }
            csv += row.joined(separator: ";") + "\n"
        }
        let csvURL = url.deletingPathExtension().appendingPathExtension("csv")
        try? csv.write(to: csvURL, atomically: true, encoding: .utf8)
    }
}
