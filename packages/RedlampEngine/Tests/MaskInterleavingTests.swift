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

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        kernels = try KernelLibrary(device: device)
    }

    // MARK: - Mask resources

    @Test func `a photo's rasters stay on the GPU while another photo renders`() throws {
        let first = try makeSession()
        let second = try makeSession()
        let firstMasks = try (0 ..< 2).map { try Self.bitmapComponent(seed: $0) }
        let resources = try MaskResources(device: device, kernels: kernels)
        try draw(firstMasks, for: first, in: resources)
        try draw((2 ..< 4).map { try Self.bitmapComponent(seed: $0) }, for: second, in: resources)
        try switchTo(first, in: resources)
        for component in firstMasks {
            #expect(resources.keys.contains(MaskResources.key(for: component.shape)))
        }
    }

    /// Subject, Sky and Background on a full-size photo come back without being drawn again.
    @Test func `a full-size photo of three masks keeps all three`() throws {
        let photo = try makeSession(width: 4096, height: 2731)
        let other = try makeSession()
        let masks = try (0 ..< 3).map { try Self.bitmapComponent(seed: $0) }
        let resources = try MaskResources(device: device, kernels: kernels)
        try draw(masks, for: photo, in: resources)
        try switchTo(other, in: resources)
        let drawn = resources.slicesDrawn
        try draw(masks, for: photo, in: resources)
        #expect(resources.slicesDrawn == drawn)
    }

    /// The photo's share fits five full-size slices: the two least recently used of seven go.
    @Test func `the least recently used slices go first when a photo is kept aside`() throws {
        let photo = try makeSession(width: 4096, height: 2731)
        let other = try makeSession()
        let masks = try (0 ..< 7).map { try Self.bitmapComponent(seed: $0) }
        let resources = try MaskResources(device: device, kernels: kernels)
        try draw(masks, for: photo, in: resources)
        try draw([masks[0]], for: photo, in: resources)
        try switchTo(other, in: resources)
        try switchTo(photo, in: resources)
        let kept = masks.map { resources.keys.contains(MaskResources.key(for: $0.shape)) }
        #expect(kept == [true, false, false, true, true, true, true])
    }

    /// The left photo's slices are copied into a smaller array on their own command buffer, so a
    /// render of the next photo that never runs can't leave them undrawn.
    @Test func `a photo left by a render that never runs keeps its rasters`() throws {
        let photo = try makeSession(width: 4096, height: 2100)
        let other = try makeSession()
        let masks = try (0 ..< 5).map { try Self.bitmapComponent(seed: $0) }
        let resources = try MaskResources(device: device, kernels: kernels)
        try draw(masks, for: photo, in: resources)
        #expect(resources.rasters?.arrayLength == 8)
        let expected = try masks.map { try readSlice(of: $0, in: resources) }
        let abandoned = try #require(queue.makeCommandBuffer())
        resources.use(other, commands: abandoned)
        #expect(resources.parkedRasterSlices == [5])
        try switchTo(photo, in: resources)
        for (mask, pixels) in zip(masks, expected) {
            #expect(try readSlice(of: mask, in: resources) == pixels)
        }
    }

    /// Unused slices are trimmed before guides are dropped.
    @Test func `a guide is kept with its photo`() throws {
        let photo = try makeSession(width: 4096, height: 2100)
        let other = try makeSession()
        let masks = try (0 ..< 5).map { try Self.bitmapComponent(seed: $0) }
        let resources = try MaskResources(device: device, kernels: kernels)
        try draw(masks, for: photo, in: resources)
        let guide = try editGuide(EditRecipe(), for: photo, in: resources)
        try switchTo(other, in: resources)
        try switchTo(photo, in: resources)
        var rendered = false
        let commands = try #require(queue.makeCommandBuffer())
        let kept = try resources.editGuide(for: EditRecipe(), from: photo, commands: commands) { _, _ in
            rendered = true
        }
        commands.commit()
        commands.waitUntilCompleted()
        #expect(!rendered && kept === guide.texture)
        #expect(resources.editGuideGeneration == guide.generation)
        #expect(masks.allSatisfy { resources.keys.contains(MaskResources.key(for: $0.shape)) })
    }

    @Test func `a guide is rendered again once the photo it's developed from has maps of its own`() throws {
        let photo = try makeSession()
        let resources = try MaskResources(device: device, kernels: kernels)
        let refreshed = ImageSession(retouching: photo, pyramid: photo.pyramid, maps: photo.maps)
        var renders = 0
        for source in [photo, photo, refreshed, refreshed] {
            let commands = try #require(queue.makeCommandBuffer())
            resources.use(photo, commands: commands)
            _ = try resources.editGuide(for: EditRecipe(), from: source, commands: commands) { _, _ in renders += 1 }
            commands.commit()
            commands.waitUntilCompleted()
        }
        #expect(renders == 2)
    }

    @Test func `a guide's version number is never reused`() throws {
        let first = try makeSession()
        let second = try makeSession()
        let resources = try MaskResources(device: device, kernels: kernels)
        var brighter = EditRecipe()
        brighter[.exposure] = 1
        var seen: [Int] = []
        try seen.append(editGuide(EditRecipe(), for: first, in: resources).generation)
        try seen.append(editGuide(EditRecipe(), for: second, in: resources).generation)
        try seen.append(editGuide(brighter, for: first, in: resources).generation)
        for texture in resources.parkedTextures {
            texture.setPurgeableState(.empty)
        }
        try seen.append(editGuide(EditRecipe(), for: second, in: resources).generation)
        try seen.append(editGuide(EditRecipe(), for: first, in: resources).generation)
        #expect(Set(seen).count == seen.count, "\(seen)")
    }

    /// What is kept aside may be purged under memory pressure; a purged photo draws its masks
    /// again.
    @Test func `kept textures are purgeable, and a purged photo draws its masks again`() throws {
        let photo = try makeSession()
        let other = try makeSession()
        let masks = try (0 ..< 3).map { try Self.bitmapComponent(seed: $0) }
        let resources = try MaskResources(device: device, kernels: kernels)
        try draw(masks, for: photo, in: resources)
        _ = try editGuide(EditRecipe(), for: photo, in: resources)
        try switchTo(other, in: resources)
        let kept = resources.parkedTextures
        #expect(kept.count == 2)
        #expect(kept.allSatisfy { $0.setPurgeableState(.keepCurrent) == .volatile })
        for texture in kept {
            texture.setPurgeableState(.empty)
        }
        try switchTo(photo, in: resources)
        #expect(resources.keys.allSatisfy { $0 == nil })
        let drawn = resources.slicesDrawn
        try draw(masks, for: photo, in: resources)
        #expect(resources.slicesDrawn == drawn + 3)
        #expect(resources.rasters?.setPurgeableState(.keepCurrent) == .nonVolatile)
    }

    @Test func `the brush being painted is kept with its photo`() throws {
        let photo = try makeSession()
        let other = try makeSession()
        let brush = BrushMask(strokes: [
            BrushStroke(points: [ImagePoint(x: 0.1, y: 0.2), ImagePoint(x: 0.6, y: 0.5)], size: 0.08),
            BrushStroke(points: [ImagePoint(x: 0.3, y: 0.1), ImagePoint(x: 0.35, y: 0.9)], size: 0.05),
        ])
        let resources = try MaskResources(device: device, kernels: kernels)
        try draw([MaskComponent(shape: .brush(brush))], for: photo, in: resources)
        try switchTo(other, in: resources)
        #expect(resources.paintBase == nil)
        try switchTo(photo, in: resources)
        #expect(resources.paintBase?.key == BrushMask(strokes: [brush.strokes[0]]))
    }

    /// A photo dropped from the session cache takes what was kept for it along at the next
    /// switch.
    @Test func `a photo whose session is gone is no longer kept`() throws {
        let resources = try MaskResources(device: device, kernels: kernels)
        let other = try makeSession()
        do {
            let photo = try makeSession()
            try draw([Self.bitmapComponent(seed: 0)], for: photo, in: resources)
            try switchTo(other, in: resources)
            #expect(resources.parkedSizes.count == 1)
        }
        try switchTo(other, in: resources)
        #expect(resources.parkedSizes.isEmpty)
    }

    /// Full-size photos of three masks each, more than the budget holds: each photo kept aside
    /// stays within its share, all of them within the total, and the oldest go first.
    @Test(.enabled(if: EngineSmokeTests.canRender && EngineSmokeTests.fixtures.count >= 5))
    func `photos kept aside stay within their memory budget, oldest dropped first`() async throws {
        let engine = try RedlampEngine()
        let resources = try MaskResources(device: engine.device, kernels: engine.kernels)
        var sessions: [ImageSession] = []
        for (index, url) in EngineSmokeTests.fixtures.prefix(6).enumerated() {
            _ = try await engine.open(url)
            let session = try #require(engine.sessions.cached(url))
            sessions.append(session)
            let components = try (0 ..< 3).map { try Self.bitmapComponent(seed: index * 3 + $0) }
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
        let kept = resources.parkedSizes.count
        print("kept aside: \(resources.parkedSizes.map { $0 >> 20 }) MB for \(sessions.count - 1) photos")
        #expect(kept >= 1 && kept < sessions.count - 1, "the budget never ran out")
        // The photos kept are the ones just before the current one. Under memory pressure, as on
        // CI's runner, the system may have purged one meanwhile; it was kept all the same.
        for (offset, session) in sessions.dropLast().reversed().enumerated() {
            let purged = resources.rastersPurged
            let commands = try #require(engine.queue.makeCommandBuffer())
            resources.use(session, commands: commands)
            commands.commit()
            await commands.completed()
            let wasPurged = resources.rastersPurged > purged
            if wasPurged {
                print("\(offset + 1) photos back: its rasters were purged")
            }
            let wasKept = wasPurged || resources.keys.contains { $0 != nil }
            #expect(wasKept == (offset < kept), "\(offset + 1) photos back, \(kept) kept")
            if !wasKept {
                break
            }
        }
    }

    // MARK: - Engine

    /// Frames of the shown photo, rendered between the tiles of the other photo's export, draw
    /// no masks, and the export comes out as it does alone.
    @Test(.enabled(if: EngineSmokeTests.canRender && Self.exported != nil && Self.shown != nil))
    func `another photo's export doesn't make the shown photo draw its masks again`() async throws {
        let exported = try #require(Self.exported)
        let shown = try #require(Self.shown)
        let engine = try RedlampEngine()
        let exportedInfo = try await engine.open(exported)
        let shownInfo = try await engine.open(shown)
        let exportRecipe = try Self.masked(Self.bitmaps(for: exportedInfo, seeds: [0, 1, 2]))
        let shownBitmaps = try Self.bitmaps(for: shownInfo, seeds: [3, 4, 5])

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
        func slicesDrawn() -> Int {
            engine.renderQueue.sync { engine.masks.slicesDrawn }
        }

        _ = engine.openIfReady(shown)
        var alone: [Duration] = []
        for _ in 0 ..< 8 {
            try await alone.append(frame())
        }

        var request = StillRequest(recipe: exportRecipe, purpose: .export)
        request.source = exported
        _ = engine.openIfReady(exported)
        let exportedAlone = try await engine.renderStill(request)

        let drawnBefore = slicesDrawn()
        _ = engine.openIfReady(exported)
        let export = Task { try await engine.renderStill(request) }
        // `slicesDrawn()` synced on the render queue, so the export above has let go of the
        // lane: from here on `isDraining` means this export started.
        while !engine.stillLanes.withLock({ $0.isDraining }) {
            try await Task.sleep(for: .milliseconds(1))
        }
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
        #expect(!during.isEmpty, "the export finished before a frame could interleave")
        #expect(slicesDrawn() == drawnBefore)
        #expect(Self.pixels(exportedInterleaved) == Self.pixels(exportedAlone))
    }

    // MARK: - Helpers

    final class Progress: Sendable {
        let durations = Mutex<[UInt64: Duration]>([:])
        let exportFinished = Atomic<Bool>(false)
    }

    private func draw(_ components: [MaskComponent], for session: ImageSession, in resources: MaskResources) throws {
        let commands = try #require(queue.makeCommandBuffer())
        resources.use(session, commands: commands)
        _ = try resources.slices(for: components, analysisGuide: nil, commands: commands)
        commands.commit()
        commands.waitUntilCompleted()
    }

    private func switchTo(_ session: ImageSession, in resources: MaskResources) throws {
        let commands = try #require(queue.makeCommandBuffer())
        resources.use(session, commands: commands)
        commands.commit()
        commands.waitUntilCompleted()
    }

    /// The photo's edit guide for `recipe`, left as allocated (nothing renders into it).
    private func editGuide(
        _ recipe: EditRecipe, for session: ImageSession, in resources: MaskResources,
    ) throws -> (texture: any MTLTexture, generation: Int) {
        let commands = try #require(queue.makeCommandBuffer())
        resources.use(session, commands: commands)
        let texture = try resources.editGuide(for: recipe, from: session, commands: commands) { _, _ in }
        commands.commit()
        commands.waitUntilCompleted()
        return (texture, resources.editGuideGeneration)
    }

    private func readSlice(of component: MaskComponent, in resources: MaskResources) throws -> [UInt16] {
        let rasters = try #require(resources.rasters)
        let slice = try #require(resources.keys.firstIndex(of: MaskResources.key(for: component.shape)))
        let rowBytes = rasters.width * 2
        let buffer = try #require(device.makeBuffer(length: rowBytes * rasters.height, options: .storageModeShared))
        let commands = try #require(queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(
            from: rasters, sourceSlice: slice, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: rasters.width, height: rasters.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * rasters.height,
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let values = buffer.contents().assumingMemoryBound(to: UInt16.self)
        return Array(UnsafeBufferPointer(start: values, count: rasters.width * rasters.height))
    }

    /// A flat grey linear raw.
    private func makeSession(width: Int = 300, height: Int = 200) throws -> ImageSession {
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
        let centerX = 0.2 + 0.1 * Double(seed % 7)
        let centerY = 0.3 + 0.1 * Double(seed % 5)
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
}
