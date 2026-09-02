import Foundation
import CoreGraphics

/// A recording read back from one of the CSV files the app writes.
///
/// The column layout is fixed by `SessionRecorder`: timestamp, elapsed
/// seconds, then minimum, maximum, average and crosshair, followed by one
/// column per measurement spot and one per area. Column *names* are written in
/// the app language, so the fixed series are recognised by position rather
/// than by their heading; areas are told apart from spots by their `_Avg_`
/// infix, which only they carry.
struct RecordingDocument {
    struct Series: Identifiable {
        let id: Int
        let name: String
        let kind: TemperatureHistory.SeriesKind
        /// One value per row; nil where the file had no reading.
        let values: [Double?]

        var minValue: Double? { values.compactMap { $0 }.min() }
        var maxValue: Double? { values.compactMap { $0 }.max() }
        var meanValue: Double? {
            let present = values.compactMap { $0 }
            guard !present.isEmpty else { return nil }
            return present.reduce(0, +) / Double(present.count)
        }
    }

    enum ReadError: LocalizedError {
        case unreadable
        case notARecording

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return String(localized: "The file could not be read.")
            case .notARecording:
                return String(localized: "This is not a HeatPeek recording. Snapshot CSVs hold a single frame and have no time axis.")
            }
        }
    }

    let name: String
    /// The unit the file was written in. Values below are converted to °C on
    /// read, so the viewer can show them in whatever unit the app is set to.
    let sourceUnit: TemperatureUnit
    /// Elapsed seconds per row, starting at zero.
    let seconds: [Double]
    let timestamps: [String]
    let series: [Series]

    var rowCount: Int { seconds.count }
    var duration: TimeInterval { seconds.last ?? 0 }

    /// Lowest and highest value across every series, the range the plot spans.
    var valueRange: (low: Double, high: Double) {
        let lows = series.compactMap { $0.minValue }
        let highs = series.compactMap { $0.maxValue }
        guard let low = lows.min(), let high = highs.max(), high > low else {
            return (lows.min() ?? 0, (highs.max() ?? 0) + 1)
        }
        return (low, high)
    }

    // MARK: - Reading

    static func read(contentsOf url: URL) throws -> RecordingDocument {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ReadError.unreadable
        }
        var lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.first else { throw ReadError.notARecording }
        lines.removeFirst()

        let columns = header.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        // A recording opens with a header: two axis columns and at least the
        // four fixed series, every one of them carrying a unit suffix. A
        // snapshot CSV starts straight into pixel values and fails all three.
        guard columns.count >= 6,
              number(columns[0]) == nil,
              columns.dropFirst(2).allSatisfy({ $0.hasSuffix("_C") || $0.hasSuffix("_F") })
        else { throw ReadError.notARecording }

        let unit: TemperatureUnit = columns[2].hasSuffix("_F") ? .fahrenheit : .celsius
        let suffix = "_" + unit.csvSuffix

        var seconds: [Double] = []
        var timestamps: [String] = []
        var raw: [[Double?]] = Array(repeating: [], count: columns.count - 2)

        for line in lines {
            let fields = line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == columns.count, let elapsed = number(fields[1]) else { continue }
            timestamps.append(fields[0])
            seconds.append(elapsed)
            for index in 2..<columns.count {
                // Stored in °C like every other temperature in the app.
                raw[index - 2].append(number(fields[index]).map(unit.celsius(fromValue:)))
            }
        }
        guard seconds.count >= 2 else { throw ReadError.notARecording }

        var series: [Series] = []
        var spotIndex = 0
        var regionIndex = 0

        for (offset, column) in columns.dropFirst(2).enumerated() {
            let kind: TemperatureHistory.SeriesKind
            switch offset {
            case 0: kind = .min
            case 1: kind = .max
            case 2: kind = .average
            case 3: kind = .center
            default:
                if column.hasSuffix("_Avg" + suffix) {
                    kind = .region(regionIndex)
                    regionIndex += 1
                } else {
                    kind = .spot(spotIndex)
                    spotIndex += 1
                }
            }
            series.append(Series(id: offset,
                                 name: displayName(of: column, unit: suffix),
                                 kind: kind,
                                 values: raw[offset]))
        }

        return RecordingDocument(name: url.deletingPathExtension().lastPathComponent,
                                 sourceUnit: unit,
                                 seconds: seconds,
                                 timestamps: timestamps,
                                 series: series)
    }

    /// Strips the unit suffix a column heading carries, so "Spot1_C" reads as
    /// "Spot1" and "Board_Avg_C" as "Board".
    private static func displayName(of column: String, unit suffix: String) -> String {
        var name = column
        if name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        if name.hasSuffix("_Avg") { name.removeLast(4) }
        return name.isEmpty ? column : name
    }

    /// Accepts both decimal separators, because the writer offers both.
    private static func number(_ field: String) -> Double? {
        Double(field.replacingOccurrences(of: ",", with: "."))
    }
}
