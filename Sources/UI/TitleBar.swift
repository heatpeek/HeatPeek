import SwiftUI
import AppKit

/// Replaces both the toolbar and the status bar. Carries identity on the left,
/// output state and window switches on the right.
struct TitleBar: View {
    @Environment(CameraController.self) private var controller
    @Binding var showsInspector: Bool
    let openMeasurements: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(verbatim: "HEATPEEK")
                .font(.hpLabel(16, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Theme.text)

            if !controller.modelName.isEmpty {
                Text(verbatim: "\(controller.modelName) · \(controller.sensorDescription)")
                    .font(.hpMono(10))
                    .foregroundStyle(Theme.label)
            }

            stateChip

            Spacer(minLength: 12)

            outputStatus

            HStack(spacing: 4) {
                barButton(.chartLine, help: "Open measurements in a separate window",
                          active: controller.statsWindowOpen, action: openMeasurements)
                barButton(.panelRight, help: "Show or hide settings",
                          active: showsInspector) { showsInspector.toggle() }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: Theme.titleBarHeight)
        .background {
            ZStack {
                VisualEffectBackground(material: .headerView, blending: .withinWindow)
                Theme.titleBar
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    // MARK: - Pieces

    private var stateChip: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
            Text(verbatim: controller.state.label.uppercased())
                .font(.hpLabel(11))
                .tracking(1.2)
                .foregroundStyle(Theme.textSecondary)
            if controller.state == .streaming {
                Text(verbatim: String(format: "%.0f fps", controller.fps))
                    .font(.hpMono(10))
                    .foregroundStyle(Theme.label)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private var stateColor: Color {
        if controller.userWantsOff { return Theme.stateIdle }
        switch controller.state {
        case .streaming: return Theme.stateStreaming
        case .connecting: return Theme.stateConnecting
        case .error: return Theme.stateError
        case .disconnected: return Theme.stateIdle
        }
    }

    /// Plain status squares rather than icons: they report, they do not act.
    /// The MJPEG address is the exception — it has somewhere to go.
    private var outputStatus: some View {
        HStack(spacing: 12) {
            if syphonCount > 0 {
                statusItem(color: Theme.accentBright,
                           text: "SYPHON \u{00D7}\(syphonCount)")
            }
            if controller.obsEnabled {
                StreamAddress(text: MJPEGServer.displayAddress) {
                    if let url = URL(string: MJPEGServer.pageURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            if controller.isRecordingVideo {
                statusItem(color: Theme.stateError, text: "REC \(controller.videoClock)")
            }
            if controller.isRecording {
                statusItem(color: Theme.stateError, text: "CSV \(controller.recordingClock)")
            }
        }
    }

    private var syphonCount: Int {
        (controller.syphonEnabled ? 1 : 0) + (controller.statsSyphonEnabled ? 1 : 0)
    }

    private func statusItem(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 5, height: 5)
            Text(verbatim: text)
                .font(.hpMono(10))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func barButton(_ shape: IconShape, help: LocalizedStringKey,
                           active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(shape: shape, size: 16)
                .foregroundStyle(active ? Theme.accentBright : Theme.textSecondary)
                .frame(width: 30, height: 26)
                .background(active ? Theme.accentTint : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The MJPEG address, which opens the stream in the browser when clicked. It
/// keeps the look of the other status items and picks up the accent on hover,
/// so it reads as reachable without shouting.
private struct StreamAddress: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Theme.accentBright)
                    .frame(width: 5, height: 5)
                Text(verbatim: text)
                    .font(.hpMono(10))
                    .foregroundStyle(hovering ? Theme.accentBright : Theme.textSecondary)
                    .underline(hovering)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open the stream in the browser")
    }
}
