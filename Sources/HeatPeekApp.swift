import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Close button (red X) quits the app instead of leaving it running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Stop the stream and reset the USB device on quit, so the camera leaves
    /// acquire mode and stops clicking once the app is gone.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            CameraController.shared.shutdownSynchronously()
        }
    }
}

/// Identifier of the separate statistics window.
enum StatsWindowID {
    static let value = "stats"
}

/// Identifier of the analysis window.
enum AnalysisWindowID {
    static let value = "analysis"
}

@main
struct HeatPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = CameraController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(controller)
        }
        .defaultSize(width: 1180, height: 860)

        .commands {
            CommandGroup(after: .newItem) { OpenAnalysisCommand() }
        }

        Window("Measurements", id: StatsWindowID.value) {
            StatsWindow()
                .environment(controller)
        }
        .defaultSize(width: 860, height: 460)

        Window("Analysis", id: AnalysisWindowID.value) {
            AnalysisWindow()
                .environment(controller)
        }
        .defaultSize(width: 900, height: 560)
    }
}

/// Menu entry for the analysis window. It lives in its own view so it can
/// reach `openWindow`, which is only available from the environment.
private struct OpenAnalysisCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open for analysis…") {
            if AnalysisStore.shared.chooseFile() {
                openWindow(id: AnalysisWindowID.value)
            }
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
    }
}
