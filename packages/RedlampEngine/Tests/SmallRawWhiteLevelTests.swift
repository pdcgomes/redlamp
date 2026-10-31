import Foundation
import Metal
import RedlampEngineAPI
import simd
import Testing
@testable import RedlampEngine
@testable import RedlampServices

/// Canon's small raws (sRAW and mRAW CR2s), which LibRaw states clip at 16383 whatever the body
/// (CAM-33). Each body's data clips elsewhere, so normalised at 16383 one whose data clips lower
/// opened darker than its full raws, and one whose data clips higher opened brighter, its brightest
/// highlights cut off. From process 20 (raw revision 6) a body whose small raws were measured is
/// normalised where its data clips, and edits made before render as they did.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct SmallRawWhiteLevelTests {
    /// Where the EOS 7D's small raws' data clips, and the level LibRaw states for them.
    static let white: Float = 11785
    static let libRaw: Float = 16383
    /// The decode suite's 7D sRAW's as-shot multipliers.
    static let asShot = SIMD3<Double>(2.1152, 1, 1.4883)
    /// Its colour matrix (XYZ to camera), from LibRaw.
    static let xyzToCamera = [0.6844, -0.0996, -0.0856, -0.3876, 1.1761, 0.2396, -0.0593, 0.1772, 0.6198]
    static let size = 512
    static let cameras = CameraGoldenTests.root.appending(path: "tests/fixtures/cameras")
    /// The decode suite's small raws of three measured bodies, with where their data clips.
    static let samples: [(url: URL, white: Float)] = [
        ("Canon_EOS-5D-Mark-IV_sRAW.CR2", 19147), ("Canon_EOS-5D-Mark-IV_mRAW.CR2", 19147),
        ("Canon_EOS-7D_sRAW.CR2", 11785), ("Canon_EOS-40D_sRAW.CR2", 17421),
    ].map { (cameras.appending(path: $0.0), $0.1) }
    static let fullRaw = cameras.appending(path: "Canon_EOS-5D-Mark-IV.CR2")
    static let sevenD = samples[2].url

    let detail: DetailStageTests

    init() throws {
        detail = try DetailStageTests()
    }

    @Test func `an edit before process 20 renders a measured body's small raw at LibRaw's white level, as it did`(
    ) throws {
        let engine = try RedlampEngine()
        let photo = try session(Self.sRAW())
        let then = try session(Self.sRAW(measured: false), revision: .fifth)
        #expect(photo.rawChanges == [.sixth] && photo.rawSource != nil)
        var recipe = EditRecipe()
        recipe.processVersion = 19
        let variant = try engine.revisions.session(for: recipe, base: photo)
        #expect(variant !== photo && variant.rawRevision == .fifth)
        #expect(variant.noise == then.noise && photo.noise != then.noise, "its noise measured at LibRaw's level")
        #expect(try detail.readLevel(variant, level: 0) == detail.readLevel(then, level: 0))
        let request = RenderRequest(recipe: recipe, targetSize: photo.orientedSize, generation: 0)
        #expect(try render(request, engine, photo) == render(request, engine, then))
        recipe.processVersion = 14
        #expect(try engine.revisions.session(for: recipe, base: photo) === variant, "every earlier revision's")
        #expect(engine.revisions.variantsBuilt == 1)
    }

    @Test func `from process 20 a measured body's small raw is normalised where its data clips`() throws {
        let engine = try RedlampEngine()
        let photo = try session(Self.sRAW())
        let then = try session(Self.sRAW(measured: false), revision: .fifth)
        var recipe = EditRecipe()
        recipe.processVersion = 20
        #expect(try engine.revisions.session(for: recipe, base: photo) === photo)
        try expectNormalisedAtWhite(photo, then)
        let clipped = photo.analysis.pixel(x: 8, y: 8), before = then.analysis.pixel(x: 8, y: 8)
        #expect(clipped == SIMD3(1, 1, 1), "what the camera clipped is white: \(clipped)")
        #expect(abs(before.y - Self.white / Self.libRaw) < 0.001, "where green stopped below the others: \(before)")
        #expect(engine.revisions.variantsBuilt == 0)
    }

    /// A photo opened for an edit made before process 20 is built as Redlamp built it then. Moved to
    /// 20, the edit renders from a variant at the measured white level, with its noise measured
    /// there, as the photo opened at 20 renders it.
    @Test func `an edit moved to process 20 renders at the measured white level from a photo opened for 19`() throws {
        let engine = try RedlampEngine()
        let photo = try session(Self.sRAW(), revision: .fifth)
        let then = try session(Self.sRAW(measured: false), revision: .fifth)
        let current = try session(Self.sRAW())
        #expect(photo.noise == then.noise)
        #expect(try detail.readLevel(photo, level: 0) == detail.readLevel(then, level: 0))
        var recipe = EditRecipe()
        recipe.processVersion = 19
        #expect(try engine.revisions.session(for: recipe, base: photo) === photo)
        recipe.processVersion = 20
        let variant = try engine.revisions.session(for: recipe, base: photo)
        #expect(variant !== photo && variant.noise == current.noise)
        let request = RenderRequest(recipe: recipe, targetSize: current.orientedSize, generation: 0)
        #expect(try render(request, engine, photo) == render(request, engine, current))
        #expect(engine.revisions.variantsBuilt == 1)
    }

    @Test func `a small raw of a body that wasn't measured renders from one photo at every process`() throws {
        let engine = try RedlampEngine()
        let photo = try session(Self.sRAW(measured: false))
        #expect(photo.rawChanges.isEmpty && photo.rawSource == nil)
        var renders: [[SIMD3<Float>]] = []
        for process in [14, 19, 20] {
            var recipe = EditRecipe()
            recipe.processVersion = process
            #expect(try engine.revisions.session(for: recipe, base: photo) === photo)
            try renders.append(render(
                RenderRequest(recipe: recipe, targetSize: photo.orientedSize, generation: 0), engine, photo,
            ))
        }
        #expect(renders[1] == renders[2])
        #expect(engine.revisions.variantsBuilt == 0)
    }

    @Test func `only Canon's small raws of a measured body have a white level of their own`() {
        let lookup = RawDecoder.smallRawWhiteLevel
        #expect(lookup("Canon", "EOS 7D", "canon_sraw_load_raw")?.level == Self.white)
        #expect(lookup("Canon", "EOS 80D", "canon_sraw_load_raw") == nil, "a body that wasn't measured")
        #expect(lookup("Canon", "EOS 7D", "lossless_jpeg_load_raw") == nil, "the body's full raws")
        for decoder in RawDecoder.smallRawDecoders.subtracting(["canon_sraw_load_raw"]) {
            #expect(lookup("Canon", "EOS 7D", decoder) == nil, "\(decoder)")
        }
        #expect(lookup(nil, "EOS 7D", "canon_sraw_load_raw") == nil)
        #expect(RawDecoder.smallRawWhiteLevels.count == 15)
        #expect(RawDecoder.smallRawWhiteLevels.values.allSatisfy { $0.revision == .sixth })
    }

    /// The real files, as the decoder gives them; none is among the process-stability fixtures.
    @Test(.enabled(if: (samples.map(\.url) + [fullRaw]).allSatisfy { FileManager.default.fileExists(atPath: $0.path) }))
    func `the measured bodies' small raws take their white level from process 20, and a full raw at every process`(
    ) throws {
        for (url, white) in Self.samples {
            let decoded = try ImageDecoder.decode(url)
            let name = url.lastPathComponent
            #expect(decoded.whiteLevel == white && decoded.whiteLevelRevision == .sixth, "\(name)")
            #expect(decoded.earlierWhiteLevel == Self.libRaw, "\(name)")
            #expect(SessionBuilder.taken(decoded, at: RawRevision(processVersion: 19)).whiteLevel == Self.libRaw)
            #expect(SessionBuilder.taken(decoded, at: RawRevision(processVersion: 20)).whiteLevel == white)
        }
        let full = try ImageDecoder.decode(Self.fullRaw)
        #expect(full.whiteLevelRevision == .first && full.earlierWhiteLevel == nil)
        #expect(SessionBuilder.taken(full, at: RawRevision(processVersion: 19)).whiteLevel == full.whiteLevel)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: sevenD.path)))
    func `the 7D's sRAW renders at process 19 exactly as before, and at 20 where its data clips`() throws {
        let engine = try RedlampEngine()
        let decoded = try ImageDecoder.decode(Self.sevenD)
        var before = decoded
        (before.whiteLevel, before.whiteLevelRevision, before.earlierWhiteLevel) = (Self.libRaw, .first, nil)
        let photo = try session(decoded)
        let then = try session(before, revision: .fifth)
        var recipe = EditRecipe()
        recipe.processVersion = 19
        let variant = try engine.revisions.session(for: recipe, base: photo)
        #expect(variant.noise == then.noise)
        let request = RenderRequest(
            recipe: recipe, targetSize: PixelSize(
                width: photo.orientedSize.width / 4,
                height: photo.orientedSize.height / 4,
            ),
            generation: 0,
        )
        #expect(try render(request, engine, photo) == render(request, engine, then))
        try expectNormalisedAtWhite(photo, then)
    }

    // MARK: - Helpers

    /// `photo`'s level 0 is `then`'s times LibRaw's white level over the measured one, wherever it
    /// stays below 1.
    func expectNormalisedAtWhite(_ photo: ImageSession, _ then: ImageSession) throws {
        let ratio = Self.libRaw / Self.white
        let pairs = try zip(detail.readLevel(photo, level: 0), detail.readLevel(then, level: 0))
            .filter { $0.1.max() < 0.7 && $0.1.min() > 0.02 }
        #expect(pairs.count > 1000)
        let worst = pairs.map { simd_reduce_max(simd_abs($0.0 / $0.1 / ratio - 1)) }.max() ?? 1
        #expect(worst < 0.002, "brighter by \(ratio) within float16's rounding, at worst \(worst) off")
    }

    /// A 512 x 512 7D sRAW: flat 16 x 16 patches of random greys in camera RGB before white
    /// balance, between black (0) and where its data clips, with Poisson–Gaussian noise, the first
    /// patch at the clip in every colour, as the camera clipped it. As the decoder gives it with its
    /// measured white level, or (`measured` false) as it did before, at LibRaw's.
    static func sRAW(measured: Bool = true) -> DecodedImage {
        let (a, b): (Float, Float) = (4e-4, 4e-6)
        var state: UInt64 = 33
        func uniform() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
        func gaussian() -> Float {
            (-2 * log(max(uniform(), 1e-7))).squareRoot() * cos(2 * .pi * uniform())
        }
        let columns = size / 16
        let patches: [Float?] = (0 ..< columns * columns).map { $0 == 0 ? nil : 0.05 + 0.75 * uniform() }
        var samples = [UInt16](repeating: 0, count: size * size * 3)
        for y in 0 ..< size {
            for x in 0 ..< size {
                for channel in 0 ..< 3 {
                    let value: Float = if let grey = patches[(y / 16) * columns + x / 16] {
                        grey / Float(asShot[channel]) + (a * grey / Float(asShot[channel]) + b).squareRoot()
                            * gaussian()
                    } else {
                        1
                    }
                    samples[(y * size + x) * 3 + channel] = UInt16(min(max(value * white, 0), 65535).rounded())
                }
            }
        }
        var decoded = DecodedImage(
            width: size, height: size, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: measured ? white : libRaw, asShotMultipliers: asShot,
            cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: xyzToCamera, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/IMG_0001.CR2"), pixelSize: PixelSize(width: size, height: size),
                isRaw: true, sensorDescription: "Small raw", make: "Canon", model: "EOS 7D",
            ),
        )
        if measured {
            decoded.whiteLevelRevision = .sixth
            decoded.earlierWhiteLevel = libRaw
        }
        return decoded
    }

    func session(_ decoded: DecodedImage, revision: RawRevision = .current) throws -> ImageSession {
        try SessionBuilder(device: detail.device, queue: detail.queue, kernels: detail.kernels)
            .build(decoded, revision: revision)
    }

    func render(_ request: RenderRequest, _ engine: RedlampEngine, _ session: ImageSession) throws -> [SIMD3<Float>] {
        try HighlightReconstructionTests.pixels(engine.renderFrame(request, session: session))
    }
}
