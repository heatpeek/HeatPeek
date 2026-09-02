import SwiftUI

/// Four corner marks plus a hairline border — the recurring frame of the
/// interface. Nothing in the app uses rounded rectangles; corners are marked
/// rather than curved.
struct BlueprintFrame: ViewModifier {
    var color: Color = Theme.accentBright
    var opacity: Double = 0.75
    var length: CGFloat = 6
    var inset: CGFloat = 3
    var showsBorder: Bool = true

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                if showsBorder {
                    Rectangle()
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
                CornerMarks(length: length, inset: inset)
                    .stroke(color.opacity(opacity), lineWidth: 1)
            }
            .allowsHitTesting(false)
        }
    }
}

private struct CornerMarks: Shape {
    let length: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = rect.insetBy(dx: inset, dy: inset)
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: r.minX, y: r.minY + length), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX + length, y: r.minY)),
            (CGPoint(x: r.maxX - length, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + length)),
            (CGPoint(x: r.maxX, y: r.maxY - length), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX - length, y: r.maxY)),
            (CGPoint(x: r.minX + length, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY - length)),
        ]
        for (a, b, c) in corners {
            path.move(to: a)
            path.addLine(to: b)
            path.addLine(to: c)
        }
        return path
    }
}

extension View {
    /// Marks the four corners of a panel and draws its hairline edge.
    func blueprintFrame(color: Color = Theme.accentBright,
                        opacity: Double = 0.75,
                        length: CGFloat = 6,
                        inset: CGFloat = 3,
                        showsBorder: Bool = true) -> some View {
        modifier(BlueprintFrame(color: color, opacity: opacity,
                                length: length, inset: inset, showsBorder: showsBorder))
    }
}
