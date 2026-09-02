import SwiftUI
import AppKit

/// Reports when the window hosting this view opens and closes.
///
/// SwiftUI's `onDisappear` is not dependable for a closing window on macOS, so
/// this hooks the real `NSWindow` and listens for `willCloseNotification`.
struct WindowObserver: NSViewRepresentable {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window is only attached once the view enters the hierarchy.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.observe(window: window, onClose: onClose)
            onOpen?()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var token: NSObjectProtocol?

        func observe(window: NSWindow, onClose: (() -> Void)?) {
            guard token == nil else { return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main) { _ in onClose?() }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
