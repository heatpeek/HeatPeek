import Foundation

/// Corrects apparent temperatures for surface emissivity.
///
/// A surface that radiates less than a black body (ε < 1) reads too cold, and
/// it also reflects its surroundings. The Stefan-Boltzmann relation removes
/// both effects:
///
///     T_object⁴ = (T_apparent⁴ − (1 − ε) · T_reflected⁴) / ε
///
/// Doing that per pixel would mean two `pow` calls on 49 152 pixels every
/// frame, so the mapping is precomputed into a lookup table over the sensor's
/// raw values and applied as a single array read.
struct Emissivity: Equatable {
    /// 0.01 … 1.0, where 1.0 means "no correction".
    var value: Double = 1.0
    /// Temperature of the surroundings being reflected, in °C.
    var reflectedC: Double = 20.0
    /// Lowest temperature the camera can express in its current range.
    /// Corrected values are held here rather than allowed to fall through to
    /// absolute zero where the correction has no solution.
    var floorC: Double = -20.0

    /// Common surfaces, as a starting point. Each name states the surface
    /// condition, because that is what sets the value — a polished and an
    /// oxidised sample of the same metal are an order of magnitude apart.
    static var presets: [(name: String, value: Double)] {
        [
            (String(localized: "Matte paint / plastic"), 0.95),
            (String(localized: "Human skin"), 0.98),
            (String(localized: "PCB, green solder mask"), 0.90),
            (String(localized: "Rusted iron"), 0.92),
            (String(localized: "Anodised aluminium"), 0.77),
            (String(localized: "Oxidised copper"), 0.65),
            (String(localized: "Rough aluminium"), 0.07),
            (String(localized: "Polished copper"), 0.05),
        ]
    }

    var isIdentity: Bool { value >= 0.999 }

    /// How much the correction multiplies an error in the apparent reading.
    /// At the point where object and surroundings are equally warm this is
    /// exactly 1/ε, so ε = 0.05 turns 0.1 K of sensor noise into 2 K.
    var noiseGain: Double { isIdentity ? 1 : 1 / value }

    /// Apparent temperature below which the correction has no solution: the
    /// reflected part alone already accounts for everything the camera sees,
    /// so no object temperature can produce that reading.
    var undefinedBelowC: Double? {
        guard !isIdentity else { return nil }
        let reflectedK = reflectedC + 273.15
        return pow((1 - value) * pow(reflectedK, 4), 0.25) - 273.15
    }

    /// Applies the correction to a single raw sensor value.
    func correct(raw: UInt16) -> UInt16 {
        guard !isIdentity else { return raw }
        let apparentK = Double(raw) / 64.0
        let reflectedK = reflectedC + 273.15
        let inner = (pow(apparentK, 4) - (1 - value) * pow(reflectedK, 4)) / value
        let objectK = inner > 0 ? pow(inner, 0.25) : 0
        // Anything below the camera's own range is reported at that limit.
        // Letting it fall to 0 K would drag the whole scale to absolute zero
        // over a single pixel the correction cannot resolve.
        let clampedK = max(floorC + 273.15, objectK)
        return UInt16(max(0, min(65535, (clampedK * 64.0).rounded())))
    }
}

/// Precomputed raw→raw mapping for one emissivity setting.
final class EmissivityTable {
    /// Raw values above this are far beyond the sensor's range; mapping the
    /// full 16-bit space would waste 128 KB and time on values never seen.
    private static let limit = 40000

    private(set) var settings = Emissivity()
    private var table: [UInt16] = []

    /// Rebuilds the table when the settings changed. Returns true if it did.
    @discardableResult
    func update(_ newSettings: Emissivity) -> Bool {
        guard newSettings != settings || (table.isEmpty && !newSettings.isIdentity) else { return false }
        settings = newSettings
        if newSettings.isIdentity {
            table = []
            return true
        }
        table = (0..<Self.limit).map { newSettings.correct(raw: UInt16($0)) }
        return true
    }

    /// Corrects a whole frame in place. Does nothing at ε = 1.
    func apply(to values: inout [UInt16]) {
        guard !table.isEmpty else { return }
        table.withUnsafeBufferPointer { lut in
            values.withUnsafeMutableBufferPointer { dst in
                var i = 0
                let count = dst.count
                while i < count {
                    let raw = Int(dst[i])
                    if raw < Self.limit { dst[i] = lut[raw] }
                    i += 1
                }
            }
        }
    }

    /// Corrects a single value, for per-spot overrides.
    func corrected(_ raw: UInt16) -> UInt16 {
        guard !table.isEmpty else { return raw }
        return Int(raw) < Self.limit ? table[Int(raw)] : raw
    }
}
