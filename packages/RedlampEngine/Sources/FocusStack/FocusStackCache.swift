import CryptoKit
import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import Synchronization

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
    /// Where each frame sits in the reference, for retouching from a frame.
    let alignment: StackAlignment

    /// The same stack with other pixels, or other info.
    func with(samples: [UInt16], info: ImageInfo? = nil) -> MergedStack {
        var image = DecodedImage(
            width: decoded.width, height: decoded.height, layout: decoded.layout, samples: samples,
            blackLevels: decoded.blackLevels, whiteLevel: decoded.whiteLevel,
            asShotMultipliers: decoded.asShotMultipliers,
            cameraToSRGB: decoded.cameraToSRGB, xyzToCamera: decoded.xyzToCamera, orientation: decoded.orientation,
            baselineExposure: decoded.baselineExposure, info: info ?? decoded.info,
        )
        image.noiseProfile = decoded.noiseProfile
        return MergedStack(
            decoded: image, report: report, depth: depth, depthWidth: depthWidth, depthHeight: depthHeight,
            crop: crop, frameWidth: frameWidth, frameHeight: frameHeight, referenceURL: referenceURL,
            alignment: alignment,
        )
    }
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
/// again; the cache can be deleted at any time. A merge is about 12 bytes a pixel (540 MB for
/// 45 megapixels), so the cache keeps to `budget`, least recently used first.
final class FocusStackCache: Sendable {
    static let formatVersion = 2
    static let defaultBudget = 4 << 30
    /// Older than this, a hidden staging folder belongs to a save that never finished.
    static let leftoverAge: TimeInterval = 60 * 60
    /// Frames decoding ahead of the one being merged (each holds its raw data, about 2 bytes a pixel).
    static let decodesAhead = 3

    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.redlamp/FocusStacks", isDirectory: true)
    }

    let root: URL
    let budget: Int
    let device: any MTLDevice
    let kernels: KernelLibrary
    /// The engine's decoder, so frames decode where its photos do (the Mac app's decode service).
    let decoder: any ImageDecoding
    /// When frames, by `identity(of:)`, last failed to decode. Each decode of a damaged file can
    /// cost a service launch, so they're tried again only after `unreadableRetry`, or once the
    /// editor opens their stack.
    let unreadable = Mutex<[String: Date]>([:])
    static let unreadableRetry: TimeInterval = 60

    init(
        device: any MTLDevice, kernels: KernelLibrary, root: URL = FocusStackCache.defaultRoot,
        budget: Int = FocusStackCache.defaultBudget,
        decoder: any ImageDecoding,
    ) {
        self.device = device
        self.kernels = kernels
        self.root = root
        self.budget = budget
        self.decoder = decoder
    }

    /// Any supported file: a stack document through the cache, anything else from disk.
    func decode(_ url: URL) throws -> DecodedImage {
        try SupportedFormats.isStack(url) ? stack(at: url).decoded : decoder.decode(url)
    }

    /// The stack document at `url`, from the cache or merged now.
    func stack(at url: URL, progress: (Double) -> Void = { _ in }) throws -> MergedStack {
        let document = try FocusStackDocument.read(url)
        let frames = document.frameURLs(at: url)
        let strokes = document.retouch ?? []
        let folder = try root.appendingPathComponent(Self.key(
            frames: frames,
            strategy: document.strategy,
            retouch: strokes,
        ))
        if let cached = cached(folder, frames: frames, documentURL: url) {
            progress(1)
            return cached
        }
        let merged = try merged(frames, strategy: document.strategy, documentURL: url, progress: progress)
        guard !strokes.isEmpty else { return merged }
        let retouched = try retouch(merged, with: strokes, document: document, at: url)
        try? save(retouched, to: folder, document: url)
        return retouched
    }

    /// `frames` merged by `strategy` without retouching, from the cache or merged and cached now.
    func merged(
        _ frames: [URL], strategy: FocusStackStrategy, documentURL: URL, progress: (Double) -> Void = { _ in },
    ) throws -> MergedStack {
        let folder = try root.appendingPathComponent(Self.key(frames: frames, strategy: strategy))
        if let cached = cached(folder, frames: frames, documentURL: documentURL) {
            progress(1)
            return cached
        }
        let merged = try merge(frames, strategy: strategy, documentURL: documentURL, progress: progress)
        try? save(merged, to: folder)
        return merged
    }

    /// The frame whose embedded preview stands in for the stack's thumbnail: the reference when
    /// the stack has been merged, else the middle frame.
    func thumbnailFrame(for url: URL) -> URL? {
        guard let document = try? FocusStackDocument.read(url) else { return nil }
        let frames = document.frameURLs(at: url)
        if let key = try? Self.key(frames: frames, strategy: document.strategy) {
            let folder = root.appendingPathComponent(key)
            for candidate in [folder, Self.incomplete(folder)] {
                if let data = try? Data(contentsOf: candidate.appendingPathComponent("stack.json")),
                   let metadata = try? JSONDecoder().decode(StackMetadata.self, from: data),
                   frames.indices.contains(metadata.report.reference) {
                    return frames[metadata.report.reference]
                }
            }
        }
        return frames.isEmpty ? nil : frames[frames.count / 2]
    }

    /// The merge cached in `folder`, else the one missing frames beside it while they still don't
    /// decode.
    func cached(_ folder: URL, frames: [URL], documentURL: URL) -> MergedStack? {
        if let complete = try? load(folder, documentURL: documentURL), stillMissing(complete, frames: frames) {
            return complete
        }
        guard let incomplete = try? load(Self.incomplete(folder), documentURL: documentURL),
              stillMissing(incomplete, frames: frames)
        else { return nil }
        return incomplete
    }

    /// Where a merge missing frames is kept instead of `folder`: a folder earlier versions of the
    /// cache never look up, since they'd take what's in it for a complete merge.
    static func incomplete(_ folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + "-incomplete")
    }

    static func key(frames: [URL], strategy: FocusStackStrategy, retouch: [FocusStackStroke] = []) throws -> String {
        var description = "v\(formatVersion) \(strategy.rawValue)"
        if !retouch.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try description += " " + (String(bytes: encoder.encode(retouch), encoding: .utf8) ?? "")
        }
        for frame in frames {
            try description += "\n" + identity(of: frame)
        }
        return SHA256.hash(data: Data(description.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// A frame's path, size and modification date, which change when it does.
    static func identity(of frame: URL) throws -> String {
        let values = try frame.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(frame.standardizedFileURL.path) \(values.fileSize ?? 0) \(modified)"
    }

    // MARK: - Merging

    /// Decodes, aligns and fuses `urls` (in focus order). A frame that doesn't decode is left out
    /// and reported, as long as two others do. A decoder that isn't available fails the merge at
    /// once, since no frame would decode.
    func merge(
        _ urls: [URL], strategy: FocusStackStrategy, documentURL: URL?, progress: (Double) -> Void,
    ) throws -> MergedStack {
        var included = Array(urls.indices)
        var failed: [FocusStackReport.FailedFrame] = []
        while true {
            do {
                let merged = try mergeFrames(
                    included.map { urls[$0] }, strategy: strategy, documentURL: documentURL, progress: progress,
                )
                return failed.isEmpty ? merged : merged.spread(over: included, of: urls.count, failed: failed)
            } catch let failure as FrameDecodeFailure {
                noteUnreadable(failure.all.map { urls[included[$0.index]] })
                for (index, error) in failure.all.sorted(by: { $0.index > $1.index }) {
                    failed.append(FocusStackReport.FailedFrame(
                        index: included[index], reason: error.localizedDescription,
                    ))
                    included.remove(at: index)
                }
                guard included.count >= 2 else { throw failure.error }
            }
        }
    }

    private func mergeFrames(
        _ urls: [URL], strategy: FocusStackStrategy, documentURL: URL?, progress: (Double) -> Void,
    ) throws -> MergedStack {
        guard urls.count >= 2 else { throw EngineError.renderFailed("a focus stack needs at least two frames") }
        guard let queue = device.makeCommandQueue() else { throw EngineError.gpuUnavailable }
        queue.label = "Focus stack"
        let builder = SessionBuilder(device: device, queue: queue, kernels: kernels)
        let stacker = FocusStacker(device: device, queue: queue, kernels: kernels)
        var metadata: [Int: DecodedImage] = [:]
        // The merge reads every frame twice, in order; the next few decode on other cores
        // (with their noise estimates) while the GPU works on the current one.
        let order = Array(urls.indices) + Array(urls.indices)
        let decodes = DispatchQueue(label: "app.redlamp.stack.decode", qos: .userInitiated, attributes: .concurrent)
        var pending: [Int: Prefetch<DecodedImage>] = [:]
        var position = 0
        let result = try stacker.merge(
            frameCount: urls.count, settings: StackMergeSettings(strategy: strategy),
            load: { index in
                precondition(order[position] == index, "frames must load in stack order, twice")
                for ahead in position ..< min(position + Self.decodesAhead + 1, order.count)
                    where pending[ahead] == nil {
                    let (frame, url, decoder) = (order[ahead], urls[order[ahead]], decoder)
                    pending[ahead] = Prefetch(on: decodes) {
                        var decoded: DecodedImage
                        do {
                            decoded = try decoder.decode(url)
                        } catch {
                            throw FrameDecodeFailure.wrapping(error, frame: frame)
                        }
                        decoded.noiseProfile = decoded.noise
                        return decoded
                    }
                }
                let decoded: DecodedImage
                do {
                    decoded = try pending.removeValue(forKey: position)!.value()
                } catch var failure as FrameDecodeFailure where position < urls.count {
                    failure.others = try Self.undecodable(
                        after: position, of: urls, pending: pending, decoder: decoder, on: decodes,
                    )
                    throw failure
                }
                position += 1
                let frame = try builder.demosaic(decoded)
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
            frameHeight: result.fused.height, referenceURL: urls[alignment.reference], alignment: alignment,
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

    /// Writes `stack` to a hidden folder and renames it into place as `key`, or `incomplete(key)`
    /// when it's missing frames, so an interrupted save leaves no half-written merge; then trims
    /// the cache. A complete save removes the incomplete one.
    /// `document` marks a retouched merge, whose earlier retouches are then of no use; one missing
    /// frames has a marker of its own, so it replaces only earlier ones missing frames, never a
    /// complete one.
    func save(_ stack: MergedStack, to key: URL, document: URL? = nil) throws {
        let incomplete = stack.report.failedFrames != nil
        let folder = incomplete ? Self.incomplete(key) : key
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(
            ".\(folder.lastPathComponent)-\(UUID().uuidString)",
            isDirectory: true,
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try stack.decoded.samples
                .withUnsafeBytes { try Data($0).write(to: staging.appendingPathComponent("fused.half")) }
            try stack.depth.withUnsafeBytes { try Data($0).write(to: staging.appendingPathComponent("depth.f32")) }
            try JSONEncoder().encode(StackMetadata(stack)).write(to: staging.appendingPathComponent("stack.json"))
            if let document {
                try Data(document.standardizedFileURL.path.utf8)
                    .write(to: staging.appendingPathComponent(Self.marker(incomplete: incomplete)))
            }
            try? fileManager.removeItem(at: folder)
            try fileManager.moveItem(at: staging, to: folder)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        if !incomplete {
            try? fileManager.removeItem(at: Self.incomplete(key))
        }
        Self.trim(root, budget: budget, keeping: folder, document: document, incomplete: incomplete)
    }

    /// The file naming the document a retouched merge belongs to.
    static func marker(incomplete: Bool) -> String {
        incomplete ? "document-incomplete" : "document"
    }

    /// Removes merges until `root` fits `budget`, least recently used first, never `kept`; also
    /// staging an interrupted save left and `document`'s other retouched merges (when `kept` is
    /// `incomplete`, only those missing frames).
    static func trim(
        _ root: URL, budget: Int, keeping kept: URL, document: URL? = nil, incomplete: Bool = false,
        now: Date = Date(),
    ) {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
        ) else { return }
        let path = document?.standardizedFileURL.path
        let replaced = incomplete ? [marker(incomplete: true)] : [marker(incomplete: true), marker(incomplete: false)]
        func retouches(_ item: URL) -> Bool {
            replaced.contains { name in
                (try? Data(contentsOf: item.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
                    == path
            }
        }
        var entries: [(url: URL, size: Int, date: Date)] = []
        for item in items where item.lastPathComponent != kept.lastPathComponent {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            if item.lastPathComponent.hasPrefix(".") {
                if now.timeIntervalSince(date) > leftoverAge {
                    try? fileManager.removeItem(at: item)
                }
            } else if path != nil, retouches(item) {
                try? fileManager.removeItem(at: item)
            } else {
                entries.append((item, size(of: item), date))
            }
        }
        var total = entries.reduce(size(of: kept)) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > budget {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private static func size(of folder: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey],
        )) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    func load(_ folder: URL, documentURL: URL) throws -> MergedStack {
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
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
        return MergedStack(
            decoded: metadata.decoded(samples: samples, url: documentURL), report: metadata.report, depth: depth,
            depthWidth: metadata.depthWidth, depthHeight: metadata.depthHeight, crop: metadata.crop,
            frameWidth: metadata.frameWidth, frameHeight: metadata.frameHeight,
            referenceURL: URL(fileURLWithPath: metadata.referencePath), alignment: metadata.alignment,
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
