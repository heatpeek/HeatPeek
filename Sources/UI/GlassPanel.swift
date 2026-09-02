import SwiftUI
import AppKit

/// Frosted background used by every floating panel: a system blur, a dark
/// layer on top so text stays readable over a bright thermal image, and the
/// hairline edge with corner marks.
struct GlassPanel<Content: View>: View {
    var padding: CGFloat = 12
    var tint: Double = 0.55
    var marks: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background {
                ZStack {
                    VisualEffectBackground(material: .hudWindow, blending: .withinWindow)
                    Color.black.opacity(tint)
                }
            }
            .blueprintFrame(opacity: marks ? 0.75 : 0)
    }
}

/// Bridges `NSVisualEffectView` into SwiftUI.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Repeating grid used behind the empty states.
struct BlueprintGrid: View {
    var spacing: CGFloat = 34

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(Theme.blueprintGrid), lineWidth: 1)
        }
    }
}
