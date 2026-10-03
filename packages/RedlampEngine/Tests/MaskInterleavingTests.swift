import CoreGraphics
import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampMasking
import RedlampServices
import Synchronization
import Testing
@testable import RedlampEngine

/// An export of one photo runs between the canvas frames of another; neither may cost the other
/// its mask rasters.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MaskInterleavingTests {
    static let exported = EngineSmokeTests.fixtures.first { $0.lastPathComponent == "_DSC0009.ARW" }
    static let shown = EngineSmokeTests.fixtures.first { $0.lastPathComponent == "DSC_0750.NEF" }

    // MARK: - Mask resources

    @Test func `a photo's rasters stay on the GPU while another photo renders`() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let kernels = try KernelLibrary(device: device)
        let first = try Self.makeSession(device: device, queue: queue, kernels: kernels)
        let second = try Self.makeSession(device: device, queue: queue, kernels: kernels)
        let firstMasks = try (0 ..< 2).map { try Self.bitmapComponent(seed: $0) }
        let secondMasks = try (2 ..< 4).map { try Self.bitmapComponent(seed: $0) }
        let resources = try MaskResources(device: device, kernels: kernels)

        func draw(_ components: [MaskComponent], for session: ImageSession) throws {
            let commands = try #require(queue.makeCommandBuffer())
            resources.use(session, commands: commands)
            _ = try resources.slices(for: components, analysisGuide: nil, commands: commands)
            commands.commit()
            commands.waitUntilCompleted()
        }
        try draw(firstMasks, for: first)
        try draw(secondMasks, for: second)
        let commands = try #require(queue.makeCommandBuffer())
        resources.use(first, commands: commands)
        commands.commit()
        commands.waitUntilCompleted()
        for component in firstMasks {
            #expect(resources.keys.contains(MaskResources.key(for: component.shape)))
        }
    }

    /// Full-size photos of four masks each, more than the budget holds: each photo kept aside
    /// stays within its share, and all of them within the total.
    @Test(.enabled(if: EngineSmokeTests.canRender && EngineSmokeTests.fixtures.count >= 5))
    func `photos kept aside stay within their memory budget`() async throws {
        let engine = try RedlampEngine()
        let resources = try MaskResources(device: engine.device, kernels: engine.kernels)
        var sessions: [ImageSession] = []
        for (index, url) in EngineSmokeTests.fixtures.prefix(6).enumerated() {
            _ = try await engine.open(url)
            let session = try #require(engine.sessions.cached(url))
            sessions.append(session)
            let components = try (0 ..< 4).map { try Self.bitmapComponent(seed: index * 4 + $0) }
            let commands = try #require(engine.queue.makeCommandBuffer())
            resources.use(session, commands: commands)
            _ = try resources.slices(for: components, analysisGuide: nil, commands: commands)
            commands.commit()
            await commands.completed()
            let sizes = resources.parkedSizes
            #expect(sizes.allSatisfy { $0 <= MaskResources.parkedBytesPerPhoto }, "\(sizes)")
            #expect(sizes.reduce(0, +) <= MaskResources.parkedBytes, "\(sizes)")
            if index > 0 {
                #expect((sizes.last ?? 0) > 0, "the photo before was not kept")
            }
        }
        print("kept aside: \(resources.parkedSizes.map { $0 >> 20 }) MB for \(sessions.count - 1) photos")
    }

    // MARK: - Engine

    /// Frames of the shown photo while the other photo's export renders between them take about
    /// as long as they do alone, and the export comes out as it does alone.
    @Test(.enabled(if: EngineSmokeTests.canRender && Self.exported != nil && Self.shown != nil))
    func `a masked frame stays quick while another photo's masked export renders`() async throws {
        let exported = try #require(Self.exported)
        let shown = try #require(Self.shown)
        let engine = try RedlampEngine()
        let exportedInfo = try await engine.open(exported)
        let shownInfo = try await engine.open(shown)
        let exportRecipe = try Self.masked(Self.bitmaps(for: exportedInfo, seeds: [0, 1]))
        let shownBitmaps = try Self.bitmaps(for: shownInfo, seeds: [2, 3])

        let progress = Progress()
        let stream = engine.frames()
        let listener = Task.detached {
            for await frame in stream {
                progress.durations.withLock { $0[frame.generation] = frame.renderDuration }
            }
        }
        defer { listener.cancel() }
        var generation: UInt64 = 0
        func frame() async throws -> Duration {
            generation += 1
            let current = generation
            engine.render(RenderRequest(
                recipe: Self.masked(shownBitmaps, exposure: Double(current % 50) * 0.02),
                targetSize: PixelSize(width: 2560, height: 1600), generation: current,
            ))
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if let duration = progress.durations.withLock({ $0[current] }) {
                    return duration
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            throw CancellationError()
        }

        _ = engine.openIfReady(shown)
        for _ in 0 ..< 5 {
            _ = try await frame()
        }
        var alone: [Duration] = []
        for _ in 0 ..< 12 {
            try await alone.append(frame())
        }

        var request = StillRequest(recipe: exportRecipe, purpose: .export)
        request.source = exported
        _ = engine.openIfReady(exported)
        let exportedAlone = try await engine.renderStill(request)

        _ = engine.openIfReady(exported)
        let export = Task { try await engine.renderStill(request) }
        try await Task.sleep(for: .milliseconds(30))
        _ = engine.openIfReady(shown)
        let watcher = Task {
            _ = await export.result
            progress.exportFinished.store(true, ordering: .sequentiallyConsistent)
        }
        var during: [Duration] = []
        while !progress.exportFinished.load(ordering: .sequentiallyConsistent) {
            try await during.append(frame())
        }
        await watcher.value
        let exportedInterleaved = try await export.value

        func median(_ values: [Duration]) -> Duration {
            values.sorted()[values.count / 2]
        }
        print(
            "masked frames alone: median \(median(alone)); during the export: median \(median(during)) of \(during.count)",
        )
        #expect(during.count >= 3, "the export finished before the frames could interleave")
        #expect(median(during) <= median(alone) * 2 + .milliseconds(1), "\(during)")
        #expect(Self.pixels(exportedInterleaved) == Self.pixels(exportedAlone))
    }

    // MARK: - Helpers

    final class Progress: Sendable {
        let durations = Mutex<[UInt64: Duration]>([:])
        let exportFinished = Atomic<Bool>(false)
    }

    static func masked(_ bitmaps: [MaskBitmap], exposure: Double = 0) -> EditRecipe {
        var recipe = EditRecipe()
        recipe[.noiseLuminance] = 30
        recipe[.exposure] = exposure
        var mask = MaskLayer(name: "Subject", components: bitmaps.map { bitmap in
            MaskComponent(shape: .ai(AIMask(
                kind: .subject, provider: "test", revision: 1, analysisHash: "test",
                center: ImagePoint(x: 0.5, y: 0.5), bitmap: bitmap,
            )))
        })
        mask[.localExposure] = 0.5
        recipe.masks = [mask]
        return recipe
    }

    /// Soft ellipses at the size AI masks are stored at, each placed by its seed.
    static func bitmaps(for info: ImageInfo, seeds: [Int]) throws -> [MaskBitmap] {
        let size = info.pixelSize.fitted(
            within: PixelSize(width: MaskResources.rasterLongEdge, height: MaskResources.rasterLongEdge),
        )
        return try seeds.map { try ellipse(size: size, seed: $0) }
    }

    static func ellipse(size: PixelSize, seed: Int) throws -> MaskBitmap {
        let centerX = 0.3 + 0.1 * Double(seed % 4)
        let centerY = 0.4 + 0.1 * Double(seed % 3)
        var pixels = [UInt8](repeating: 0, count: size.width * size.height)
        for y in 0 ..< size.height {
            let dy = (Double(y) / Double(size.height) - centerY) / 0.35
            for x in 0 ..< size.width {
                let dx = (Double(x) / Double(size.width) - centerX) / 0.3
                let distance = (dx * dx + dy * dy).squareRoot()
                pixels[y * size.width + x] = UInt8(max(0, min(255, (1.2 - distance) * 255)))
            }
        }
        return try #require(GrayMask(width: size.width, height: size.height, pixels: pixels).bitmap())
    }

    static func bitmapComponent(seed: Int) throws -> MaskComponent {
        try MaskComponent(shape: .ai(AIMask(
            kind: .subject, provider: "test", revision: 1, analysisHash: "test", center: ImagePoint(x: 0.5, y: 0.5),
            bitmap: ellipse(size: PixelSize(width: 96, height: 64), seed: seed),
        )))
    }

    static func pixels(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }

    /// A flat grey linear raw.
    static func makeSession(
        device: any MTLDevice, queue: any MTLCommandQueue, kernels: KernelLibrary,
        width: Int = 300, height: Int = 200,
    ) throws -> ImageSession {
        let black: Float = 512
        let white: Float = 16383
        let level = UInt16((black + 0.18 * (white - black)).rounded())
        var decoded = DecodedImage(
            width: width, height: height, layout: .linearRGB,
            samples: [UInt16](repeating: level, count: width * height * 3),
            blackLevels: [black, black, black], whiteLevel: white,
            asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil,
            orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/synthetic-interleaving.dng"),
                pixelSize: PixelSize(width: width, height: height), isRaw: true, sensorDescription: "synthetic",
            ),
        )
        decoded.noiseProfile = DetailStageTests.noise
        return try SessionBuilder(device: device, queue: queue, kernels: kernels).build(decoded)
    }
}
