import Foundation
import Network
import AppKit

/// Counts outstanding sends so the next frame waits for the slowest viewer.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ value: Int) { self.value = value }
    func decrementReachedZero() -> Bool {
        lock.lock(); defer { lock.unlock() }
        value -= 1
        return value <= 0
    }
}

/// Minimal MJPEG-over-HTTP server on localhost so the thermal image can be
/// pulled into OBS (Browser source) or any browser/player. No dependencies.
final class MJPEGServer {
    static let port: NWEndpoint.Port = 8377
    static let pageURL = "http://localhost:8377/"
    /// Host and port as shown in the interface.
    static let displayAddress = "localhost:8377"
    static let streamURL = "http://localhost:8377/stream"

    private let queue = DispatchQueue(label: "com.heatpeek.HeatPeek.mjpeg")
    private var listener: NWListener?
    private var streamClients: [NWConnection] = []
    private let boundary = "p3thermalframe"

    private let clientLock = NSLock()
    private var clientCount = 0
    /// True while a frame is still being encoded or sent. Without this the
    /// queue grows without bound as soon as a viewer cannot keep up, and the
    /// pending frames pile up in memory.
    private var busy = false
    /// True while at least one viewer is attached, so the app can skip the
    /// (relatively costly) overlay compositing when nobody is watching.
    var hasClients: Bool {
        clientLock.lock(); defer { clientLock.unlock() }
        return clientCount > 0
    }
    private func setClientCount(_ n: Int) {
        clientLock.lock(); clientCount = n; clientLock.unlock()
    }

    /// Called when the port cannot be taken, so the interface does not go on
    /// claiming to serve a stream that nothing is listening for.
    var onFailure: (@Sendable () -> Void)?

    func start() {
        queue.sync {
            guard listener == nil else { return }
            let params = NWParameters.tcp
            // Bind to loopback only: the stream is not exposed to the network.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: Self.port)
            params.allowLocalEndpointReuse = true
            guard let l = try? NWListener(using: params) else {
                onFailure?()
                return
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            // Binding happens asynchronously, so a port already in use only
            // shows up here.
            l.stateUpdateHandler = { [weak self] state in
                guard case .failed = state else { return }
                self?.stop()
                self?.onFailure?()
            }
            l.start(queue: queue)
            listener = l
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            streamClients.forEach { $0.cancel() }
            streamClients.removeAll()
            setClientCount(0)
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, let data, error == nil,
                  let request = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            if request.hasPrefix("GET /stream") {
                let header = "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: multipart/x-mixed-replace; boundary=\(self.boundary)\r\n"
                    + "Cache-Control: no-cache\r\nPragma: no-cache\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
                self.streamClients.append(conn)
                self.setClientCount(self.streamClients.count)
            } else {
                let html = """
                <!doctype html><html><head><title>HeatPeek</title></head>\
                <body style="margin:0;background:#000;display:flex;align-items:center;\
                justify-content:center;height:100vh">\
                <img src="/stream" style="width:100%;height:100%;object-fit:contain"></body></html>
                """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
                    + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
                conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
    }

    /// Encodes the frame as JPEG and pushes it to all connected stream clients.
    func publish(_ image: CGImage) {
        // Drop this frame rather than queue it when the previous one is still
        // in flight — for live video, late frames are worthless anyway.
        clientLock.lock()
        if busy || clientCount == 0 {
            clientLock.unlock()
            return
        }
        busy = true
        clientLock.unlock()

        queue.async {
            self.streamClients.removeAll { conn in
                switch conn.state {
                case .cancelled, .failed: return true
                default: return false
                }
            }
            self.setClientCount(self.streamClients.count)
            guard !self.streamClients.isEmpty else {
                self.clearBusy()
                return
            }

            let rep = NSBitmapImageRep(cgImage: image)
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                self.clearBusy()
                return
            }
            var part = Data("--\(self.boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
            part.append(jpeg)
            part.append(Data("\r\n".utf8))

            // Release the slot only once every viewer has taken the frame. No
            // blocking wait here: the completion runs on this same queue, so
            // waiting for it would deadlock.
            let remaining = Counter(self.streamClients.count)
            for client in self.streamClients {
                client.send(content: part, completion: .contentProcessed { _ in
                    if remaining.decrementReachedZero() { self.clearBusy() }
                })
            }
        }
    }

    private func clearBusy() {
        clientLock.lock(); busy = false; clientLock.unlock()
    }
}
