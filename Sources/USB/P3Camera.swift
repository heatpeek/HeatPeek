import Foundation
import IOUSBHost
import IOKit
import IOKit.usb

/// Errors thrown by the P3 USB driver layer.
enum P3CameraError: LocalizedError {
    case deviceNotFound
    case interfaceNotFound(Int)
    case pipeNotFound
    case controlTransferFailed(String)
    case unexpectedStatus(expected: UInt8, got: UInt8)
    case streamingFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return String(localized: "No P3/P1 thermal camera found. Is the camera connected via USB?")
        case .interfaceNotFound(let n):
            return String(localized: "USB interface \(n) not found.")
        case .pipeNotFound:
            return String(localized: "Bulk endpoint 0x81 not found.")
        case .controlTransferFailed(let msg):
            return String(localized: "USB control transfer failed: \(msg)")
        case .unexpectedStatus(let expected, let got):
            let expectedHex = String(format: "0x%02x", expected)
            let gotHex = String(format: "0x%02x", got)
            return String(localized: "Unexpected camera status: expected \(expectedHex), got \(gotHex)")
        case .streamingFailed(let msg):
            return String(localized: "Could not start streaming: \(msg)")
        }
    }
}

/// Supported camera models.
struct P3Model {
    let name: String
    let vendorID: Int
    let productID: Int
    let sensorWidth: Int
    let sensorHeight: Int

    /// Total pixel rows per frame: IR image + 2 metadata rows + thermal data.
    var frameRows: Int { sensorHeight * 2 + 2 }
    /// Pixel payload in bytes (16-bit per pixel).
    var frameSize: Int { frameRows * sensorWidth * 2 }
    /// Payload plus 12-byte start and end markers.
    var frameReadSize: Int { frameSize + 24 }

    static let p3 = P3Model(name: "P3", vendorID: 0x3474, productID: 0x45A2, sensorWidth: 256, sensorHeight: 192)
    static let p1 = P3Model(name: "P1", vendorID: 0x3474, productID: 0x45C2, sensorWidth: 160, sensorHeight: 120)
    static let all: [P3Model] = [.p3, .p1]
}

/// Device information read from the camera at connect time.
struct P3DeviceInfo {
    var name = ""
    var firmwareVersion = ""
    var partNumber = ""
    var serialNumber = ""
    var hardwareVersion = ""
    var modelLong = ""
}

/// Low-level driver for InfiRay P3/P1 thermal cameras, speaking the
/// vendor protocol documented in jvdillon/p3-ir-camera (P3_PROTOCOL.md)
/// via Apple's user-space IOUSBHost framework.
final class P3Camera {
    let model: P3Model
    private(set) var info = P3DeviceInfo()

    private var controlInterface: IOUSBHostInterface?
    private var streamInterface: IOUSBHostInterface?
    private var bulkPipe: IOUSBHostPipe?
    /// Reused across frames. The USB framework keeps a reference to the
    /// buffer it is handed, so a fresh one per call would accumulate.
    private let chunkBuffer = NSMutableData(length: P3Camera.chunkSize)!

    static let chunkSize = 16384

    // Pre-computed protocol commands (18 bytes each, CRC16 included).
    private enum Command {
        static let readName       = Data(hex: "0101810001000000000000001e0000004f90")
        static let readVersion    = Data(hex: "0101810002000000000000000c0000001f63")
        static let readPartNumber = Data(hex: "01018100060000000000000040000000654f")
        static let readSerial     = Data(hex: "01018100070000000000000040000000104c")
        static let readHWVersion  = Data(hex: "010181000a00000000000000400000001959")
        static let readModelLong  = Data(hex: "010181000f0000000000000040000000b857")
        static let startStream    = Data(hex: "012f81000000000000000000010000004930")
        static let gainLow        = Data(hex: "012f41000000000000000000000000003c3a")
        static let gainHigh       = Data(hex: "012f41000100000000000000000000004939")
        static let shutter        = Data(hex: "01364300000000000000000000000000cd0b")
    }

    private init(model: P3Model, controlInterface: IOUSBHostInterface, streamInterface: IOUSBHostInterface) {
        self.model = model
        self.controlInterface = controlInterface
        self.streamInterface = streamInterface
    }

    deinit { close() }

    // MARK: - Discovery / open

    /// Finds the first attached P3/P1 camera and claims its interfaces.
    static func open() throws -> P3Camera {
        for model in P3Model.all {
            guard let deviceService = findDeviceService(vendorID: model.vendorID, productID: model.productID) else {
                continue
            }
            defer { IOObjectRelease(deviceService) }

            guard let if0 = interfaceService(ofDevice: deviceService, interfaceNumber: 0) else {
                throw P3CameraError.interfaceNotFound(0)
            }
            guard let if1 = interfaceService(ofDevice: deviceService, interfaceNumber: 1) else {
                IOObjectRelease(if0)
                throw P3CameraError.interfaceNotFound(1)
            }
            defer { IOObjectRelease(if0); IOObjectRelease(if1) }

            let control = try IOUSBHostInterface(__ioService: if0, options: [], queue: nil, interestHandler: nil)
            let stream = try IOUSBHostInterface(__ioService: if1, options: [], queue: nil, interestHandler: nil)
            return P3Camera(model: model, controlInterface: control, streamInterface: stream)
        }
        throw P3CameraError.deviceNotFound
    }

    /// Returns true if a supported camera is currently attached (without claiming it).
    static func isDevicePresent() -> Bool {
        for model in P3Model.all {
            if let service = findDeviceService(vendorID: model.vendorID, productID: model.productID) {
                IOObjectRelease(service)
                return true
            }
        }
        return false
    }

    /// Resets and re-enumerates the USB device — the software equivalent of
    /// unplugging it. Per P3_PROTOCOL.md the camera stays in acquire mode and
    /// keeps firing its shutter roughly every 90 s "unless unplugged or reset",
    /// so stopping the stream alone does not silence the clicking.
    /// All interfaces must be released before calling this.
    static func resetAttachedDevice() throws {
        for model in P3Model.all {
            guard let service = findDeviceService(vendorID: model.vendorID, productID: model.productID) else {
                continue
            }
            defer { IOObjectRelease(service) }
            let device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
            try device.reset()
            return
        }
        throw P3CameraError.deviceNotFound
    }

    private static func findDeviceService(vendorID: Int, productID: Int) -> io_service_t? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return nil }
        matching["idVendor"] = vendorID
        matching["idProduct"] = productID
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        return service != 0 ? service : nil
    }

    private static func interfaceService(ofDevice device: io_service_t, interfaceNumber: Int) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let child = IOIteratorNext(iterator), child != 0 {
            var matched = false
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
               let numRef = IORegistryEntryCreateCFProperty(child, "bInterfaceNumber" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let num = numRef as? Int, num == interfaceNumber {
                matched = true
            }
            if matched { return child }
            IOObjectRelease(child)
        }
        return nil
    }

    /// Stops the video stream (alt setting 0 also ends the camera's periodic
    /// shutter/NUC clicking, matching the reference driver's stop_streaming).
    func stopStreaming() {
        bulkPipe = nil
        try? streamInterface?.selectAlternateSetting(0)
    }

    func close() {
        stopStreaming()
        streamInterface = nil
        controlInterface = nil
    }

    // MARK: - Control transfers

    private func controlOut(bmRequestType: UInt8, bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data?) throws {
        guard let iface = controlInterface else { throw P3CameraError.controlTransferFailed(String(localized: "Interface closed")) }
        let request = IOUSBDeviceRequest(
            bmRequestType: bmRequestType,
            bRequest: bRequest,
            wValue: wValue,
            wIndex: wIndex,
            wLength: UInt16(data?.count ?? 0)
        )
        let buffer: NSMutableData? = data.map { NSMutableData(data: $0) }
        var transferred = 0
        do {
            try iface.__send(request, data: buffer, bytesTransferred: &transferred,
                             completionTimeout: TimeInterval(1.0))
        } catch {
            throw P3CameraError.controlTransferFailed(error.localizedDescription)
        }
    }

    private func controlIn(bmRequestType: UInt8, bRequest: UInt8, wValue: UInt16, wIndex: UInt16, length: Int) throws -> Data {
        guard let iface = controlInterface else { throw P3CameraError.controlTransferFailed(String(localized: "Interface closed")) }
        let request = IOUSBDeviceRequest(
            bmRequestType: bmRequestType,
            bRequest: bRequest,
            wValue: wValue,
            wIndex: wIndex,
            wLength: UInt16(length)
        )
        let buffer = NSMutableData(length: length)!
        var transferred = 0
        do {
            try iface.__send(request, data: buffer, bytesTransferred: &transferred,
                             completionTimeout: TimeInterval(1.0))
        } catch {
            throw P3CameraError.controlTransferFailed(error.localizedDescription)
        }
        return (buffer as Data).prefix(transferred)
    }

    /// Reads the 1-byte status register (0x02 after a write command, 0x03 after reading response data).
    private func readStatus() throws -> UInt8 {
        let data = try controlIn(bmRequestType: 0xC1, bRequest: 0x22, wValue: 0, wIndex: 0, length: 1)
        return data.first ?? 0
    }

    private func expectStatus(_ expected: UInt8) throws {
        var last: UInt8 = 0
        for _ in 0..<10 {
            last = try readStatus()
            if last == expected { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw P3CameraError.unexpectedStatus(expected: expected, got: last)
    }

    /// Sends an 18-byte command; when `responseLength` > 0, reads back that many response bytes.
    @discardableResult
    private func sendCommand(_ command: Data, responseLength: Int = 0) throws -> Data {
        try controlOut(bmRequestType: 0x41, bRequest: 0x20, wValue: 0, wIndex: 0, data: command)
        try expectStatus(0x02)
        var response = Data()
        if responseLength > 0 {
            response = try controlIn(bmRequestType: 0xC1, bRequest: 0x21, wValue: 0, wIndex: 0, length: responseLength)
            try expectStatus(0x03)
        }
        return response
    }

    private static func string(from data: Data) -> String {
        let trimmed = data.prefix { $0 != 0 }
        return String(data: trimmed, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - High-level operations

    /// Reads all device information registers.
    func readDeviceInfo() throws {
        info.name = Self.string(from: try sendCommand(Command.readName, responseLength: 30))
        info.firmwareVersion = Self.string(from: try sendCommand(Command.readVersion, responseLength: 12))
        info.partNumber = Self.string(from: try sendCommand(Command.readPartNumber, responseLength: 64))
        info.serialNumber = Self.string(from: try sendCommand(Command.readSerial, responseLength: 64))
        info.hardwareVersion = Self.string(from: try sendCommand(Command.readHWVersion, responseLength: 64))
        info.modelLong = Self.string(from: try sendCommand(Command.readModelLong, responseLength: 64))
    }

    /// Runs the full streaming init sequence from P3_PROTOCOL.md.
    func startStreaming() throws {
        guard let stream = streamInterface else { throw P3CameraError.streamingFailed(String(localized: "Interface closed")) }

        _ = try sendCommand(Command.startStream, responseLength: 1)
        Thread.sleep(forTimeInterval: 1.0)

        try stream.selectAlternateSetting(1)
        try controlOut(bmRequestType: 0x40, bRequest: 0xEE, wValue: 0, wIndex: 1, data: nil)
        Thread.sleep(forTimeInterval: 2.0)

        bulkPipe = try stream.copyPipe(withAddress: 0x81)

        // Probe read: a timeout here is expected while the camera warms up.
        let probe = NSMutableData(length: 16384)!
        var n = 0
        try? bulkPipe?.__sendIORequest(with: probe, bytesTransferred: &n, completionTimeout: 0.1)

        // Final start-stream command kicks off the actual frame flow.
        _ = try sendCommand(Command.startStream, responseLength: 1)
    }

    /// Toggles between high gain (-20…150 °C) and low gain (0…550 °C).
    func setGain(high: Bool) throws {
        try sendCommand(high ? Command.gainHigh : Command.gainLow)
    }

    /// Triggers a manual shutter / NUC calibration.
    func triggerShutter() throws {
        try sendCommand(Command.shutter)
    }

    // MARK: - Frame reading

    /// Reads one complete validated frame (blocking; call from a background thread).
    /// Returns nil when a frame had to be dropped for resynchronisation.
    func readFrame(into frameBuffer: inout [UInt8]) throws -> Bool {
        guard let pipe = bulkPipe else { throw P3CameraError.pipeNotFound }
        let frameReadSize = model.frameReadSize
        if frameBuffer.count != frameReadSize {
            frameBuffer = [UInt8](repeating: 0, count: frameReadSize)
        }

        let chunkSize = Self.chunkSize
        let chunk = chunkBuffer
        var pos = 0

        while pos < frameReadSize {
            var n = 0
            chunk.length = chunkSize
            do {
                try pipe.__sendIORequest(with: chunk, bytesTransferred: &n, completionTimeout: 10.0)
            } catch {
                throw P3CameraError.streamingFailed(String(localized: "bulk read: \(error.localizedDescription)"))
            }
            guard n > 0 else { continue }

            // Resync: a lone 12-byte transfer is only valid as the trailing
            // end marker; any overshoot means the stream is misaligned.
            if (n == 12 && pos != frameReadSize - 12) || (pos + n > frameReadSize) {
                pos = 0
                continue
            }

            chunk.bytes.withMemoryRebound(to: UInt8.self, capacity: n) { src in
                frameBuffer.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.advanced(by: pos).update(from: src, count: n)
                }
            }
            pos += n
        }

        // Validate markers: length byte, sync bytes, and matching cnt1.
        let startSync = frameBuffer[1]
        let endBase = frameReadSize - 12
        let endSync = frameBuffer[endBase + 1]
        guard frameBuffer[0] == 0x0C, frameBuffer[endBase] == 0x0C,
              startSync == 0x8C || startSync == 0x8D,
              endSync == 0x8E || endSync == 0x8F else {
            return false
        }
        let cnt1Start = frameBuffer[2...5]
        let cnt1End = frameBuffer[(endBase + 2)...(endBase + 5)]
        guard cnt1Start.elementsEqual(cnt1End) else { return false }
        return true
    }
}

extension Data {
    /// Builds Data from a hex string (no separators). Traps on malformed input —
    /// only used for compile-time protocol constants.
    init(hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
