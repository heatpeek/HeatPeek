import SwiftUI

/// Stroke-drawn icon on a 24x24 grid, scaled to the requested size.
///
/// The set is stroke-based with a uniform 1.5 pt weight so icons keep the same
/// visual weight as the hairlines around them.
struct Icon: View {
    let shape: IconShape
    var size: CGFloat = 18
    var weight: CGFloat = 1.5

    var body: some View {
        IconPath(shape: shape)
            .stroke(style: StrokeStyle(lineWidth: weight * 24 / size,
                                       lineCap: .round,
                                       lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// Builds one icon's outline in its own 24x24 coordinate space.
private struct IconPath: Shape {
    let shape: IconShape

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for element in shape.elements {
            switch element {
            case .path(let d):
                path.addPath(SVGPath.parse(d))
            case .circle(let raw):
                let v = SVGPath.numbers(raw)
                guard v.count >= 3 else { break }
                path.addEllipse(in: CGRect(x: v[0] - v[2], y: v[1] - v[2],
                                           width: v[2] * 2, height: v[2] * 2))
            case .line(let raw):
                let v = SVGPath.numbers(raw)
                guard v.count >= 4 else { break }
                path.move(to: CGPoint(x: v[0], y: v[1]))
                path.addLine(to: CGPoint(x: v[2], y: v[3]))
            case .rect(let raw):
                let v = SVGPath.numbers(raw)
                guard v.count >= 4 else { break }
                let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
                let radius = v.count > 4 ? v[4] : 0
                path.addPath(Path(roundedRect: r, cornerRadius: radius))
            case .polyline(let raw), .polygon(let raw):
                let v = SVGPath.numbers(raw)
                guard v.count >= 4 else { break }
                path.move(to: CGPoint(x: v[0], y: v[1]))
                var i = 2
                while i + 1 < v.count {
                    path.addLine(to: CGPoint(x: v[i], y: v[i + 1]))
                    i += 2
                }
                if case .polygon = element { path.closeSubpath() }
            }
        }
        let scale = min(rect.width, rect.height) / 24
        return path.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

/// Minimal SVG path-data reader covering the commands the icon set uses,
/// including elliptical arcs.
enum SVGPath {
    static func numbers(_ text: String) -> [CGFloat] {
        var values: [CGFloat] = []
        var current = ""
        var previous: Character = " "
        for character in text {
            if character.isNumber || character == "." {
                // A second dot starts a new number, as in "1.5.5".
                if character == "." && current.contains(".") {
                    values.append(CGFloat(Double(current) ?? 0))
                    current = "."
                } else {
                    current.append(character)
                }
            } else if character == "-" && !(previous == "e" || previous == "E") {
                if !current.isEmpty { values.append(CGFloat(Double(current) ?? 0)) }
                current = "-"
            } else if character == "e" || character == "E" {
                current.append(character)
            } else {
                if !current.isEmpty { values.append(CGFloat(Double(current) ?? 0)) }
                current = ""
            }
            previous = character
        }
        if !current.isEmpty { values.append(CGFloat(Double(current) ?? 0)) }
        return values
    }

    static func parse(_ data: String) -> Path {
        var path = Path()
        var point = CGPoint.zero
        var start = CGPoint.zero
        var control = CGPoint.zero
        var index = data.startIndex
        var command: Character = "M"

        func nextNumbers(_ count: Int) -> [CGFloat] {
            var raw = ""
            while index < data.endIndex, !"MmLlHhVvCcSsQqTtAaZz".contains(data[index]) {
                raw.append(data[index])
                index = data.index(after: index)
            }
            var values = numbers(raw)
            // Repeat sets are handled by the caller; pad short reads with zeros.
            while values.count < count { values.append(0) }
            return values
        }

        while index < data.endIndex {
            let character = data[index]
            if "MmLlHhVvCcSsQqTtAaZz".contains(character) {
                command = character
                index = data.index(after: index)
                if command == "Z" || command == "z" {
                    path.closeSubpath()
                    point = start
                    continue
                }
            }
            let relative = command.isLowercase
            switch command.lowercased().first! {
            case "m":
                let v = nextNumbers(2)
                var i = 0
                while i + 1 < v.count {
                    let p = relative ? CGPoint(x: point.x + v[i], y: point.y + v[i + 1])
                                     : CGPoint(x: v[i], y: v[i + 1])
                    if i == 0 { path.move(to: p); start = p } else { path.addLine(to: p) }
                    point = p
                    i += 2
                }
            case "l":
                let v = nextNumbers(2)
                var i = 0
                while i + 1 < v.count {
                    let p = relative ? CGPoint(x: point.x + v[i], y: point.y + v[i + 1])
                                     : CGPoint(x: v[i], y: v[i + 1])
                    path.addLine(to: p); point = p
                    i += 2
                }
            case "h":
                for value in nextNumbers(1) {
                    point = CGPoint(x: relative ? point.x + value : value, y: point.y)
                    path.addLine(to: point)
                }
            case "v":
                for value in nextNumbers(1) {
                    point = CGPoint(x: point.x, y: relative ? point.y + value : value)
                    path.addLine(to: point)
                }
            case "c":
                let v = nextNumbers(6)
                var i = 0
                while i + 5 < v.count {
                    let base = relative ? point : .zero
                    let c1 = CGPoint(x: base.x + v[i], y: base.y + v[i + 1])
                    let c2 = CGPoint(x: base.x + v[i + 2], y: base.y + v[i + 3])
                    let end = CGPoint(x: base.x + v[i + 4], y: base.y + v[i + 5])
                    path.addCurve(to: end, control1: c1, control2: c2)
                    control = c2; point = end
                    i += 6
                }
            case "s":
                let v = nextNumbers(4)
                var i = 0
                while i + 3 < v.count {
                    let base = relative ? point : .zero
                    let c1 = CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
                    let c2 = CGPoint(x: base.x + v[i], y: base.y + v[i + 1])
                    let end = CGPoint(x: base.x + v[i + 2], y: base.y + v[i + 3])
                    path.addCurve(to: end, control1: c1, control2: c2)
                    control = c2; point = end
                    i += 4
                }
            case "q":
                let v = nextNumbers(4)
                var i = 0
                while i + 3 < v.count {
                    let base = relative ? point : .zero
                    let c = CGPoint(x: base.x + v[i], y: base.y + v[i + 1])
                    let end = CGPoint(x: base.x + v[i + 2], y: base.y + v[i + 3])
                    path.addQuadCurve(to: end, control: c)
                    control = c; point = end
                    i += 4
                }
            case "a":
                let v = nextNumbers(7)
                var i = 0
                while i + 6 < v.count {
                    let base = relative ? point : .zero
                    let end = CGPoint(x: base.x + v[i + 5], y: base.y + v[i + 6])
                    addArc(&path, from: point, to: end,
                           rx: v[i], ry: v[i + 1], rotation: v[i + 2],
                           largeArc: v[i + 3] != 0, sweep: v[i + 4] != 0)
                    point = end
                    i += 7
                }
            default:
                index = data.index(after: index)
            }
        }
        return path
    }

    /// Endpoint-to-centre conversion for an elliptical arc, per the SVG spec.
    private static func addArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat,
                               largeArc: Bool, sweep: Bool) {
        guard rxIn != 0, ryIn != 0 else { path.addLine(to: p1); return }
        var rx = abs(rxIn), ry = abs(ryIn)
        let phi = rotation * .pi / 180
        let dx2 = (p0.x - p1.x) / 2, dy2 = (p0.y - p1.y) / 2
        let x1 = cos(phi) * dx2 + sin(phi) * dy2
        let y1 = -sin(phi) * dx2 + cos(phi) * dy2

        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }

        let sign: CGFloat = largeArc == sweep ? -1 : 1
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coefficient = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)
        let cx1 = coefficient * rx * y1 / ry
        let cy1 = -coefficient * ry * x1 / rx
        let cx = cos(phi) * cx1 - sin(phi) * cy1 + (p0.x + p1.x) / 2
        let cy = sin(phi) * cx1 + cos(phi) * cy1 + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard len > 0 else { return 0 }
            let value = max(-1, min(1, dot / len))
            return (ux * vy - uy * vx < 0 ? -1 : 1) * acos(value)
        }
        let start = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry,
                          (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        // Approximate the arc with cubic segments of at most 90 degrees.
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let alpha = 4.0 / 3.0 * tan(step / 4)
        var theta = start
        var current = p0
        for _ in 0..<segments {
            let next = theta + step
            let cosT = cos(theta), sinT = sin(theta)
            let cosN = cos(next), sinN = sin(next)

            func point(_ c: CGFloat, _ s: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * cosPhi(c) - ry * sinPhi(s),
                        y: cy + rx * sinPhiX(c) + ry * cosPhiY(s))
            }
            func cosPhi(_ c: CGFloat) -> CGFloat { cos(phi) * c }
            func sinPhi(_ s: CGFloat) -> CGFloat { sin(phi) * s }
            func sinPhiX(_ c: CGFloat) -> CGFloat { sin(phi) * c }
            func cosPhiY(_ s: CGFloat) -> CGFloat { cos(phi) * s }

            let end = point(cosN, sinN)
            let d1 = CGPoint(x: -rx * cos(phi) * sinT - ry * sin(phi) * cosT,
                             y: -rx * sin(phi) * sinT + ry * cos(phi) * cosT)
            let d2 = CGPoint(x: -rx * cos(phi) * sinN - ry * sin(phi) * cosN,
                             y: -rx * sin(phi) * sinN + ry * cos(phi) * cosN)
            path.addCurve(to: end,
                          control1: CGPoint(x: current.x + alpha * d1.x, y: current.y + alpha * d1.y),
                          control2: CGPoint(x: end.x - alpha * d2.x, y: end.y - alpha * d2.y))
            current = end
            theta = next
        }
    }
}
