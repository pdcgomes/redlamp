import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import Testing
@testable import RedlampEngine

/// A render that fails on the GPU, or is dropped before it's committed, leaves no mask cache
/// pointing at what it never drew: the next render draws its masks again.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MaskFailureTests {
    struct Failure: Error {}

    let engine: RedlampEngine

    init() throws {
        engine = try RedlampEngine()
    }

    static let failures: [CommandBufferFailure] = [.abandoned, .failed]

    @Test(arguments: failures)
    func `a slice drawn by a failed render is drawn again`(failure: CommandBufferFailure) throws {
        let session = try makeSession()
        let component = try MaskInterleavingTests.bitmapComponent(seed: 0)
        try fail(failure) { commands in
            engine.masks.use(session, commands: commands)
            _ = try engine.masks.slices(for: [component], analysisGuide: nil, commands: commands)
        }
        withKnownIssue("CONC-05: the slice keeps its key") {
            #expect(!engine.masks.keys.contains(MaskResources.key(for: component.shape)))
        }
        let drawn = engine.masks.slicesDrawn
        try complete { commands in
            engine.masks.use(session, commands: commands)
            _ = try engine.masks.slices(for: [component], analysisGuide: nil, commands: commands)
        }
        withKnownIssue("CONC-05: the slice keeps its key") {
            #expect(engine.masks.slicesDrawn == drawn + 1)
        }
    }

    /// The larger array a dropped render made never received the slices it was to copy.
    @Test func `the rasters a dropped render grew keep their slices`() throws {
        let session = try makeSession()
        let first = try (0 ..< 4).map { try MaskInterleavingTests.bitmapComponent(seed: $0) }
        let fifth = try MaskInterleavingTests.bitmapComponent(seed: 4)
        try complete { commands in
            engine.masks.use(session, commands: commands)
            _ = try engine.masks.slices(for: first, analysisGuide: nil, commands: commands)
        }
        let before = try first.map(readSlice)
        try fail(.abandoned) { commands in
            engine.masks.use(session, commands: commands)
            _ = try engine.masks.slices(for: [fifth], analysisGuide: nil, commands: commands)
        }
        let after = try first.map(readSlice)
        withKnownIssue("CONC-05: the grown array is kept without its copy") {
            #expect(after == before)
            #expect(!engine.masks.keys.contains(MaskResources.key(for: fifth.shape)))
        }
    }

    @Test(arguments: failures)
    func `an edit guide rendered by a failed render is rendered again`(failure: CommandBufferFailure) throws {
        let session = try makeSession()
        var renders = 0
        func guide(_ commands: any MTLCommandBuffer) throws {
            engine.masks.use(session, commands: commands)
            _ = try engine.masks.editGuide(for: EditRecipe(), from: session, commands: commands) { _, _ in
                renders += 1
            }
        }
        try fail(failure, guide)
        try complete(guide)
        withKnownIssue("CONC-05: the edit guide is kept") {
            #expect(renders == 2)
        }
    }

    @Test(arguments: failures)
    func `an analysis guide rendered by a failed render is rendered again`(failure: CommandBufferFailure) throws {
        let session = try makeSession()
        var renders = 0
        func guide(_ commands: any MTLCommandBuffer) throws {
            engine.masks.use(session, commands: commands)
            _ = try engine.masks.analysisGuide(commands: commands) { _, _ in renders += 1 }
        }
        try fail(failure, guide)
        try complete(guide)
        withKnownIssue("CONC-05: the analysis guide is kept") {
            #expect(renders == 2)
        }
    }

    @Test(arguments: failures)
    func `a brush painted by a failed render leaves no painting cache`(failure: CommandBufferFailure) throws {
        let session = try makeSession()
        let brush = BrushMask(strokes: [
            BrushStroke(points: [ImagePoint(x: 0.1, y: 0.2), ImagePoint(x: 0.6, y: 0.5)], size: 0.08),
            BrushStroke(points: [ImagePoint(x: 0.3, y: 0.1), ImagePoint(x: 0.35, y: 0.9)], size: 0.05),
        ])
        try fail(failure) { commands in
            engine.masks.use(session, commands: commands)
            _ = try engine.masks.slices(
                for: [MaskComponent(shape: .brush(brush))], analysisGuide: nil, commands: commands,
            )
        }
        withKnownIssue("CONC-05: the painting cache is kept") {
            #expect(engine.masks.paintBase == nil)
            #expect(engine.masks.scratch == nil)
        }
    }

    /// The edge coefficients a dropped render grew into a larger array were never copied there.
    @Test func `the edge coefficients a dropped render grew keep their slices`() throws {
        let session = try makeSession()
        let first = try (0 ..< 4).map { try MaskInterleavingTests.bitmapComponent(seed: $0) }
        let fifth = try MaskInterleavingTests.bitmapComponent(seed: 4)
        func edges(_ components: [MaskComponent], _ commands: any MTLCommandBuffer) throws -> (any MTLTexture)? {
            try engine.masks.edges(for: components, session: session, commands: commands)?.texture
        }
        var before: [Float16] = []
        try complete { commands in
            before = try readFirst(#require(try edges(first, commands)))
        }
        try fail(.abandoned) { commands in
            _ = try edges([fifth], commands)
        }
        var after: [Float16] = []
        try complete { commands in
            after = try readFirst(#require(try edges(first, commands)))
        }
        withKnownIssue("CONC-05: the grown array is kept without its copy") {
            #expect(after == before)
        }
    }

    /// The Sky colours a dropped render grew into a larger array were never copied there.
    @Test func `the sky colours a dropped render grew keep their slices`() throws {
        let session = try makeSession()
        let first = try (0 ..< 2).map { try Self.skyComponent(seed: $0) }
        let third = try Self.skyComponent(seed: 2)
        func colors(_ components: [MaskComponent], _ commands: any MTLCommandBuffer) throws -> (any MTLTexture)? {
            try engine.masks.colors(for: components, session: session, commands: commands)?.texture
        }
        var before: [Float16] = []
        try complete { commands in
            before = try readFirst(#require(try colors(first, commands)))
        }
        try fail(.abandoned) { commands in
            _ = try colors([third], commands)
        }
        var after: [Float16] = []
        try complete { commands in
            after = try readFirst(#require(try colors(first, commands)))
        }
        withKnownIssue("CONC-05: the grown array is kept without its copy") {
            #expect(after == before)
        }
    }

    // MARK: - Helpers

    /// Encodes into a buffer that is dropped before it's committed, or that is reported to have
    /// failed on the GPU once it ran.
    private func fail(_ failure: CommandBufferFailure, _ encode: (any MTLCommandBuffer) throws -> Void) throws {
        let commands = try #require(engine.queue.makeCommandBuffer())
        switch failure {
        case .abandoned:
            #expect(throws: Failure.self) {
                try engine.encoding(commands) {
                    try encode(commands)
                    throw Failure()
                }
            }
        case .failed:
            try encode(commands)
            commands.commit()
            commands.waitUntilCompleted()
            engine.rollBack(commands, after: .failed)
        }
    }

    private func complete(_ encode: (any MTLCommandBuffer) throws -> Void) throws {
        let commands = try #require(engine.queue.makeCommandBuffer())
        try encode(commands)
        commands.commit()
        commands.waitUntilCompleted()
        #expect(commands.status == .completed)
    }

    private func readSlice(of component: MaskComponent) throws -> [UInt16] {
        let rasters = try #require(engine.masks.rasters)
        let slice = try #require(engine.masks.keys.firstIndex(of: MaskResources.key(for: component.shape)))
        let rowBytes = rasters.width * 2
        let buffer = try #require(engine.device.makeBuffer(
            length: rowBytes * rasters.height, options: .storageModeShared,
        ))
        let commands = try #require(engine.queue.makeCommandBuffer())
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

    /// The first slice of a shared RGBA half-float array.
    private func readFirst(_ texture: any MTLTexture) -> [Float16] {
        var values = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        values.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!, bytesPerRow: texture.width * 8, bytesPerImage: texture.width * texture.height * 8,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0, slice: 0,
            )
        }
        return values
    }

    static func skyComponent(seed: Int) throws -> MaskComponent {
        try MaskComponent(shape: .ai(AIMask(
            kind: .sky, provider: "test", revision: 1, analysisHash: "test", center: ImagePoint(x: 0.5, y: 0.5),
            bitmap: MaskInterleavingTests.ellipse(size: PixelSize(width: 96, height: 64), seed: seed),
        )))
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
                url: URL(fileURLWithPath: "/synthetic-mask-failure.dng"),
                pixelSize: PixelSize(width: width, height: height), isRaw: true, sensorDescription: "synthetic",
            ),
        )
        decoded.noiseProfile = DetailStageTests.noise
        return try SessionBuilder(device: engine.device, queue: engine.queue, kernels: engine.kernels).build(decoded)
    }
}
