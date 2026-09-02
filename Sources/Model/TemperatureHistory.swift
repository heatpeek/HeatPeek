import Foundation
import CoreGraphics

/// One sampled moment of the scene's temperature statistics.
struct HistorySample {
    let time: Date
    let minC: Double
    let maxC: Double
    let avgC: Double
    let centerC: Double
    /// Temperatures of the user-placed measurement spots, in spot order.
    let spots: [Double]
    /// Mean temperature of each area measurement, in region order.
    let regions: [Double]
}

/// Rolling buffer of temperature statistics over the recent past, used for the
/// trend overlay and as the source for recordings.
final class TemperatureHistory {
    /// How far back the trend overlay looks.
    enum Window: String, CaseIterable, Identifiable {
        case s30, m2, m10
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .s30: return 30
            case .m2: return 120
            case .m10: return 600
            }
        }
        var label: String {
            switch self {
            case .s30: return "30 s"
            case .m2: return "2 min"
            case .m10: return "10 min"
            }
        }
    }

    /// Samples are taken at this rate, independently of the frame rate — plenty
    /// for a trend line and keeps the buffer small.
    static let sampleRate: TimeInterval = 1.0 / 5.0

    private(set) var samples: [HistorySample] = []
    private var lastSampleTime: Date?

    var isEmpty: Bool { samples.isEmpty }

    /// Adds a sample if enough time has passed; drops anything older than the
    /// longest supported window. Returns true when a sample was actually taken.
    @discardableResult
    func record(frame: ThermalFrame, spots: [Double], regions: [Double] = [],
                now: Date = Date()) -> Bool {
        if let last = lastSampleTime, now.timeIntervalSince(last) < Self.sampleRate {
            return false
        }
        lastSampleTime = now

        let center = frame.temperatureC(x: frame.width / 2, y: frame.height / 2) ?? 0
        samples.append(HistorySample(time: now,
                                     minC: frame.minC,
                                     maxC: frame.maxC,
                                     avgC: frame.avgC,
                                     centerC: center,
                                     spots: spots,
                                     regions: regions))

        let cutoff = now.addingTimeInterval(-(Window.allCases.map(\.seconds).max() ?? 600))
        if let firstKept = samples.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
        return true
    }

    func clear() {
        samples.removeAll()
        lastSampleTime = nil
    }

    // MARK: - Layout for drawing

    /// What a curve represents; drives its colour in both renderers.
    enum SeriesKind: Hashable {
        case max
        case min
        /// Mean over the frame. Only recordings carry it; the live trend
        /// leaves it out to keep the curves apart.
        case average
        case center
        /// A user-placed measurement spot, 0-based.
        case spot(Int)
        /// Mean of an area measurement, 0-based.
        case region(Int)
    }

    /// A named polyline in normalised coordinates (0…1, y already flipped so
    /// 0 is the top), ready for either SwiftUI or CoreGraphics to stroke.
    struct Series {
        let name: String
        let kind: SeriesKind
        let points: [CGPoint]
    }

    /// Everything the trend overlay needs for one window.
    struct Layout {
        let series: [Series]
        let minC: Double
        let maxC: Double
        let spanSeconds: TimeInterval
        let sampleCount: Int
    }

    /// Builds normalised polylines for the given window. Returns nil when there
    /// is not enough data to draw a line yet.
    /// - Parameter includeCenter: the crosshair curve is left out when the
    ///   crosshair itself is switched off — there is no such measurement then.
    func layout(window: Window, now: Date = Date(), includeCenter: Bool = true) -> Layout? {
        let cutoff = now.addingTimeInterval(-window.seconds)
        let visible = samples.filter { $0.time >= cutoff }
        guard visible.count >= 2 else { return nil }

        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for s in visible {
            lo = Swift.min(lo, s.minC)
            hi = Swift.max(hi, s.maxC)
        }
        // Keep a minimum span so a flat scene does not turn into noise.
        if hi - lo < 1.0 {
            let mid = (hi + lo) / 2
            lo = mid - 0.5
            hi = mid + 0.5
        }
        let pad = (hi - lo) * 0.08
        lo -= pad
        hi += pad

        func normalise(_ value: Double, _ time: Date) -> CGPoint {
            let x = 1.0 - (now.timeIntervalSince(time) / window.seconds)
            let y = 1.0 - ((value - lo) / (hi - lo))
            return CGPoint(x: Swift.max(0, Swift.min(1, x)), y: Swift.max(0, Swift.min(1, y)))
        }

        var series = [
            Series(name: "Max", kind: .max, points: visible.map { normalise($0.maxC, $0.time) }),
        ]
        if includeCenter {
            series.append(Series(name: "Crosshair", kind: .center,
                                 points: visible.map { normalise($0.centerC, $0.time) }))
        }
        series.append(Series(name: "Min", kind: .min, points: visible.map { normalise($0.minC, $0.time) }))

        // One curve per measurement spot. A spot only has samples from the
        // moment it was placed, so its line simply starts there.
        let spotCount = visible.last?.spots.count ?? 0
        for index in 0..<spotCount {
            let points = visible
                .filter { $0.spots.count > index }
                .map { normalise($0.spots[index], $0.time) }
            guard points.count >= 2 else { continue }
            series.append(Series(name: "\(index + 1)", kind: .spot(index), points: points))
        }

        // One curve per area measurement, following its mean temperature.
        let regionCount = visible.last?.regions.count ?? 0
        for index in 0..<regionCount {
            let points = visible
                .filter { $0.regions.count > index }
                .map { normalise($0.regions[index], $0.time) }
            guard points.count >= 2 else { continue }
            series.append(Series(name: "\(index + 1)", kind: .region(index), points: points))
        }
        return Layout(series: series, minC: lo, maxC: hi,
                      spanSeconds: window.seconds, sampleCount: visible.count)
    }
}
