import SwiftUI

/// Shown whenever there is no live picture. Carries the supported-device table
/// so the most common question is answered before it is asked.
struct EmptyStateView: View {
    @Environment(CameraController.self) private var controller

    var body: some View {
        ZStack {
            Theme.emptyBackground
            BlueprintGrid()

            VStack(spacing: 22) {
                Icon(shape: icon, size: 46)
                    .foregroundStyle(Theme.accentLine)
                    .frame(width: 120, height: 120)
                    .blueprintFrame(length: 8, inset: 0)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.hpLabel(30))
                        .tracking(1.2)
                        .foregroundStyle(Theme.text)
                    Text(hint)
                        .font(.hpBody(14.5))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                action

                deviceTable
                    .padding(.top, 8)
            }
            .padding(40)
        }
    }

    // MARK: - Pieces

    private var icon: IconShape {
        if controller.userWantsOff { return .power }
        switch controller.state {
        case .error: return .circleAlert
        case .connecting, .streaming: return .aperture
        case .disconnected: return .cameraOff
        }
    }

    private var title: LocalizedStringKey {
        if controller.userWantsOff { return "Camera switched off" }
        switch controller.state {
        case .connecting: return "Connecting to the camera…"
        // Streaming has begun but no frame has arrived yet. Saying "no camera"
        // here is what made the start look like a failed attempt.
        case .streaming: return "Waiting for the first image…"
        case .error: return "No connection"
        case .disconnected: return "No camera found"
        }
    }

    private var hint: String {
        if controller.userWantsOff {
            return String(localized: "The stream is stopped and the USB device has been reset, so the camera no longer clicks.")
        }
        switch controller.state {
        case .connecting, .streaming:
            return String(localized: "The camera runs its shutter calibration first; that click is normal and takes about three seconds.")
        case .error(let message):
            return message
        case .disconnected:
            return String(localized: "Connect a supported camera via USB-C and the app will connect on its own.")
        }
    }

    @ViewBuilder
    private var action: some View {
        if controller.userWantsOff {
            PrimaryButton(title: "Switch camera on") { controller.powerToggle() }
        } else if case .error = controller.state {
            PrimaryButton(title: "Try again") { controller.connect() }
        } else if controller.state == .disconnected {
            PrimaryButton(title: "Connect") { controller.connect() }
        } else if controller.state == .connecting || controller.state == .streaming {
            ProgressView().controlSize(.small)
        }
    }

    private var deviceTable: some View {
        VStack(spacing: 0) {
            header(String(localized: "MODEL"), "VID / PID", String(localized: "RESOLUTION"))
            ForEach(P3Model.all, id: \.productID) { model in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                row(model.name,
                    String(format: "0x%04X / 0x%04X", model.vendorID, model.productID),
                    "\(model.sensorWidth) \u{00D7} \(model.sensorHeight)")
            }
        }
        .frame(width: 340)
        .blueprintFrame(opacity: 0.4, length: 5)
    }

    private func header(_ a: String, _ b: String, _ c: String) -> some View {
        row(a, b, c, isHeader: true)
    }

    private func row(_ a: String, _ b: String, _ c: String, isHeader: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: a)
                .font(isHeader ? .hpLabel(10) : .hpMono(11))
                .tracking(isHeader ? 1.2 : 0)
                .foregroundStyle(isHeader ? Theme.label : Theme.text)
                .frame(width: 70, alignment: .leading)
            Text(verbatim: b)
                .font(isHeader ? .hpLabel(10) : .hpMono(11))
                .tracking(isHeader ? 1.2 : 0)
                .foregroundStyle(isHeader ? Theme.label : Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: c)
                .font(isHeader ? .hpLabel(10) : .hpMono(11))
                .tracking(isHeader ? 1.2 : 0)
                .foregroundStyle(isHeader ? Theme.label : Theme.textSecondary)
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: isHeader ? 26 : 24)
    }
}
