import Foundation
import IOSurface
import Metal
import RedlampEngineAPI
import simd
import Testing
@testable import RedlampEngine

/// Raw revisions (CAM-31): an edit at an older revision than its photo was built at renders from a
/// variant of the photo built at the edit's revision.
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
        _ = try engine.renderFrame(
            RenderRequest(recipe: recipe, targetSize: PixelSize(width: 768, height: 96)), session: photo,
        )
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
