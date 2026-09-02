import Foundation
import Metal
import CoreGraphics
import Syphon

/// Publishes frames as a Syphon server so OBS (and any other Syphon client)
/// can pick them up as shared GPU textures — no JPEG encode, no HTTP, no
/// browser source in between.
/// Thread-safe: the UI starts and stops it, while frames are published from
/// the capture thread and the stats queue.
final class SyphonPublisher: @unchecked Sendable {
    private let lock = NSLock()
    /// Name OBS shows for this source.
    let name: String

    init(name: String) {
        self.name = name
    }

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var server: SyphonMetalServer?
    private var texture: MTLTexture?
    /// Scratch buffer for the CGImage → texture upload.
    private var uploadBuffer: [UInt8] = []

    private(set) var isRunning = false

    /// True while a Syphon client is attached, so the caller can skip the
    /// overlay compositing when nobody is watching.
    var hasClients: Bool {
        lock.lock(); defer { lock.unlock() }
        return server?.hasClients ?? false
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !isRunning else { return }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return
        }
        // Declared as returning a non-null id, but documented to fail — the
        // header's audit makes Swift import it as non-optional either way.
        let server = SyphonMetalServer(name: name, device: device, options: nil)
        self.device = device
        self.commandQueue = queue
        self.server = server
        isRunning = true
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        server?.stop()
        server = nil
        texture = nil
        commandQueue = nil
        device = nil
        uploadBuffer = []
        isRunning = false
    }

    /// Uploads the image to a Metal texture and publishes it. Cheap enough to
    /// call per frame: the texture is reused while the size stays the same.
    func publish(_ image: CGImage) {
        lock.lock(); defer { lock.unlock() }
        guard isRunning, let device, let commandQueue, let server else { return }

        let w = image.width
        let h = image.height
        if texture?.width != w || texture?.height != h {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .managed
            texture = device.makeTexture(descriptor: descriptor)
            uploadBuffer = [UInt8](repeating: 0, count: w * h * 4)
        }
        guard let texture else { return }

        // Draw the CGImage into a BGRA buffer matching the texture layout.
        let bytesPerRow = w * 4
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let drawn = uploadBuffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo) else { return false }
            // The buffer is reused across frames, so the image has to replace
            // its contents rather than be composited onto them: drawing a
            // translucent source over its own previous frame would add up to
            // an opaque one within a second.
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return }

        uploadBuffer.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, w, h),
                            mipmapLevel: 0,
                            withBytes: raw.baseAddress!,
                            bytesPerRow: bytesPerRow)
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        // Syphon's shared surface follows the OpenGL convention: row 0 is the
        // BOTTOM of the image. Drawing a CGImage into a bitmap context gives us
        // row 0 = top, so the texture counts as flipped and Syphon has to
        // re-render it. Passing false would take the straight-blit path in
        // SyphonMetalServer and hand consumers an upside-down image.
        server.publishFrameTexture(texture,
                                   on: commandBuffer,
                                   imageRegion: NSRect(x: 0, y: 0, width: w, height: h),
                                   flipped: true)
        commandBuffer.commit()
    }
}
