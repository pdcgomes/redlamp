import Foundation
import IOSurface
import Metal
import RedlampColor
import RedlampEngineAPI
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Clipped highlights pulled below white (CAM-31). From the second raw revision (process 15), a sky
/// clipped in one or two colours keeps the colour around it and an area clipped in every colour
/// fades to neutral; an edit at the first renders, from a variant of the photo, as CAM-08 shipped.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct HighlightReconstructionTests {
    let detail: DetailStageTests

    init() throws {
        detail = try DetailStageTests()
    }

    /// The Nikon Z 8 sample's as-shot multipliers: in daylight red's is nearly twice green's, so
    /// after white balance red clips at nearly twice green's level.
    static let daylight = SIMD3<Double>(1.908, 1, 1.537)
    /// A blue sky, white-balanced.
    static let sky = SIMD3<Float>(0.75, 0.9, 1.15)

    // MARK: - The second revision

    /// A sky brightening to the right: green clips from 36% of the way across and blue from 52%,
    /// red never. The first revision turns it lilac where both clipped, with a cyan band before.
    @Test(arguments: [SensorKind.bayer, .xTrans])
    func `a clipped sky pulled below white keeps its hue`(sensor: SensorKind) throws {
        func hues(_ revision: RawRevision) throws -> (unclipped: Float, rebuilt: Float) {
            let columns = try columns(skySession(sensor, revision: revision), rows: 24 ..< 72)
            return (Self.hue(Self.mean(columns[40 ..< 240])), Self.hue(Self.mean(columns[460 ..< 728])))
        }
        let second = try hues(.second)
        let first = try hues(.first)
        #expect(
            abs(second.rebuilt - second.unclipped) < 3,
            "rebuilt sky \(second.rebuilt)°, unclipped \(second.unclipped)°",
        )
        #expect(
            abs(first.rebuilt - first.unclipped) > 15,
            "the first revision's \(first.rebuilt)°, \(first.unclipped)°",
        )
    }

    @Test(arguments: [SensorKind.bayer, .xTrans])
    func `nothing steps where a second colour starts to clip`(sensor: SensorKind) throws {
        let second = try Self.steepestStep(columns(skySession(sensor, revision: .second), rows: 24 ..< 72))
        let first = try Self.steepestStep(columns(skySession(sensor, revision: .first), rows: 24 ..< 72))
        #expect(second < 1, "steepest step \(second), the first revision's \(first)")
        #expect(first > 3, "the first revision's steepest step \(first)")
    }

    /// The sun in the sky: clipped in every colour, with clipped glow around it. A dark twig passes
    /// beside it, within the fade's reach.
    @Test func `an area clipped in every colour fades to neutral, and unclipped detail beside it keeps its colour`(
    ) throws {
        let centre = SIMD2<Float>(538, 128)
        func sunSession(_ revision: RawRevision) throws -> ImageSession {
            try session(.bayer, width: 768, height: 256, revision: revision) { x, y in
                if (482 ..< 498).contains(x) {
                    return SIMD3(0.12, 0.1, 0.06)
                }
                let distance = simd_distance(SIMD2(Float(x), Float(y)), centre)
                let glow = 1.5 + 2.5 * exp(-max(distance - 10, 0) / 24)
                return Self.sky * max(0.6 + Float(x) / 768, glow)
            }
        }
        let second = try columns(sunSession(.second), rows: 126 ..< 131)
        let first = try columns(sunSession(.first), rows: 126 ..< 131)
        let sun = second[538]
        #expect(simd_reduce_max(sun) / simd_reduce_min(sun) < 1.01, "the sun \(sun)")
        let near = Self.chroma(second[574]), far = Self.chroma(second[628])
        #expect(near < 0.6 * far, "chroma beside the sun \(near), further out \(far)")
        for x in 487 ..< 493 {
            #expect(second[x] == first[x], "the twig at \(x): \(second[x]), was \(first[x])")
        }
    }

    /// Saturated foliage, bright in green only, borders the clipped sky's lower half.
    @Test func `bright foliage beside a clipped sky isn't taken for its rim`() throws {
        let session = try session(.bayer, width: 768, height: 192, revision: .second) { x, y in
            if y >= 96, x < 400 {
                return SIMD3(0.12, 0.95, 0.1)
            }
            return Self.sky * (0.6 + 1.4 * Float(x) / 768)
        }
        let columns = try columns(session, rows: 16 ..< 72)
        let unclipped = Self.hue(Self.mean(columns[40 ..< 240])), rebuilt = Self.hue(Self.mean(columns[460 ..< 728]))
        #expect(abs(rebuilt - unclipped) < 3, "rebuilt sky \(rebuilt)°, unclipped \(unclipped)°")
    }

    /// The development samples overexposed two stops and clipped at the white level, as a sensor
    /// clips, against the same samples as shot (they didn't clip): the truth.
    static let overexposed = ["AFXT2720.RAF", "Canon_EOS_R6_RAW_ISO_100_nocrop_nodual.CR3"].compactMap { name in
        EngineSmokeTests.fixtures.first { $0.lastPathComponent == name }
    }

    /// How much closer to the truth the second revision must come: a quarter on the X-T3, whose
    /// clipped grey wall the first turns lilac; on the R6, whose clipped objects were near neutral,
    /// no further than the first.
    static let closer = ["AFXT2720.RAF": 0.75, "Canon_EOS_R6_RAW_ISO_100_nocrop_nodual.CR3": 1.0]

    @Test(.enabled(if: !overexposed.isEmpty), arguments: overexposed)
    func `overexposed samples come closer to their unclipped originals`(sample: URL) throws {
        let decoded = try ImageDecoder.decode(sample)
        let builder = SessionBuilder(device: detail.device, queue: detail.queue, kernels: detail.kernels)
        let truth = try builder.build(decoded, revision: .first)
        let clipped = Self.overexposed(decoded, stops: 2)
        let first = try Self.error(builder.build(clipped, revision: .first), truth: truth, detail: detail)
        let second = try Self.error(builder.build(clipped, revision: .second), truth: truth, detail: detail)
        let ratio = try #require(Self.closer[sample.lastPathComponent])
        #expect(second <= ratio * first, "\(sample.lastPathComponent): error \(second), the first revision's \(first)")
    }

    // MARK: - Older edits

    /// The photo open at the second revision renders an edit at process 14 from a variant built at
    /// the first, pixel for pixel as a photo built at the first renders it.
    @Test func `an edit at process 14 renders exactly as the first revision built it`() throws {
        let engine = try RedlampEngine()
        let photo = try skySession(.bayer, revision: .second)
        let firstBuilt = try skySession(.bayer, revision: .first)
        var recipe = EditRecipe()
        recipe.processVersion = 14
        recipe[.exposure] = -1.5
        let request = RenderRequest(recipe: recipe, targetSize: PixelSize(width: 768, height: 96))
        let older = try Self.pixels(engine.renderFrame(request, session: photo))
        let built = try Self.pixels(engine.renderFrame(request, session: firstBuilt))
        #expect(older == built)
        #expect(engine.revisions.keptVariants.count == 1 && engine.revisions.variantsBuilt == 1)
        recipe.processVersion = 15
        let newer = try Self.pixels(engine.renderFrame(
            RenderRequest(recipe: recipe, targetSize: PixelSize(width: 768, height: 96)), session: photo,
        ))
        #expect(newer != older)
        #expect(engine.revisions.variantsBuilt == 1)
    }

    /// A photo nothing clipped in builds the same pyramid at every revision, so it keeps no raw
    /// source and an older edit needs no variant.
    @Test func `a photo nothing clipped in serves every revision`() throws {
        let engine = try RedlampEngine()
        let photo = try detail.makeSession(.bayer, width: 256, height: 128, noiseScale: 0, revision: .second)
        #expect(photo.rawSource == nil)
        var recipe = EditRecipe()
        recipe.processVersion = 14
        #expect(try engine.revisions.session(for: recipe, base: photo) === photo)
        #expect(engine.revisions.variantsBuilt == 0)
    }

    // MARK: - Helpers

    func skySession(_ sensor: SensorKind, revision: RawRevision) throws -> ImageSession {
        try session(sensor, width: 768, height: 96, revision: revision) { x, _ in
            Self.sky * (0.6 + 1.4 * Float(x) / 768)
        }
    }

    /// `colour` per photosite (white-balanced), as a camera balanced by `daylight` records it.
    func session(
        _ sensor: SensorKind, width: Int, height: Int, revision: RawRevision,
        colour: (Int, Int) -> SIMD3<Float>,
    ) throws -> ImageSession {
        try detail.makeSession(
            sensor, width: width, height: height, noiseScale: 0, asShot: Self.daylight, revision: revision,
        ) { x, y in
            let channel = Self.channel(sensor, x, y)
            return min(colour(x, y)[channel] / Float(Self.daylight[channel]), 1)
        }
    }

    /// The colour of a photosite in `DetailStageTests.makeSession`'s patterns.
    static func channel(_ sensor: SensorKind, _ x: Int, _ y: Int) -> Int {
        let xTrans = [
            1, 1, 0, 1, 1, 2, 1, 1, 2, 1, 1, 0, 2, 0, 1, 0, 2, 1,
            1, 1, 2, 1, 1, 0, 1, 1, 0, 1, 1, 2, 0, 2, 1, 2, 0, 1,
        ]
        return sensor == .xTrans ? xTrans[(y % 6) * 6 + x % 6] : [0, 1, 1, 2][(y % 2) * 2 + x % 2]
    }

    /// Each column's mean over `rows` of the pyramid's level 0: white-balanced camera RGB, which
    /// these sessions' identity matrix makes linear sRGB.
    func columns(_ session: ImageSession, rows: Range<Int>) throws -> [SIMD3<Float>] {
        let pixels = try detail.readLevel(session, level: 0)
        let width = session.pyramid.width
        return (0 ..< width).map { x in
            rows.reduce(SIMD3<Float>.zero) { $0 + pixels[$1 * width + x] } / Float(rows.count)
        }
    }

    static func mean(_ colours: ArraySlice<SIMD3<Float>>) -> SIMD3<Float> {
        colours.reduce(.zero, +) / Float(colours.count)
    }

    /// OKLab hue in degrees.
    static func hue(_ colour: SIMD3<Float>) -> Float {
        let lab = OKLab.fromLinearSRGB(colour)
        return atan2(lab.z, lab.y) * 180 / .pi
    }

    static func chroma(_ colour: SIMD3<Float>) -> Float {
        let lab = OKLab.fromLinearSRGB(colour)
        return simd_length(SIMD2(lab.y, lab.z))
    }

    /// The largest change in OKLab a and b (× 100) between columns 8 apart, from the unclipped sky
    /// across both clipped areas: where a band shows.
    static func steepestStep(_ columns: [SIMD3<Float>]) -> Float {
        (240 ..< 720).map { x in
            let a = OKLab.fromLinearSRGB(columns[x]), b = OKLab.fromLinearSRGB(columns[x + 8])
            return simd_length(SIMD2(a.y - b.y, a.z - b.z)) * 100
        }.max() ?? 0
    }

    /// The mean OKLab difference (× 100) between `session`, made from a mosaic overexposed two
    /// stops, and `truth`, over the pixels it clipped, both at Exposure −1.5.
    static func error(_ session: ImageSession, truth: ImageSession, detail: DetailStageTests) throws -> Double {
        let level = 2
        let clipped = try detail.readLevel(session, level: level)
        let original = try detail.readLevel(truth, level: level)
        let clip = SIMD3<Float>(truth.balanceMultipliers) * HighlightModel.clipFraction
        let matrix = truth.cameraToWorking
        let pulled = Float(pow(2, -1.5))
        func lab(_ camera: SIMD3<Float>) -> SIMD3<Float> {
            OKLab.fromLinearRec2020(simd_max(matrix * camera * pulled, .zero))
        }
        var sum = 0.0, count = 0
        for index in original.indices where any(original[index] * 4 .>= clip) {
            sum += Double(simd_distance(lab(clipped[index] / 4), lab(original[index]))) * 100
            count += 1
        }
        return sum / Double(max(count, 1))
    }

    /// `image` with `stops` more light, clipped at the white level.
    static func overexposed(_ image: DecodedImage, stops: Float) -> DecodedImage {
        guard case let .mosaic(pattern) = image.layout else { return image }
        let gain = powf(2, stops)
        let blacks = image.blackLevels
        let samples = (0 ..< image.width * image.height).map { index in
            let (x, y) = (index % image.width, index / image.width)
            let position = ((y % pattern.height) * pattern.width + x % pattern.width) % max(blacks.count, 1)
            let black = blacks.isEmpty ? 0 : blacks[position]
            let value = (Float(image.samples[index]) - black) * gain + black
            return UInt16(min(max(value, 0), image.whiteLevel).rounded())
        }
        var copy = DecodedImage(
            width: image.width, height: image.height, layout: image.layout, samples: samples,
            blackLevels: image.blackLevels, whiteLevel: image.whiteLevel, asShotMultipliers: image.asShotMultipliers,
            cameraToSRGB: image.cameraToSRGB, xyzToCamera: image.xyzToCamera, orientation: image.orientation,
            baselineExposure: image.baselineExposure, info: image.info,
        )
        copy.noiseProfile = image.noiseProfile
        copy.gainMaps = image.gainMaps
        copy.dngColor = image.dngColor
        copy.dngProfile = image.dngProfile
        copy.lensCorrection = image.lensCorrection
        copy.banding = image.banding
        return copy
    }

    static func pixels(_ frame: RenderedFrame) -> [SIMD3<Float>] {
        let surface = frame.surface
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        return (0 ..< frame.size.height).flatMap { y in
            let row = (base + y * bytesPerRow).assumingMemoryBound(to: Float16.self)
            return (0 ..< frame.size.width).map { x in
                SIMD3(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2]))
            }
        }
    }
}
