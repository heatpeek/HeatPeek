import Foundation

/// Display unit for every temperature the app shows or writes out. Values are
/// stored in °C throughout; conversion happens only at the edges.
enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case celsius
    case fahrenheit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .celsius: return String(localized: "Celsius (°C)")
        case .fahrenheit: return String(localized: "Fahrenheit (°F)")
        }
    }

    var suffix: String { self == .celsius ? "°C" : "°F" }
    /// Suffix used in CSV column names, e.g. `Max_C` / `Max_F`.
    var csvSuffix: String { self == .celsius ? "C" : "F" }

    func value(fromCelsius celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9.0 / 5.0 + 32.0
    }

    func celsius(fromValue value: Double) -> Double {
        self == .celsius ? value : (value - 32.0) * 5.0 / 9.0
    }

    /// "23.4 °C" style, with the unit.
    func format(_ celsius: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f\(suffix)", value(fromCelsius: celsius))
    }

    /// Number only, for places that print the unit separately.
    func number(_ celsius: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", value(fromCelsius: celsius))
    }

    /// Degree sign without the scale letter, for tight axis labels.
    func degrees(_ celsius: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f°", value(fromCelsius: celsius))
    }
}
