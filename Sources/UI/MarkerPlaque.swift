import SwiftUI

/// Label beside a deliberately placed measurement: a small frosted plate in
/// the marker's own colour. Min/max markers stay plain text so they read
/// quieter than the points the user chose.
struct MarkerPlaque: View {
    let name: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: name.uppercased())
                .font(.hpLabel(12))
                .tracking(1.2)
                .foregroundStyle(color.opacity(0.95))
            Text(verbatim: value)
                .font(.hpMono(11))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background {
            ZStack {
                VisualEffectBackground(material: .hudWindow, blending: .withinWindow)
                Color(red: 10 / 255, green: 12 / 255, blue: 15 / 255, opacity: 0.62)
            }
        }
        .overlay(Rectangle().strokeBorder(color.opacity(0.42), lineWidth: 1))
        .fixedSize()
    }
}

/// Plain shadowed text, used for the min and max markers.
struct MarkerText: View {
    let value: String
    let color: Color

    var body: some View {
        Text(verbatim: value)
            .font(.hpMono(12))
            .foregroundStyle(color)
            .shadow(color: .black.opacity(0.85), radius: 3)
            .fixedSize()
    }
}

/// Dot with a glow so it survives a bright thermal image.
struct MarkerDot: View {
    let color: Color
    var size: CGFloat = 11

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .shadow(color: color.opacity(0.7), radius: 6)
    }
}

/// Open circle with four ticks, marking the centre of the image.
struct CrosshairMark: View {
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.white, lineWidth: 1.5)
                .frame(width: 11, height: 11)
            ForEach(0..<4, id: \.self) { index in
                Rectangle()
                    .fill(.white)
                    .frame(width: index < 2 ? 7 : 1.5, height: index < 2 ? 1.5 : 7)
                    .offset(x: index == 0 ? -11 : (index == 1 ? 11 : 0),
                            y: index == 2 ? -11 : (index == 3 ? 11 : 0))
            }
        }
        .shadow(color: .black.opacity(0.7), radius: 2)
    }
}
