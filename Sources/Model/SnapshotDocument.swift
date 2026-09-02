import Foundation
import CoreGraphics

/// A saved snapshot read back from its CSV: the full temperature matrix of one
/// frame. The file names its geometry and unit in a leading comment, so it can
/// be recognised and read without guessing.
struct SnapshotDocument {
    let name: String
    /// The unit the file was written in. Values below are in °C.
    let sourceUnit: TemperatureUnit
    let width: Int
    let height: Int
    /// Temperatures in °C, row-major.
    let values: [Double]

    let minC: Double
    let maxC: Double
    let meanC: Double

    func temperature(x: Int, y: Int) -> Double? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return values[y * width + x]
    }

    /// Counts per bucket across the min…max span, for the distribution plot.
    func histogram(bins: Int) -> [Int] {
        var counts = [Int](repeating: 0, count: bins)
        let span = max(0.0001, maxC - minC)
        for value in values {
            let index = Int((value - minC) / span * Double(bins - 1))
            counts[min(bins - 1, max(0, index))] += 1
        }
        return counts
    }

    /// Renders the matrix with a palette, scaled linearly over its own range.
    func image(palette: Palette) -> CGImage? {
        let span = max(0.0001, maxC - minC)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<values.count {
            let t = (values[i] - minC) / span
            let index = min(255, max(0, Int(t * 255))) * 3
            pixels[i * 4 + 0] = palette.lut[index]
            pixels[i * 4 + 1] = palette.lut[index + 1]
            pixels[i * 4 + 2] = palette.lut[index + 2]
        }
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            return context.makeImage()
        }
    }

    // MARK: - Reading

    /// Header written by the snapshot export, e.g.
    /// `# HeatPeek snapshot 256x192 C`.
    private static let headerPrefix = "# HeatPeek snapshot "

    static func read(contentsOf url: URL) throws -> SnapshotDocument? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.first, header.hasPrefix(headerPrefix) else { return nil }
        lines.removeFirst()

        let fields = header.dropFirst(headerPrefix.count).split(separator: " ")
        let geometry = fields.first?.split(separator: "x") ?? []
        guard geometry.count == 2,
              let width = Int(geometry[0]), let height = Int(geometry[1]),
              width > 0, height > 0
        else { throw RecordingDocument.ReadError.notARecording }

        let unit: TemperatureUnit = fields.count > 1 && fields[1] == "F" ? .fahrenheit : .celsius

        var values = [Double]()
        values.reserveCapacity(width * height)
        for line in lines {
            for field in line.split(separator: ";", omittingEmptySubsequences: false) {
                guard let value = Double(field.replacingOccurrences(of: ",", with: ".")) else { continue }
                values.append(unit.celsius(fromValue: value))
            }
        }
        guard values.count == width * height else { throw RecordingDocument.ReadError.notARecording }

        let total = values.reduce(0, +)
        return SnapshotDocument(name: url.deletingPathExtension().lastPathComponent,
                                sourceUnit: unit,
                                width: width, height: height,
                                values: values,
                                minC: values.min() ?? 0,
                                maxC: values.max() ?? 0,
                                meanC: total / Double(values.count))
    }
}
