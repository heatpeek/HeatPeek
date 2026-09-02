import SwiftUI

/// Floating strip of actions, centred under the image. It fades back while the
/// mouse rests and returns on movement, but stays fully visible whenever the
/// image is frozen or a recording is running.
struct ControlBar: View {
    @Environment(CameraController.self) private var controller
    @Binding var isAwake: Bool

    var body: some View {
        GlassPanel(padding: 6) {
            HStack(spacing: 4) {
                button(.power,
                       help: controller.userWantsOff
                           ? String(localized: "Switch camera on")
                           : String(localized: "Switch camera off — stops the stream and the shutter clicking"),
                       tint: controller.userWantsOff ? nil : Theme.stateStreaming,
                       active: !controller.userWantsOff) {
                    controller.powerToggle()
                }

                button(controller.frozen ? .play : .pause,
                       help: controller.frozen
                           ? String(localized: "Resume live image")
                           : String(localized: "Freeze image"),
                       tint: controller.frozen ? Theme.accentBright : nil,
                       active: controller.frozen,
                       enabled: controller.state == .streaming) {
                    controller.frozen.toggle()
                }

                Rectangle().fill(Theme.hairline).frame(width: 1, height: 26)

                button(.camera,
                       help: String(localized: "Snapshot: image as PNG and temperature matrix as CSV"),
                       enabled: controller.frame != nil) {
                    controller.saveSnapshot()
                }

                button(.video,
                       help: controller.isRecordingVideo
                           ? String(localized: "Finish the video")
                           : String(localized: "Record the picture as an MP4 video"),
                       tint: controller.isRecordingVideo ? Theme.stateError : nil,
                       active: controller.isRecordingVideo,
                       enabled: controller.state == .streaming || controller.isRecordingVideo) {
                    controller.toggleVideoRecording()
                }

                recordButton

                Rectangle().fill(Theme.hairline).frame(width: 1, height: 26)

                overlayToggle
            }
        }
        .opacity(isAwake ? 1 : 0.35)
        .animation(.easeOut(duration: 0.25), value: isAwake)
    }

    /// Decides whether saved photos and recorded video carry the on-image
    /// information. It sits with the capture actions because that is where the
    /// choice matters; the same setting appears under Output.
    private var overlayToggle: some View {
        Button {
            controller.captureWithOverlay.toggle()
        } label: {
            HStack(spacing: 7) {
                Icon(shape: .layers, size: 16)
                Text("With overlay")
                    .font(.hpLabel(11.5))
                    .tracking(0.9)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(controller.captureWithOverlay ? Theme.accentBright : Theme.textSecondary)
            .padding(.horizontal, 11)
            .frame(height: 40)
            .background(controller.captureWithOverlay ? Theme.accentTint : Color.clear)
            .overlay {
                if controller.captureWithOverlay {
                    Rectangle().strokeBorder(Theme.accentBright.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(controller.captureWithOverlay
              ? String(localized: "Photos and video are saved with the on-image information")
              : String(localized: "Photos and video are saved as the plain picture"))
    }

    /// Carries its own elapsed time, so it is wider than the icon buttons.
    private var recordButton: some View {
        Button {
            controller.toggleRecording()
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(controller.isRecording ? Theme.stateError : Theme.textSecondary)
                    .frame(width: 9, height: 9)
                if controller.isRecording {
                    Text(verbatim: controller.recordingClock)
                        .font(.hpMono(11.5))
                        .foregroundStyle(Theme.text)
                }
            }
            .padding(.horizontal, controller.isRecording ? 11 : 0)
            .frame(minWidth: 44)
            .frame(height: 40)
            .background(controller.isRecording ? Theme.stateError.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.state != .streaming && !controller.isRecording)
        .help(controller.isRecording
              ? String(localized: "Finish the recording")
              : String(localized: "Record temperature over time as CSV"))
    }

    private func button(_ shape: IconShape, help: String, tint: Color? = nil,
                        active: Bool = false, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(shape: shape, size: 18)
                .foregroundStyle(enabled ? (tint ?? Theme.text) : Theme.label.opacity(0.5))
                .frame(width: 44, height: 40)
                .background(active ? (tint ?? Theme.accentBright).opacity(0.14) : Color.clear)
                .overlay {
                    if active {
                        Rectangle().strokeBorder((tint ?? Theme.accentBright).opacity(0.55), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}
