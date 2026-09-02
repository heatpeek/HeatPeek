import Foundation

/// Contrast Limited Adaptive Histogram Equalization on an 8-bit plane.
///
/// Plain histogram equalization stretches the whole image at once, which blows
/// out a scene that contains one very hot object. CLAHE equalizes each tile
/// separately, clips the histogram peaks so flat areas do not turn into noise,
/// and interpolates between neighbouring tiles so no tile edges show.
enum CLAHE {
    /// - Parameters:
    ///   - tiles: grid resolution; 8 means an 8×8 grid of tiles.
    ///   - clipLimit: histogram clip height as a multiple of the average bin
    ///     count. 1.0 is barely any enhancement, 4.0 is aggressive.
    static func apply(to plane: inout [UInt8], width: Int, height: Int,
                      tiles: Int = 8, clipLimit: Double = 2.5) {
        guard width > tiles, height > tiles, plane.count >= width * height else { return }

        let tw = width / tiles
        let th = height / tiles
        guard tw > 1, th > 1 else { return }

        // One 256-entry mapping per tile.
        var maps = [UInt8](repeating: 0, count: tiles * tiles * 256)
        var histogram = [Int](repeating: 0, count: 256)
        let pixelsPerTile = tw * th
        let clip = max(1, Int(clipLimit * Double(pixelsPerTile) / 256.0))

        plane.withUnsafeBufferPointer { src in
            maps.withUnsafeMutableBufferPointer { maps in
                for ty in 0..<tiles {
                    for tx in 0..<tiles {
                        for i in 0..<256 { histogram[i] = 0 }

                        // Tiles at the right/bottom edge absorb the remainder.
                        let x0 = tx * tw, x1 = tx == tiles - 1 ? width : x0 + tw
                        let y0 = ty * th, y1 = ty == tiles - 1 ? height : y0 + th
                        var y = y0
                        while y < y1 {
                            let row = y * width
                            var x = x0
                            while x < x1 {
                                histogram[Int(src[row + x])] += 1
                                x += 1
                            }
                            y += 1
                        }

                        // Clip the peaks and hand the excess back evenly.
                        var excess = 0
                        for i in 0..<256 where histogram[i] > clip {
                            excess += histogram[i] - clip
                            histogram[i] = clip
                        }
                        let share = excess / 256
                        var leftover = excess % 256
                        for i in 0..<256 {
                            histogram[i] += share
                            if leftover > 0 { histogram[i] += 1; leftover -= 1 }
                        }

                        // Cumulative histogram becomes the tile's mapping.
                        let total = (x1 - x0) * (y1 - y0)
                        let scale = 255.0 / Double(max(1, total))
                        var running = 0
                        let base = (ty * tiles + tx) * 256
                        for i in 0..<256 {
                            running += histogram[i]
                            maps[base + i] = UInt8(min(255, Int((Double(running) * scale).rounded())))
                        }
                    }
                }
            }
        }

        // Bilinear blend between the four surrounding tile mappings.
        var output = [UInt8](repeating: 0, count: width * height)
        plane.withUnsafeBufferPointer { src in
            maps.withUnsafeBufferPointer { maps in
                output.withUnsafeMutableBufferPointer { dst in
                    var y = 0
                    while y < height {
                        // Position between tile centres, in tile units.
                        let fy = min(Double(tiles) - 1.0,
                                     max(0.0, (Double(y) + 0.5) / Double(th) - 0.5))
                        let ty0 = Int(fy), ty1 = min(tiles - 1, ty0 + 1)
                        let wy = fy - Double(ty0)

                        var x = 0
                        while x < width {
                            let fx = min(Double(tiles) - 1.0,
                                         max(0.0, (Double(x) + 0.5) / Double(tw) - 0.5))
                            let tx0 = Int(fx), tx1 = min(tiles - 1, tx0 + 1)
                            let wx = fx - Double(tx0)

                            let v = Int(src[y * width + x])
                            let a = Double(maps[(ty0 * tiles + tx0) * 256 + v])
                            let b = Double(maps[(ty0 * tiles + tx1) * 256 + v])
                            let c = Double(maps[(ty1 * tiles + tx0) * 256 + v])
                            let d = Double(maps[(ty1 * tiles + tx1) * 256 + v])
                            let top = a + (b - a) * wx
                            let bottom = c + (d - c) * wx
                            dst[y * width + x] = UInt8(min(255, max(0, (top + (bottom - top) * wy).rounded())))
                            x += 1
                        }
                        y += 1
                    }
                }
            }
        }
        plane = output
    }
}
