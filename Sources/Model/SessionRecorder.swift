import Foundation

/// Records a temperature time series to CSV while the user holds a recording.
/// Unlike the single-frame snapshot export, every row here is one moment in
/// time, so the file has a real time axis.
final class SessionRecorder {
    /// Decimal separator for the written numbers.
    enum NumberFormat: String, CaseIterable, Identifiable {
        case german, english
        var id: String { rawValue }
        var label: String {
            switch self {
            case .german: return String(localized: "German (12,34)")
            case .english: return String(localized: "English (12.34)")
            }
        }

        /// The separator as it actually appears in a file.
        var sample: String { self == .german ? "24,31" : "24.31" }
    }

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var rowCount = 0
    private(set) var url: URL?

    private var handle: FileHandle?
    private var format: NumberFormat = .german
    private var unit: TemperatureUnit = .celsius
    private var spotColumnCount = 0
    private var regionColumnCount = 0

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Opens the file and writes the header. `spotNames` fixes the column
    /// layout for the whole recording, so spots added later do not shift
    /// existing columns; empty entries fall back to the running number.
    func start(url: URL, spotNames: [String], regionNames: [String],
               format: NumberFormat, unit: TemperatureUnit) throws {
        stop()
        self.format = format
        self.unit = unit
        self.spotColumnCount = spotNames.count
        self.regionColumnCount = regionNames.count

        // Column titles follow the app language so the file opens readably in
        // the user's spreadsheet.
        var header = [
            String(localized: "csv.time", defaultValue: "Time"),
            String(localized: "csv.seconds", defaultValue: "Seconds"),
            String(localized: "csv.min", defaultValue: "Min") + "_" + unit.csvSuffix,
            String(localized: "csv.max", defaultValue: "Max") + "_" + unit.csvSuffix,
            String(localized: "csv.avg", defaultValue: "Average") + "_" + unit.csvSuffix,
            String(localized: "csv.center", defaultValue: "Crosshair") + "_" + unit.csvSuffix,
        ]
        let spotPrefix = String(localized: "csv.spot", defaultValue: "Spot")
        for (i, name) in spotNames.enumerated() {
            header.append((name.isEmpty ? "\(spotPrefix)\(i + 1)" : name) + "_" + unit.csvSuffix)
        }
        let regionPrefix = String(localized: "csv.region", defaultValue: "Area")
        for (i, name) in regionNames.enumerated() {
            let base = name.isEmpty ? "\(regionPrefix)\(i + 1)" : name
            header.append(base + "_Avg_" + unit.csvSuffix)
        }
        let line = header.joined(separator: ";") + "\n"

        FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8))
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()

        self.url = url
        startedAt = Date()
        rowCount = 0
        isRecording = true
    }

    func stop() {
        try? handle?.close()
        handle = nil
        isRecording = false
    }

    /// Values arrive in °C and are converted here, so the file matches the
    /// unit shown in the app.
    private func number(_ value: Double) -> String {
        let text = String(format: "%.2f", unit.value(fromCelsius: value))
        return format == .german ? text.replacingOccurrences(of: ".", with: ",") : text
    }

    /// Appends one sample. Extra spots beyond the recording's column count are
    /// dropped, missing ones are left empty.
    func append(_ sample: HistorySample) {
        guard isRecording, let handle, let startedAt else { return }
        var fields = [
            Self.timestampFormatter.string(from: sample.time),
            number(sample.time.timeIntervalSince(startedAt)),
            number(sample.minC),
            number(sample.maxC),
            number(sample.avgC),
            number(sample.centerC),
        ]
        for i in 0..<spotColumnCount {
            fields.append(i < sample.spots.count ? number(sample.spots[i]) : "")
        }
        for i in 0..<regionColumnCount {
            fields.append(i < sample.regions.count ? number(sample.regions[i]) : "")
        }
        if let data = (fields.joined(separator: ";") + "\n").data(using: .utf8) {
            try? handle.write(contentsOf: data)
            rowCount += 1
        }
    }
}
