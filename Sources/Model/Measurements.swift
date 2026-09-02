import Foundation
import CoreGraphics

/// Optional warning limits for a measurement.
struct AlarmLimits: Equatable {
    var low: Double?
    var high: Double?

    var isActive: Bool { low != nil || high != nil }

    /// True when the value is outside the configured limits.
    func triggered(by value: Double) -> Bool {
        if let low, value < low { return true }
        if let high, value > high { return true }
        return false
    }
}

/// A user-placed measurement spot, stored in raw sensor coordinates so it
/// survives rotation/mirror changes.
struct MeasureSpot: Identifiable, Equatable {
    let id = UUID()
    var rawX: Int
    var rawY: Int
    /// Optional user-given name; falls back to the running number.
    var name: String = ""
    /// Overrides the global emissivity for this spot only, e.g. a bare metal
    /// heatsink in an otherwise matte scene.
    var emissivity: Double?
    var alarm = AlarmLimits()
}

/// A rectangular area measurement, in raw sensor coordinates.
struct MeasureRegion: Identifiable, Equatable {
    let id = UUID()
    /// Inclusive raw-coordinate bounds.
    var rawX0: Int
    var rawY0: Int
    var rawX1: Int
    var rawY1: Int
    var name: String = ""
    var alarm = AlarmLimits()

    var rawMinX: Int { min(rawX0, rawX1) }
    var rawMaxX: Int { max(rawX0, rawX1) }
    var rawMinY: Int { min(rawY0, rawY1) }
    var rawMaxY: Int { max(rawY0, rawY1) }

    /// Regions smaller than this are treated as an accidental drag.
    static let minimumSize = 4
    var isUsable: Bool {
        rawMaxX - rawMinX >= Self.minimumSize && rawMaxY - rawMinY >= Self.minimumSize
    }
}

/// A spot resolved against the current frame for display.
struct SpotReading: Identifiable {
    let id: UUID
    let index: Int
    let name: String
    let x: Int // display sensor coordinates
    let y: Int
    let tempC: Double
    var inAlarm = false

    /// What overlays and lists show: the custom name, or the number.
    var label: String { name.isEmpty ? "\(index)" : name }
}

/// A region resolved against the current frame for display.
struct RegionReading: Identifiable {
    let id: UUID
    let index: Int
    let name: String
    /// Display-space sensor rect (x0,y0)–(x1,y1), already rotated/mirrored.
    let rect: CGRect
    let minC: Double
    let maxC: Double
    let avgC: Double
    var inAlarm = false

    /// Areas fall back to their full name, because a bare number would read as
    /// a spot of the same index.
    var label: String { name.isEmpty ? String(localized: "Area \(index)") : name }
}
