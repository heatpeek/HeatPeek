import SwiftUI

/// Glass strip carrying the palette ramp, five labels and a marker at the
/// crosshair reading.
struct ColorScale: View {
    @Environment(CameraController.self) private var controller
    let frame: ThermalFrame
    let span: ScaleSpan

    var body: some View {
        GlassPanel(padding: 8) {
            HStack(spacing: 8) {
                labels
                ZStack(alignment: .top) {
                    LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
                        .frame(width: Theme.scaleBarWidth, height: Theme.scaleBarHeight)
                    marks
                }
            }
        }
    }

    // MARK: - Ramp

    private var stops: [Gradient.Stop] {
        stride(from: 0, through: 24, by: 1).map { i in
            let t = Double(i) / 24.0
            let index = Int((1 - t) * 255) * 3
            return Gradient.Stop(
                color: Color(red: Double(controller.palette.lut[index]) / 255,
                             green: Double(controller.palette.lut[index + 1]) / 255,
                             blue: Double(controller.palette.lut[index + 2]) / 255),
                location: t)
        }
    }

    /// Five readings down the ramp, from the range the picture was mapped
    /// over — including the camera's own gain, whose curve is recovered.
    private var labels: some View {
        let steps: [Double] = [0, 0.25, 0.5, 0.75, 1]
        return VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, t in
                Text(verbatim: controller.unit.number(span.value(at: t)))
                    .font(.hpMono(10))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxHeight: .infinity,
                           alignment: index == 0 ? .top
                               : (index == steps.count - 1 ? .bottom : .center))
            }
        }
        .frame(height: Theme.scaleBarHeight)
    }

    /// A white tick at the crosshair value, and a red one whenever a
    /// measurement is outside its limits.
    private var marks: some View {
        ZStack(alignment: .top) {
            if controller.overlay.crosshair,
               let fraction = span.fraction(ofPixelAt: frame.width / 2, y: frame.height / 2,
                                            in: frame) {
                tick(at: fraction, color: .white)
            }
            // An alarm names a temperature, not a pixel, so it can only be
            // placed where the ramp is evenly spaced.
            if controller.hasAlarm, let value = controller.alarmValue,
               let fraction = span.fraction(of: value) {
                tick(at: fraction, color: Color(hex: 0xFF453A))
            }
        }
    }

    private func tick(at fraction: Double, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: Theme.scaleBarWidth + 8, height: 1)
            .offset(y: fraction * Theme.scaleBarHeight)
    }
}
