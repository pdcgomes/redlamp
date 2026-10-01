import Foundation
import RedlampEngineAPI
import Synchronization

/// Decodes images, in this process or (on the Mac) in Redlamp's sandboxed decode service.
public protocol ImageDecoding: Sendable {
    func decode(_ url: URL) throws -> DecodedImage
}

/// Decodes in this process: the CLI, tests, and platforms without the decode service.
public struct InProcessDecoder: ImageDecoding {
    public init() {}

    public func decode(_ url: URL) throws -> DecodedImage {
        try ImageDecoder.decode(url)
    }
}

/// The decode service's XPC interface: a file's bytes in, `DecodedImage.archived()` out, or an
/// archived `EngineError`.
@objc public protocol DecodeServiceProtocol {
    func decode(_ file: Data, path: String, reply: @escaping @Sendable (Data?, Data?) -> Void)
}

/// The service side: decodes from the bytes it is sent (it has no file system access).
public final class DecodeService: NSObject, DecodeServiceProtocol {
    override public init() {}

    public func decode(_ file: Data, path: String, reply: @escaping @Sendable (Data?, Data?) -> Void) {
        do {
            try reply(ImageDecoder.decode(file, url: URL(fileURLWithPath: path)).archived(), nil)
        } catch {
            let failure = error as? EngineError ?? .decodeFailed(error.localizedDescription)
            reply(nil, try? JSONEncoder().encode(failure))
        }
    }
}

public extension DecodedImage {
    /// Everything but the samples, which follow the header as raw bytes.
    private struct Header: Codable {
        var width: Int
        var height: Int
        var layout: Layout
        var sampleCount: Int
        var blackLevels: [Float]
        var whiteLevel: Float
        var asShotMultipliers: SIMD3<Double>
        var cameraToSRGB: [Double]
        var xyzToCamera: [Double]?
        var orientation: Int
        var baselineExposure: Double
        var info: ImageInfo
        var noiseProfile: NoiseModel?
        var gainMaps: [GainMap]
        var dngColor: DNGColorCalibration?
        var banding: BandingCorrection?
    }

    /// A compact binary form for crossing process boundaries: a header length (8 bytes,
    /// little-endian), the header as JSON, then the samples.
    func archived() throws -> Data {
        let header = try JSONEncoder().encode(Header(
            width: width, height: height, layout: layout, sampleCount: samples.count, blackLevels: blackLevels,
            whiteLevel: whiteLevel, asShotMultipliers: asShotMultipliers, cameraToSRGB: cameraToSRGB,
            xyzToCamera: xyzToCamera, orientation: orientation, baselineExposure: baselineExposure, info: info,
            noiseProfile: noiseProfile, gainMaps: gainMaps, dngColor: dngColor, banding: banding,
        ))
        var data = Data(capacity: 8 + header.count + samples.count * 2)
        withUnsafeBytes(of: UInt64(header.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(header)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// `url` replaces the archived photo's URL: the caller's own, rather than how the decode
    /// service saw it.
    init(archive data: Data, url: URL? = nil) throws {
        guard data.count >= 8 else { throw EngineError.decodeFailed("the decode service sent no image") }
        let stored = data.prefix(8).withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard stored <= UInt64(data.count - 8) else {
            throw EngineError.decodeFailed("the decode service sent a damaged image")
        }
        let length = Int(stored)
        var header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 8 ..< 8 + length))
        if let url {
            header.info.url = url
        }
        let body = data.subdata(in: 8 + length ..< data.count)
        guard body.count == header.sampleCount * MemoryLayout<UInt16>.size else {
            throw EngineError.decodeFailed("the decode service sent a damaged image")
        }
        let samples = [UInt16](unsafeUninitializedCapacity: header.sampleCount) { buffer, count in
            body.withUnsafeBytes { bytes in
                _ = bytes.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
            }
            count = header.sampleCount
        }
        self.init(
            width: header.width, height: header.height, layout: header.layout, samples: samples,
            blackLevels: header.blackLevels, whiteLevel: header.whiteLevel,
            asShotMultipliers: header.asShotMultipliers, cameraToSRGB: header.cameraToSRGB,
            xyzToCamera: header.xyzToCamera, orientation: header.orientation,
            baselineExposure: header.baselineExposure, info: header.info,
        )
        noiseProfile = header.noiseProfile
        gainMaps = header.gainMaps
        dngColor = header.dngColor
        banding = header.banding
    }
}

#if os(macOS)
    /// Decodes in `RedlampDecoder.xpc`, the app's sandboxed decode service, so a damaged or
    /// hostile file can only crash the service, never the editor. Each decode gets its own
    /// connection, so neighbouring photos decode in parallel as they do in-process. Without the
    /// service (a build that doesn't bundle it), decoding falls back to this process.
    public final class DecodeServiceClient: ImageDecoding {
        public static let serviceName = "app.redlamp.mac.decoder"

        public init() {}

        public func decode(_ url: URL) throws -> DecodedImage {
            let file = try Data(contentsOf: url, options: .alwaysMapped)
            let connection = NSXPCConnection(serviceName: Self.serviceName)
            connection.remoteObjectInterface = NSXPCInterface(with: DecodeServiceProtocol.self)
            connection.resume()
            defer { connection.invalidate() }

            let result = Mutex<Result<DecodedImage, any Error>?>(nil)
            let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { error in
                result.withLock { $0 = .failure(error) }
            } as? DecodeServiceProtocol
            proxy?.decode(file, path: url.absoluteURL.path) { archive, failure in
                let outcome: Result<DecodedImage, any Error> = if let archive {
                    Result { try DecodedImage(archive: archive, url: url) }
                } else {
                    .failure(failure.flatMap { try? JSONDecoder().decode(EngineError.self, from: $0) }
                        ?? EngineError.decodeFailed("the decode service gave no reason"))
                }
                result.withLock { $0 = outcome }
            }
            switch result.withLock({ $0 }) {
            case let .success(image):
                return image
            case let .failure(error as NSError) where error.domain == NSCocoaErrorDomain
                && error.code == NSXPCConnectionInvalid:
                return try InProcessDecoder().decode(url)
            case let .failure(error as NSError) where error.domain == NSCocoaErrorDomain
                && error.code == NSXPCConnectionInterrupted:
                throw EngineError
                    .decodeFailed("the decoder stopped while reading \(url.lastPathComponent); the file may be damaged")
            case let .failure(error):
                throw error
            case nil:
                return try InProcessDecoder().decode(url)
            }
        }
    }
#endif
