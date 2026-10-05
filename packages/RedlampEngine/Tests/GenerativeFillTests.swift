import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampEngine

/// Generative fill (RM-10), with the model stood in for: what the engine shows it, and how a fill it
/// makes is kept and rendered.
extension RetouchTests {
    /// A Remove spot on the blemish, filled by a model that gives back exactly what it was shown.
    func echoedFill(engine: RedlampEngine, session: ImageSession) throws -> RetouchSpot {
        var spot = spot(.remove)
        spot.source = spot.center
        let crop = try #require(try engine.generativeCrop(
            for: spot, in: EditRecipe(), session: session, reference: .photo,
        ))
        #expect(crop.reference == crop.input)
        #expect(crop.mask.contains(1) && crop.mask.contains(0))
        spot.fill = try crop.fill(from: crop.input, seed: 3, prompt: "remove", model: "test", version: 1)
        return spot
    }

    @Test func `a fill that gives back what it was shown leaves the photo as it was`() throws {
        let engine = try RedlampEngine()
        let session = try scene(blemished: true)
        let photo = try render(session, EditRecipe(), engine: engine)
        var recipe = EditRecipe()
        recipe.spots = try [echoedFill(engine: engine, session: session)]
        let filled = try render(session, recipe, engine: engine)
        let before = statistics(photo, around: Self.blemish, radius: 6)
        let after = statistics(filled, around: Self.blemish, radius: 6)
        #expect(abs(after.mean - before.mean) < 0.01, "the blemish \(before.mean) → \(after.mean)")
        let around = statistics(photo, around: Self.blemish + SIMD2(30, 0), radius: 6).mean
        #expect(abs(around - after.mean) > 0.05, "the spot should still show the blemish")
    }

    @Test func `a fill renders the same every time, and without its bitmap the spot is filled from the photo`() throws {
        let engine = try RedlampEngine()
        let session = try scene(blemished: true)
        var recipe = EditRecipe()
        let spot = try echoedFill(engine: engine, session: session)
        recipe.spots = [spot]
        let first = try render(session, recipe, engine: engine)
        #expect(try render(session, recipe, engine: engine) == first)

        var classical = recipe
        classical.spots[0].fill = nil
        let contentAware = try render(session, classical, engine: engine)
        // A build reading an edit whose fill it can't use (made for a photo of another size, or its
        // bitmap missing) fills the spot from the photo instead.
        var resized = recipe
        resized.spots[0].fill?.photoSize = PixelSize(width: Self.width * 2, height: Self.height * 2)
        #expect(try render(session, resized, engine: engine) == contentAware)
        var unloaded = recipe
        unloaded.spots[0].fill?.bitmap.png = nil
        #expect(try render(session, unloaded, engine: engine) == contentAware)
    }

    @Test func `a fill keeps the photo's values through 16 bits`() throws {
        var rgb: [Float] = []
        for index in 0 ..< 64 * 32 {
            rgb += [Float(index % 64) / 63 * 3.5, Float(index / 64) / 31, 0.001 * Float(index % 7)]
        }
        let (png, peak) = try GeneratedFillCodec.encode(rgb, width: 64, height: 32)
        let decoded = try #require(GeneratedFillCodec.decode(png))
        #expect(decoded.width == 64 && decoded.height == 32)
        for index in 0 ..< 64 * 32 {
            for channel in 0 ..< 3 {
                let value = decoded.values[index * 4 + channel]
                let restored = value * value * Float(peak)
                let original = rgb[index * 3 + channel]
                #expect(abs(restored - original) <= max(original, 1e-3) * 1e-3, "\(original) → \(restored)")
            }
        }
    }
}
