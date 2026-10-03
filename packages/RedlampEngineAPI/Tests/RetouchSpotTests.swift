import Foundation
import Testing
@testable import RedlampEngineAPI

struct RetouchSpotTests {
    static let spot = RetouchSpot(
        mode: .clone, center: ImagePoint(x: 0.2, y: 0.3), source: ImagePoint(x: 0.4, y: 0.3), radius: 0.05,
        feather: 20, opacity: 80,
    )

    @Test func `spots are saved with the edit and only when there are some`() throws {
        var recipe = EditRecipe()
        let plain = try String(decoding: JSONEncoder().encode(recipe), as: UTF8.self)
        #expect(!plain.contains("spots"))
        recipe.spots = [Self.spot]
        #expect(!recipe.isPristine)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(decoded.spots == [Self.spot])
        #expect(decoded == recipe)
    }

    @Test func `a brushed spot keeps its stroke, and a circle reads without one`() throws {
        var spot = Self.spot
        spot.stroke = [ImagePoint(x: 0.1, y: 0), ImagePoint(x: 0.1, y: 0.05)]
        let decoded = try JSONDecoder().decode(RetouchSpot.self, from: JSONEncoder().encode(spot))
        #expect(decoded == spot)
        let end = try #require(spot.points(at: spot.source).last)
        #expect(abs(end.x - 0.5) < 1e-12 && abs(end.y - 0.35) < 1e-12, "the stroke moves with the source")
        let circle = try String(decoding: JSONEncoder().encode(Self.spot), as: UTF8.self)
        #expect(!circle.contains("stroke"))
        #expect(try JSONDecoder().decode(RetouchSpot.self, from: Data(circle.utf8)) == Self.spot)
    }

    @Test func `a spot onto itself or at no opacity changes nothing`() {
        var spot = Self.spot
        #expect(!spot.isEmpty)
        spot.opacity = 0
        #expect(spot.isEmpty)
        spot = Self.spot
        spot.source = spot.center
        #expect(spot.isEmpty)
    }

    @Test func `pasting Heal and Clone takes the source's spots`() {
        var source = EditRecipe()
        source.spots = [Self.spot]
        var target = EditRecipe()
        target.spots = [RetouchSpot(
            center: ImagePoint(x: 0.8, y: 0.8),
            source: ImagePoint(x: 0.6, y: 0.8),
            radius: 0.02,
        )]
        #expect(target.pasting(source, .default).spots == target.spots, "not ticked the first time")
        #expect(target.pasting(source, SettingsSelection(items: ["remove.spots"])).spots == [Self.spot])
        #expect(SettingsSelection.changes(from: target, to: source).items == ["remove.spots"])
    }
}
