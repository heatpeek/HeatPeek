import Foundation
import AVFoundation
import CoreGraphics

/// Records the composited picture to an H.264 MP4.
///
/// Frames arrive on the capture thread; everything here is guarded so the UI
/// can start and stop a recording at any time. Frames are dropped rather than
/// queued when the encoder is busy — the same backpressure rule as the network
/// outputs, so a slow encoder cannot grow memory without bound.
final class VideoRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startedAt: Date?
    private var size = CGSize.zero
    private var lastPresentation = CMTime.zero

    private(set) var isRecording = false
    private(set) var frameCount = 0
    private(set) var droppedFrames = 0
    private(set) var url: URL?

    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    /// H.264 wants even dimensions.
    private static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(width: Int(size.width) & ~1, height: Int(size.height) & ~1)
    }

    func start(url: URL, size rawSize: CGSize, fps: Int = 25) throws {
        stopImmediately()
        lock.lock(); defer { lock.unlock() }

        let size = Self.evenSize(rawSize)
        guard size.width >= 16, size.height >= 16 else {
            throw NSError(domain: "HeatPeek", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Picture is too small to record.")])
        }
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                // Thermal footage is smooth; this keeps files reasonable while
                // staying well clear of visible blocking.
                AVVideoAverageBitRateKey: Int(size.width * size.height) * 6,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        guard writer.canAdd(input) else {
            throw NSError(domain: "HeatPeek", code: 2, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Could not set up the video encoder.")])
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "HeatPeek", code: 3)
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.size = size
        self.url = url
        startedAt = Date()
        lastPresentation = .zero
        frameCount = 0
        droppedFrames = 0
        isRecording = true
    }

    /// Appends one frame. Safe to call from the capture thread.
    func append(_ image: CGImage) {
        lock.lock()
        guard isRecording, let input, let adaptor, let startedAt,
              image.width == Int(size.width), image.height == Int(size.height) else {
            // A different size means the user rotated mid-recording; the file
            // has a fixed geometry, so such frames are skipped.
            if isRecording { droppedFrames += 1 }
            lock.unlock()
            return
        }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
            droppedFrames += 1
            lock.unlock()
            return
        }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else {
            droppedFrames += 1
            lock.unlock()
            return
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer),
           let ctx = CGContext(data: base,
                               width: Int(size.width), height: Int(size.height),
                               bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                   | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        // Wall-clock timing, so dropped frames do not speed the video up.
        var time = CMTime(seconds: Date().timeIntervalSince(startedAt), preferredTimescale: 600)
        if time <= lastPresentation {
            time = lastPresentation + CMTime(value: 1, timescale: 600)
        }
        lastPresentation = time
        if adaptor.append(buffer, withPresentationTime: time) {
            frameCount += 1
        } else {
            droppedFrames += 1
        }
        lock.unlock()
    }

    /// Finishes the file. The callback runs once the writer is done.
    func finish(completion: @escaping (URL?) -> Void) {
        lock.lock()
        guard isRecording, let writer, let input else {
            lock.unlock()
            completion(nil)
            return
        }
        isRecording = false
        let finishedURL = url
        self.writer = nil
        self.input = nil
        self.adaptor = nil
        lock.unlock()

        input.markAsFinished()
        writer.finishWriting {
            completion(writer.status == .completed ? finishedURL : nil)
        }
    }

    /// Drops an in-progress recording without waiting, used when restarting.
    private func stopImmediately() {
        lock.lock()
        let writer = self.writer
        let input = self.input
        isRecording = false
        self.writer = nil
        self.input = nil
        self.adaptor = nil
        lock.unlock()
        input?.markAsFinished()
        writer?.cancelWriting()
    }
}
