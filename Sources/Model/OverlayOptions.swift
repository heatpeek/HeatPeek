import Foundation

/// Which pieces of information are drawn into the picture. One set governs
/// the window and the streamed sources alike, so what is on screen is what
/// leaves the app; captures may deliberately differ, see `captureWithOverlay`.
struct OverlayOptions: Equatable {
    var timestamp = true
    var scaleBar = true
    var crosshair = true
    var markers = true
    var spots = true
    var trend = true
    /// The block of readings: scene extremes and the measurement list.
    var readout = true
    /// The temperature under the mouse pointer.
    var cursor = true

    /// Everything on.
    static let all = OverlayOptions()

    /// Nothing drawn — the plain picture, used for clean captures.
    static var none: OverlayOptions {
        OverlayOptions(timestamp: false, scaleBar: false, crosshair: false,
                       markers: false, spots: false, trend: false,
                       readout: false, cursor: false)
    }

    // MARK: - Persistence

    private static let keys = ["timestamp", "scaleBar", "crosshair", "markers",
                               "spots", "trend", "readout", "cursor"]

    init() {}

    init(timestamp: Bool, scaleBar: Bool, crosshair: Bool,
         markers: Bool, spots: Bool, trend: Bool, readout: Bool, cursor: Bool) {
        self.timestamp = timestamp
        self.scaleBar = scaleBar
        self.crosshair = crosshair
        self.markers = markers
        self.spots = spots
        self.trend = trend
        self.readout = readout
        self.cursor = cursor
    }

    init(loadingWithPrefix prefix: String) {
        let defaults = UserDefaults.standard
        func flag(_ key: String) -> Bool {
            defaults.object(forKey: prefix + "." + key) as? Bool ?? true
        }
        readout = flag("readout")
        cursor = flag("cursor")
        timestamp = flag("timestamp")
        scaleBar = flag("scaleBar")
        crosshair = flag("crosshair")
        markers = flag("markers")
        spots = flag("spots")
        trend = flag("trend")
    }

    func save(withPrefix prefix: String) {
        let defaults = UserDefaults.standard
        let values = [timestamp, scaleBar, crosshair, markers, spots, trend, readout, cursor]
        for (key, value) in zip(Self.keys, values) {
            defaults.set(value, forKey: prefix + "." + key)
        }
    }
}

/// How the burned-in timestamp is written.
enum TimestampFormat: String, CaseIterable, Identifiable {
    case european
    case american

    var id: String { rawValue }

    var pattern: String {
        switch self {
        case .european: return "dd.MM.yyyy  HH:mm:ss"
        case .american: return "MM/dd/yyyy  h:mm:ss a"
        }
    }

    /// The AM/PM suffix has to read in English whatever the app language is,
    /// so the American pattern is formatted against a fixed locale.
    var locale: Locale {
        self == .american ? Locale(identifier: "en_US_POSIX") : Locale(identifier: "de_DE")
    }

    /// One formatter per format, built once and never modified afterwards.
    /// The window and the capture thread both ask for a stamp, and reusing a
    /// single formatter by rewriting its pattern would race between them.
    private static let formatters: [TimestampFormat: DateFormatter] = {
        var map: [TimestampFormat: DateFormatter] = [:]
        for format in TimestampFormat.allCases {
            let f = DateFormatter()
            f.locale = format.locale
            f.dateFormat = format.pattern
            map[format] = f
        }
        return map
    }()

    func string(from date: Date) -> String {
        Self.formatters[self]?.string(from: date) ?? ""
    }
}
