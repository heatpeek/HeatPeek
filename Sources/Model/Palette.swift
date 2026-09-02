import Foundation
import CoreGraphics

/// A 256-entry RGB lookup table mapping 8-bit IR brightness to color.
struct Palette: Identifiable, Hashable {
    let id: String
    let name: String
    let lut: [UInt8] // 256 * 3 (RGB)

    static func == (lhs: Palette, rhs: Palette) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    private init(id: String, name: String, map: (Double) -> (Double, Double, Double)) {
        var lut = [UInt8](repeating: 0, count: 256 * 3)
        for i in 0..<256 {
            let t = Double(i) / 255.0
            let (r, g, b) = map(t)
            lut[i * 3 + 0] = UInt8((r.clamped01) * 255.0)
            lut[i * 3 + 1] = UInt8((g.clamped01) * 255.0)
            lut[i * 3 + 2] = UInt8((b.clamped01) * 255.0)
        }
        self.id = id
        self.name = name
        self.lut = lut
    }

    /// Evaluates a degree-6 polynomial colormap fit (Matt Zucker's approximations
    /// of the matplotlib colormaps).
    private static func poly(_ t: Double, _ c: [(Double, Double, Double)]) -> (Double, Double, Double) {
        var r = 0.0, g = 0.0, b = 0.0
        for coeff in c.reversed() {
            r = r * t + coeff.0
            g = g * t + coeff.1
            b = b * t + coeff.2
        }
        return (r, g, b)
    }

    /// Matplotlib "plasma" – very close to the vendor app's default look
    /// (violet → magenta → orange → yellow-white).
    static let plasma = Palette(id: "plasma", name: "Plasma") { t in
        poly(t, [
            (0.05873234392399702, 0.02333670892565664, 0.5433401826748754),
            (2.176514634195958, 0.2383834171260182, 0.7539604599784036),
            (-2.689460476458034, -7.455851135738909, 3.110799939717086),
            (6.130348345893603, 42.3461881477227, -28.51885465332158),
            (-11.10743619062271, -82.66631109428045, 60.13984767418263),
            (10.02306557647065, 71.41361770095349, -54.07218655560067),
            (-3.658713842777788, -22.93153465461149, 18.19190778539828),
        ])
    }

    /// Matplotlib "inferno" – black → purple → red-orange → yellow.
    static let inferno = Palette(id: "inferno", name: "Inferno") { t in
        poly(t, [
            (0.0002189403691192265, 0.001651004631001012, -0.01948089843709184),
            (0.1065134194856116, 0.5639564367884091, 3.932712388889277),
            (11.60249308247187, -3.972853965665698, -15.9423941062914),
            (-41.70399613139459, 17.43639888205313, 44.35414519872813),
            (77.162935699427, -33.40235894210092, -81.80730925738993),
            (-71.31942824499214, 32.62606426397723, 73.20951985803202),
            (25.13112622477341, -12.24266895238567, -23.07032500287172),
        ])
    }

    static let whiteHot = Palette(id: "whitehot", name: "White Hot") { t in (t, t, t) }

    static let blackHot = Palette(id: "blackhot", name: "Black Hot") { t in (1 - t, 1 - t, 1 - t) }

    /// Blue → cyan → green → yellow → red rainbow.
    static let rainbow = Palette(id: "rainbow", name: "Rainbow") { t in
        let r = max(0.0, min(1.0, 2.0 * t - 0.5) * 2.0).clamped01
        let g = (t < 0.5 ? 2.0 * t : 2.0 - 2.0 * t) * 1.6
        let b = max(0.0, 1.0 - 2.2 * t)
        return (r, g, b)
    }

    /// Cold blue tint for dark areas, warm white for hot.
    static let arctic = Palette(id: "arctic", name: "Arctic") { t in
        (t * t, 0.3 * t + 0.7 * t * t, 0.55 + 0.45 * t)
    }

    static let all: [Palette] = [.plasma, .inferno, .whiteHot, .blackHot, .rainbow, .arctic]
}

private extension Double {
    var clamped01: Double { Swift.min(1.0, Swift.max(0.0, self)) }
}

/// How brightness is mapped to colour.
enum ScaleMode: String, CaseIterable, Identifiable {
    /// The camera's own auto-gain image: best local contrast, but the same
    /// colour means different temperatures from one moment to the next.
    case camera
    /// Linear over this frame's own min…max — colours then match the scale bar
    /// exactly, but still drift as the scene changes.
    case frame
    /// Linear over a fixed range, so recordings stay comparable over time.
    case manual

    var id: String { rawValue }
    var label: String {
        switch self {
        case .camera: return String(localized: "Camera automatic")
        case .frame: return String(localized: "Auto per frame")
        case .manual: return String(localized: "Fixed range")
        }
    }

    /// Compact form for segmented controls.
    var shortTitle: String {
        switch self {
        case .camera: return String(localized: "Auto cam")
        case .frame: return String(localized: "Per frame")
        case .manual: return String(localized: "Fixed")
        }
    }
}

/// The temperature span the colour ramp currently covers, and whether the
/// steps between its ends are evenly spaced.
struct ScaleSpan: Equatable {
    let lowC: Double
    let highC: Double
    /// Temperature per brightness level, for a ramp that is not a straight
    /// line between its ends. The camera's own gain needs it, and it is read
    /// back from the frame rather than assumed — see
    /// `ThermalFrame.brightnessCurve()`.
    let curve: [Double]?

    var isLinear: Bool { curve == nil }

    static func of(mode: ScaleMode, frame: ThermalFrame,
                   manualRange: ClosedRange<Double>,
                   curve: [Double]? = nil) -> ScaleSpan {
        switch mode {
        case .camera:
            return ScaleSpan(lowC: frame.minC, highC: frame.maxC,
                             curve: curve ?? frame.brightnessCurve())
        case .frame:
            return ScaleSpan(lowC: frame.minC, highC: frame.maxC, curve: nil)
        case .manual:
            return ScaleSpan(lowC: manualRange.lowerBound,
                             highC: manualRange.upperBound, curve: nil)
        }
    }

    /// Where a temperature sits on the bar: 0 at the hot end, 1 at the cold
    /// end. The recovered curve rises with brightness, so a scan finds the
    /// level the value belongs to.
    func fraction(of celsius: Double) -> Double? {
        guard let curve else {
            let span = max(0.01, highC - lowC)
            return min(max(0, (highC - celsius) / span), 1)
        }
        guard celsius >= curve[0] else { return 1 }
        guard celsius <= curve[255] else { return 0 }
        var level = 0
        while level < 255, curve[level + 1] < celsius { level += 1 }
        return 1 - Double(level) / 255
    }

    /// The value at a position on the bar, top to bottom.
    func value(at fraction: Double) -> Double {
        guard let curve else { return highC - fraction * (highC - lowC) }
        // The ends are known exactly; the curve's outermost levels average a
        // range of temperatures together and would read a little short.
        if fraction <= 0 { return highC }
        if fraction >= 1 { return lowC }
        let level = Int(((1 - fraction) * 255).rounded())
        return curve[min(255, max(0, level))]
    }

    /// Where one pixel of the frame sits on the bar. Under the camera's own
    /// gain the bar is the palette laid over brightness, so the pixel's own
    /// brightness is its exact position and the unknown curve never enters.
    func fraction(ofPixelAt x: Int, y: Int, in frame: ThermalFrame) -> Double? {
        guard x >= 0, x < frame.width, y >= 0, y < frame.height else { return nil }
        guard isLinear else {
            return 1 - Double(frame.ir[y * frame.width + x]) / 255
        }
        return frame.temperatureC(x: x, y: y).flatMap(fraction(of:))
    }
}

/// Renders a ThermalFrame to a CGImage using a palette LUT.
enum ThermalRenderer {
    /// Renders using the camera's AGC image.
    static func render(frame: ThermalFrame, palette: Palette) -> CGImage? {
        render(frame: frame, palette: palette, mode: .camera, manualRange: 0...1)
    }

    /// - Parameters:
    ///   - manualRange: lower and upper bound in °C, used by `.manual`.
    ///   - contrast: CLAHE strength; 0 disables it.
    static func render(frame: ThermalFrame,
                       palette: Palette,
                       mode: ScaleMode,
                       manualRange: ClosedRange<Double>,
                       contrast: Double = 0) -> CGImage? {
        let w = frame.width
        let h = frame.height
        var rgba = [UInt8](repeating: 255, count: w * h * 4)

        // Precompute the temperature→index mapping for the linear modes.
        let lowC: Double
        let highC: Double
        switch mode {
        case .camera:
            lowC = 0; highC = 1 // unused
        case .frame:
            lowC = frame.minC; highC = frame.maxC
        case .manual:
            lowC = manualRange.lowerBound; highC = manualRange.upperBound
        }
        let span = max(0.01, highC - lowC)

        palette.lut.withUnsafeBufferPointer { lut in
            let count = w * h

            // Build the 8-bit brightness plane first. Going through one common
            // plane lets the contrast step work in every scale mode.
            var plane: [UInt8]
            if mode == .camera {
                plane = frame.ir
            } else {
                // Map temperature to an index with integer maths on the raw
                // 1/64 K values, avoiding a division per pixel.
                plane = [UInt8](repeating: 0, count: count)
                let lowRaw = (lowC + 273.15) * 64.0
                let scale = 255.0 / (span * 64.0)
                frame.tempRaw.withUnsafeBufferPointer { temps in
                    plane.withUnsafeMutableBufferPointer { dst in
                        var i = 0
                        while i < count {
                            let t = (Double(temps[i]) - lowRaw) * scale
                            dst[i] = UInt8(t < 0 ? 0 : (t > 255 ? 255 : t))
                            i += 1
                        }
                    }
                }
            }

            if contrast > 0.01 {
                CLAHE.apply(to: &plane, width: w, height: h, clipLimit: 1.0 + contrast * 3.0)
            }

            rgba.withUnsafeMutableBufferPointer { dst in
                plane.withUnsafeBufferPointer { src in
                    var i = 0
                    while i < count {
                        let v = Int(src[i]) * 3
                        dst[i * 4 + 0] = lut[v + 0]
                        dst[i * 4 + 1] = lut[v + 1]
                        dst[i * 4 + 2] = lut[v + 2]
                        i += 1
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
