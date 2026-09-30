import CryptoKit
import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices

/// A merged focus stack, ready to develop.
struct MergedStack: Sendable {
    /// Cropped to where every frame has data; `.balancedCameraHalf` for raw frames,
    /// `.linearSRGBHalf` for bitmaps.
    let decoded: DecodedImage
    let report: FocusStackReport
    /// Which frame is sharpest where, over the uncropped reference frame.
    let depth: [Float]
    let depthWidth: Int
    let depthHeight: Int
    /// The crop within the uncropped reference frame, and that frame's size, in its pixels.
    let crop: PixelRect
    let frameWidth: Int
    let frameHeight: Int
    /// The reference frame, for thumbnails.
    let referenceURL: URL
}

struct PixelRect: Codable, Hashable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

/// Merges focus stacks and keeps the results in `root/<key>/`: the fused pixels (`fused.half`,
/// float16 RGBA), `stack.json` (calibration, report, crop) and `depth.f32`. The key hashes the
/// frames' paths, sizes and modification dates and the strategy, so changing any of them merges
/// again; the cache can be deleted at any time.
final class FocusStackCache: Sendable {
    static let formatVersion = 1

    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.redlamp/FocusStacks", isDirectory: true)
    }

    let root: URL
    private let device: any MTLDevice
    private let kernels: KernelLibrary

    init(device: any MTLDevice, kernels: KernelLibrary, root: URL = FocusStackCache.defaultRoot) {
        self.device = device
        self.kernels = kernels
        self.root = root
    }

    /// Any supported file: a stack document through the cache, anything else from disk.
    func decode(_ url: URL) throws -> DecodedImage {
        try SupportedFormats.isStack(url) ? stack(at: url).decoded : ImageDecoder.decode(url)
    }

    /// The stack document at `url`, from the cache or merged now.
    func stack(at url: URL, progress: (Double) -> Void = { _ in }) throws -> MergedStack {
        let document = try FocusStackDocument.read(url)
        let frames = document.frameURLs(at: url)
        let folder = try root.appendingPathComponent(Self.key(frames: frames, strategy: document.strategy))
        if let cached = try? load(folder, documentURL: url) {
            progress(1)
            return cached
        }
        let merged = try merge(frames, strategy: document.strategy, documentURL: url, progress: progress)
        try? save(merged, to: folder)
        return merged
    }

    /// The frame whose embedded preview stands in for the stack's thumbnail: the reference when
    /// the stack has been merged, else the middle frame.
    func thumbnailFrame(for url: URL) -> URL? {
        guard let document = try? FocusStackDocument.read(url) else { return nil }
        let frames = document.frameURLs(at: url)
        if let key = try? Self.key(frames: frames, strategy: document.strategy),
           let data = try? Data(contentsOf: root.appendingPathComponent(key).appendingPathComponent("stack.json")),
           let metadata = try? JSONDecoder().decode(StackMetadata.self, from: data),
           frames.indices.contains(metadata.report.reference) {
            return frames[metadata.report.reference]
        }
        return frames.isEmpty ? nil : frames[frames.count / 2]
    }

    static func key(frames: [URL], strategy: FocusStackStrategy) throws -> String {
        var description = "v\(formatVersion) \(strategy.rawValue)"
        for frame in frames {
            let values = try frame.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            description += "\n\(frame.standardizedFileURL.path) \(values.fileSize ?? 0) \(modified)"
        }
        return SHA256.hash(data: Data(description.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Merging

    /// Decodes, aligns and fuses `urls` (in focus order).
    func merge(
        _ urls: [URL], strategy: FocusStackStrategy, documentURL: URL?, progress: (Double) -> Void,
    ) throws -> MergedStack {
        guard urls.count >= 2 else { throw EngineError.renderFailed("a focus stack needs at least two frames") }
        guard let queue = device.makeCommandQueue() else { throw EngineError.gpuUnavailable }
        queue.label = "Focus stack"
        let builder = SessionBuilder(device: device, queue: queue, kernels: kernels)
        let stacker = FocusStacker(device: device, queue: queue, kernels: kernels)
        var metadata: [Int: DecodedImage] = [:]
        let result = try stacker.merge(
            frameCount: urls.count, settings: StackMergeSettings(strategy: strategy),
            load: { index in
                let frame = try builder.demosaic(ImageDecoder.decode(urls[index]))
                metadata[index] = frame.decoded.calibration(noise: frame.noise)
                return frame.texture
            },
            progress: progress,
        )
        let alignment = result.alignment
        guard let reference = metadata[alignment.reference] else { throw EngineError.gpuUnavailable }
        let (samples, crop) = try readCovered(result.fused, queue: queue)
        let report = FocusStackReport(
            frames: urls.count,
            reference: alignment.reference,
            width: crop.width,
            height: crop.height,
            maximumScaleChange: Double(alignment.transforms.map { abs($0.scale - 1) }.max() ?? 0),
            minimumCorrelation: Double(alignment.correlations.min() ?? 1),
            confidentDepthFraction: Double(result.depth.confidentFraction),
            timings: result.timings,
        )
        let decoded = reference.stacked(
            samples: samples, width: crop.width, height: crop.height, frames: urls.count, url: documentURL,
        )
        return MergedStack(
            decoded: decoded, report: report, depth: result.depth.depth, depthWidth: result.depth.width,
            depthHeight: result.depth.height, crop: crop, frameWidth: result.fused.width,
            frameHeight: result.fused.height, referenceURL: urls[alignment.reference],
        )
    }

    /// The fused texture's float16 RGBA samples inside the largest rectangle every frame covers,
    /// with alpha set to 1.
    private func readCovered(_ fused: any MTLTexture, queue: any MTLCommandQueue) throws -> ([UInt16], PixelRect) {
        let (width, height) = (fused.width, fused.height)
        let rowBytes = width * 8
        guard let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else {
            throw EngineError.gpuUnavailable
        }
        blit.copy(
            from: fused, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height,
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let halves = buffer.contents().assumingMemoryBound(to: UInt16.self)
        let crop = Self.coveredRect(width: width, height: height) { x, y in
            Float(Float16(bitPattern: halves[(y * width + x) * 4 + 3])) >= 0.999
        }
        let one = Float16(1).bitPattern
        var samples = [UInt16](repeating: one, count: crop.width * crop.height * 4)
        samples.withUnsafeMutableBufferPointer { out in
            for row in 0 ..< crop.height {
                let source = halves + ((crop.y + row) * width + crop.x) * 4
                let destination = out.baseAddress! + row * crop.width * 4
                for x in 0 ..< crop.width {
                    destination[x * 4] = source[x * 4]
                    destination[x * 4 + 1] = source[x * 4 + 1]
                    destination[x * 4 + 2] = source[x * 4 + 2]
                }
            }
        }
        return (samples, crop)
    }

    /// The largest rectangle, found by trimming edges, in which `covered` holds everywhere: the
    /// edge with the most uncovered pixels goes first, one row or column at a time.
    static func coveredRect(width: Int, height: Int, covered: (Int, Int) -> Bool) -> PixelRect {
        var (left, top, right, bottom) = (0, 0, width, height)
        func missing(row y: Int) -> Int {
            (left ..< right).count { !covered($0, y) }
        }
        func missing(column x: Int) -> Int {
            (top ..< bottom).count { !covered(x, $0) }
        }
        while right - left > 1, bottom - top > 1 {
            let edges = [missing(row: top), missing(row: bottom - 1), missing(column: left), missing(column: right - 1)]
            guard let worst = edges.indices.max(by: { edges[$0] < edges[$1] }), edges[worst] > 0 else { break }
            switch worst {
            case 0: top += 1
            case 1: bottom -= 1
            case 2: left += 1
            default: right -= 1
            }
        }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    // MARK: - Storage

    private func save(_ stack: MergedStack, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try stack.decoded.samples
            .withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent("fused.half")) }
        try stack.depth.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent("depth.f32")) }
        let metadata = StackMetadata(stack)
        try JSONEncoder().encode(metadata).write(to: folder.appendingPathComponent("stack.json"), options: .atomic)
    }

    private func load(_ folder: URL, documentURL: URL) throws -> MergedStack {
        let metadata = try JSONDecoder().decode(
            StackMetadata.self, from: Data(contentsOf: folder.appendingPathComponent("stack.json")),
        )
        let samples: [UInt16] = try Self.read(folder.appendingPathComponent("fused.half"))
        let depth: [Float] = try Self.read(folder.appendingPathComponent("depth.f32"))
        guard samples.count == metadata.width * metadata.height * 4,
              depth.count == metadata.depthWidth * metadata.depthHeight
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return MergedStack(
            decoded: metadata.decoded(samples: samples, url: documentURL), report: metadata.report, depth: depth,
            depthWidth: metadata.depthWidth, depthHeight: metadata.depthHeight, crop: metadata.crop,
            frameWidth: metadata.frameWidth, frameHeight: metadata.frameHeight,
            referenceURL: URL(fileURLWithPath: metadata.referencePath),
        )
    }

    private static func read<T>(_ url: URL) throws -> [T] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return [T](unsafeUninitializedCapacity: data.count / MemoryLayout<T>.stride) { buffer, count in
            count = data.copyBytes(to: buffer) / MemoryLayout<T>.stride
        }
    }
}

private extension DecodedImage {
    /// The calibration and metadata without the sensor data; `noise` becomes its profile.
    func calibration(noise: NoiseModel) -> DecodedImage {
        var copy = DecodedImage(
            width: width, height: height, layout: layout, samples: [], blackLevels: blackLevels,
            whiteLevel: whiteLevel, asShotMultipliers: asShotMultipliers, cameraToSRGB: cameraToSRGB,
            xyzToCamera: xyzToCamera, orientation: orientation, baselineExposure: baselineExposure, info: info,
        )
        copy.noiseProfile = noise
        return copy
    }

    /// A merge of frames like this one: float16 RGBA as the demosaic left it, with this frame's
    /// calibration.
    func stacked(samples: [UInt16], width: Int, height: Int, frames: Int, url: URL?) -> DecodedImage {
        let layout: Layout = switch self.layout {
        case let .mosaic(pattern): .balancedCameraHalf(pattern)
        case .linearRGB: .balancedCameraHalf(nil)
        case .linearSRGBHalf, .balancedCameraHalf: self.layout
        }
        var info = info
        info.url = url ?? info.url
        info.sensorDescription = "Focus stack of \(frames), \(info.sensorDescription)"
        info.pixelSize = orientation == 5 || orientation == 6
            ? PixelSize(width: height, height: width)
            : PixelSize(width: width, height: height)
        var decoded = DecodedImage(
            width: width, height: height, layout: layout, samples: samples, blackLevels: [0, 0, 0], whiteLevel: 1,
            asShotMultipliers: asShotMultipliers, cameraToSRGB: cameraToSRGB, xyzToCamera: xyzToCamera,
            orientation: orientation, baselineExposure: baselineExposure, info: info,
        )
        decoded.noiseProfile = noiseProfile
        return decoded
    }
}

/// Everything but the pixels, as stored in `stack.json`.
private struct StackMetadata: Codable {
    var width: Int
    var height: Int
    /// "bitmap", "linear" or a CFA description; `patternColors` holds a mosaic's pattern.
    var source: String
    var patternWidth: Int?
    var patternHeight: Int?
    var patternColors: [UInt8]?
    var asShotMultipliers: [Double]
    var cameraToSRGB: [Double]
    var xyzToCamera: [Double]?
    var orientation: Int
    var baselineExposure: Double
    var noiseA: [Float]?
    var noiseB: [Float]?
    var sensorDescription: String
    var make: String?
    var model: String?
    var lens: String?
    var iso: Double?
    var exposureTime: Double?
    var aperture: Double?
    var focalLength: Double?
    var captureDate: Date?
    var report: FocusStackReport
    var depthWidth: Int
    var depthHeight: Int
    var crop: PixelRect
    var frameWidth: Int
    var frameHeight: Int
    var referencePath: String

    init(_ stack: MergedStack) {
        let decoded = stack.decoded
        width = decoded.width
        height = decoded.height
        switch decoded.layout {
        case let .balancedCameraHalf(pattern?), let .mosaic(pattern):
            source = pattern.description
            patternWidth = pattern.width
            patternHeight = pattern.height
            patternColors = pattern.colors
        case .balancedCameraHalf(nil), .linearRGB:
            source = "linear"
        case .linearSRGBHalf:
            source = "bitmap"
        }
        let multipliers = decoded.asShotMultipliers
        asShotMultipliers = [multipliers.x, multipliers.y, multipliers.z]
        cameraToSRGB = decoded.cameraToSRGB
        xyzToCamera = decoded.xyzToCamera
        orientation = decoded.orientation
        baselineExposure = decoded.baselineExposure
        if let noise = decoded.noiseProfile {
            noiseA = [noise.a.x, noise.a.y, noise.a.z]
            noiseB = [noise.b.x, noise.b.y, noise.b.z]
        }
        let info = decoded.info
        sensorDescription = info.sensorDescription
        make = info.make
        model = info.model
        lens = info.lens
        iso = info.iso
        exposureTime = info.exposureTime
        aperture = info.aperture
        focalLength = info.focalLength
        captureDate = info.captureDate
        report = stack.report
        depthWidth = stack.depthWidth
        depthHeight = stack.depthHeight
        crop = stack.crop
        frameWidth = stack.frameWidth
        frameHeight = stack.frameHeight
        referencePath = stack.referenceURL.path
    }

    func decoded(samples: [UInt16], url: URL) -> DecodedImage {
        let layout: DecodedImage.Layout = switch source {
        case "bitmap": .linearSRGBHalf
        case "linear": .balancedCameraHalf(nil)
        default: .balancedCameraHalf(patternColors.map {
                CFAPattern(width: patternWidth ?? 2, height: patternHeight ?? 2, colors: $0)
            })
        }
        let pixelSize = orientation == 5 || orientation == 6
            ? PixelSize(width: height, height: width)
            : PixelSize(width: width, height: height)
        let info = ImageInfo(
            url: url, pixelSize: pixelSize, isRaw: source != "bitmap", sensorDescription: sensorDescription,
            make: make, model: model, lens: lens, iso: iso, exposureTime: exposureTime, aperture: aperture,
            focalLength: focalLength, captureDate: captureDate,
        )
        var decoded = DecodedImage(
            width: width, height: height, layout: layout, samples: samples, blackLevels: [0, 0, 0], whiteLevel: 1,
            asShotMultipliers: SIMD3(asShotMultipliers[0], asShotMultipliers[1], asShotMultipliers[2]),
            cameraToSRGB: cameraToSRGB, xyzToCamera: xyzToCamera, orientation: orientation,
            baselineExposure: baselineExposure, info: info,
        )
        if let noiseA, let noiseB {
            decoded.noiseProfile = NoiseModel(
                a: SIMD3(noiseA[0], noiseA[1], noiseA[2]), b: SIMD3(noiseB[0], noiseB[1], noiseB[2]),
            )
        }
        return decoded
    }
}
