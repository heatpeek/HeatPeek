import Foundation

/// One decoded thermal frame: an 8-bit AGC brightness image plus
/// per-pixel radiometric temperature data.
struct ThermalFrame {
    let width: Int
    let height: Int
    /// 8-bit IR brightness image (AGC applied by the camera), row-major.
    let ir: [UInt8]
    /// Raw temperature values in 1/64 Kelvin, row-major.
    let tempRaw: [UInt16]

    let minC: Double
    let maxC: Double
    let avgC: Double
    let minIndex: Int
    let maxIndex: Int

    static func celsius(fromRaw raw: UInt16) -> Double {
        Double(raw) / 64.0 - 273.15
    }

    /// Temperature in °C at sensor coordinates.
    func temperatureC(x: Int, y: Int) -> Double? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return Self.celsius(fromRaw: tempRaw[y * width + x])
    }

    /// Temperature per brightness level, read back from this frame.
    ///
    /// The camera's automatic gain maps the scene to 8-bit brightness by a
    /// curve the app is not told. It does not have to be: every pixel carries
    /// both its brightness and its temperature, so averaging the temperatures
    /// at each level recovers the mapping for this frame. Levels no pixel
    /// reached are filled in between their neighbours.
    func brightnessCurve() -> [Double] {
        var sums = [Double](repeating: 0, count: 256)
        var counts = [Int](repeating: 0, count: 256)
        ir.withUnsafeBufferPointer { brightness in
            tempRaw.withUnsafeBufferPointer { temps in
                var i = 0
                let count = min(brightness.count, temps.count)
                while i < count {
                    let level = Int(brightness[i])
                    sums[level] += Double(temps[i])
                    counts[level] += 1
                    i += 1
                }
            }
        }

        var curve = [Double](repeating: .nan, count: 256)
        for level in 0..<256 where counts[level] > 0 {
            curve[level] = sums[level] / Double(counts[level]) / 64.0 - 273.15
        }

        // Fill the gaps: carry the nearest reading outwards at the ends and
        // interpolate straight across any level in between that stayed empty.
        guard let first = curve.firstIndex(where: { !$0.isNaN }),
              let last = curve.lastIndex(where: { !$0.isNaN })
        else { return [Double](repeating: minC, count: 256) }
        for level in 0..<first { curve[level] = curve[first] }
        for level in (last + 1)..<256 { curve[level] = curve[last] }
        var level = first
        while level <= last {
            if curve[level].isNaN {
                var end = level
                while curve[end].isNaN { end += 1 }
                let low = curve[level - 1], high = curve[end]
                for gap in level..<end {
                    let t = Double(gap - level + 1) / Double(end - level + 1)
                    curve[gap] = low + (high - low) * t
                }
                level = end
            }
            level += 1
        }
        return curve
    }

    /// Min, max and mean over a rectangular area, in °C. Coordinates are
    /// clamped to the frame, so a region survives a rotation change.
    func statistics(inX x0: Int, y0: Int, x1: Int, y1: Int) -> (minC: Double, maxC: Double, avgC: Double)? {
        let lo = (x: max(0, min(x0, x1)), y: max(0, min(y0, y1)))
        let hi = (x: min(width - 1, max(x0, x1)), y: min(height - 1, max(y0, y1)))
        guard lo.x <= hi.x, lo.y <= hi.y else { return nil }

        var minRaw = UInt16.max
        var maxRaw = UInt16.min
        var sum: UInt64 = 0
        var count: UInt64 = 0
        tempRaw.withUnsafeBufferPointer { buf in
            for y in lo.y...hi.y {
                let row = y * width
                for x in lo.x...hi.x {
                    let raw = buf[row + x]
                    if raw < minRaw { minRaw = raw }
                    if raw > maxRaw { maxRaw = raw }
                    sum += UInt64(raw)
                    count += 1
                }
            }
        }
        guard count > 0 else { return nil }
        return (Self.celsius(fromRaw: minRaw),
                Self.celsius(fromRaw: maxRaw),
                Self.celsius(fromRaw: UInt16(sum / count)))
    }

    /// Returns a copy rotated by `quarterTurns` × 90° clockwise, optionally
    /// mirrored horizontally (applied after rotation). Min/max positions are
    /// re-derived; the statistics values stay identical.
    func transformed(quarterTurns: Int, mirrored: Bool) -> ThermalFrame {
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns == 0 && !mirrored { return self }

        let nw = turns % 2 == 0 ? width : height
        let nh = turns % 2 == 0 ? height : width
        var newIR = [UInt8](repeating: 0, count: width * height)
        var newTemps = [UInt16](repeating: 0, count: width * height)
        var minRaw: UInt16 = .max
        var maxRaw: UInt16 = .min
        var minIdx = 0
        var maxIdx = 0

        ir.withUnsafeBufferPointer { srcIR in
        tempRaw.withUnsafeBufferPointer { srcT in
        newIR.withUnsafeMutableBufferPointer { dstIR in
        newTemps.withUnsafeMutableBufferPointer { dstT in
            var y = 0
            while y < nh {
                var x = 0
                while x < nw {
                    let mx = mirrored ? nw - 1 - x : x
                    let sx: Int
                    let sy: Int
                    switch turns {
                    case 1: sx = y; sy = nw - 1 - mx
                    case 2: sx = width - 1 - mx; sy = height - 1 - y
                    case 3: sx = nh - 1 - y; sy = mx
                    default: sx = mx; sy = y
                    }
                    let di = y * nw + x
                    let si = sy * width + sx
                    dstIR[di] = srcIR[si]
                    let raw = srcT[si]
                    dstT[di] = raw
                    if raw < minRaw { minRaw = raw; minIdx = di }
                    if raw > maxRaw { maxRaw = raw; maxIdx = di }
                    x += 1
                }
                y += 1
            }
        }}}}

        return ThermalFrame(width: nw, height: nh, ir: newIR, tempRaw: newTemps,
                            minC: minC, maxC: maxC, avgC: avgC,
                            minIndex: minIdx, maxIndex: maxIdx)
    }

    /// Parses a raw USB frame buffer (markers included) into a ThermalFrame.
    static func parse(buffer: [UInt8], model: P3Model) -> ThermalFrame {
        let w = model.sensorWidth
        let h = model.sensorHeight
        let pixelCount = w * h

        var ir = [UInt8](repeating: 0, count: pixelCount)
        var temps = [UInt16](repeating: 0, count: pixelCount)

        var minRaw: UInt16 = .max
        var maxRaw: UInt16 = .min
        var minIdx = 0
        var maxIdx = 0
        var sum: UInt64 = 0

        buffer.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress! + 12 // skip start marker

            // Plain `while` loops on purpose: a `for i in 0..<n` goes through
            // generic collection witnesses in an unoptimised build, which costs
            // more than the pixel work itself.
            ir.withUnsafeMutableBufferPointer { dst in
                var i = 0
                while i < pixelCount {
                    dst[i] = base[i * 2]
                    i += 1
                }
            }

            // Rows (h+2)..<(2h+2): 16-bit LE temperature raw values.
            let thermalOffset = (h + 2) * w * 2
            temps.withUnsafeMutableBufferPointer { dst in
                var i = 0
                while i < pixelCount {
                    let lo = UInt16(base[thermalOffset + i * 2])
                    let hi = UInt16(base[thermalOffset + i * 2 + 1])
                    let raw = lo | (hi << 8)
                    dst[i] = raw
                    sum += UInt64(raw)
                    if raw < minRaw { minRaw = raw; minIdx = i }
                    if raw > maxRaw { maxRaw = raw; maxIdx = i }
                    i += 1
                }
            }
        }

        return ThermalFrame(
            width: w,
            height: h,
            ir: ir,
            tempRaw: temps,
            minC: celsius(fromRaw: minRaw),
            maxC: celsius(fromRaw: maxRaw),
            avgC: celsius(fromRaw: UInt16(sum / UInt64(pixelCount))),
            minIndex: minIdx,
            maxIndex: maxIdx
        )
    }
}
