import Foundation
import RedlampEngineAPI
import Testing

struct EditRecipeTests {
    @Test func `stores only non default values`() {
        var recipe = EditRecipe()
        recipe[.exposure] = 0.5
        recipe[.contrast] = 0
        #expect(recipe.values == [.exposure: 0.5])
        recipe[.exposure] = 0
        #expect(recipe.values.isEmpty)
    }

    @Test func `clamps to schema range`() {
        var recipe = EditRecipe()
        recipe[.exposure] = 12
        #expect(recipe[.exposure] == 5)
    }

    @Test func `round trips through JSON`() throws {
        var recipe = EditRecipe()
        recipe[.exposure] = 1.25
        recipe[.hueOrange] = -12
        recipe.treatment = .blackAndWhite
        recipe.pointCurve = [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 1)]
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        #expect(decoded == recipe)
    }

    @Test func `ignores unknown keys`() throws {
        let json = #"{"version":1,"values":{"basic.exposure":0.5,"future.parameter":3}}"#
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(decoded[.exposure] == 0.5)
        #expect(decoded.values.count == 1)
    }

    @Test func `mired scale round trips`() {
        let spec = ParameterID.temperature.spec
        for kelvin in [2000.0, 3200, 5500, 7500, 50000] {
            let position = spec.position(for: kelvin)
            #expect(abs(spec.value(atPosition: position) - kelvin) < 0.5)
        }
        #expect(spec.position(for: 5500) > 0.5)
    }

    @Test func `identity tone curve`() {
        let lut = ToneCurveMath.lut(for: EditRecipe(), count: 11)
        for (index, value) in lut.enumerated() {
            #expect(abs(Double(value) - Double(index) / 10) < 1e-6)
        }
    }

    @Test func `tone curve is monotonic`() {
        var recipe = EditRecipe()
        recipe[.curveDarks] = -100
        recipe[.curveLights] = 100
        recipe.pointCurve = [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.3, y: 0.1),
            CurvePoint(x: 0.7, y: 0.9),
            CurvePoint(x: 1, y: 1),
        ]
        let lut = ToneCurveMath.lut(for: recipe)
        #expect(zip(lut, lut.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func `formats like lightroom`() {
        #expect(ParameterID.exposure.spec.formatted(0.5) == "+0.50")
        #expect(ParameterID.exposure.spec.formatted(0) == "0.00")
        #expect(ParameterID.contrast.spec.formatted(-12) == "-12")
        #expect(ParameterID.contrast.spec.formatted(8) == "+8")
        #expect(ParameterID.temperature.spec.formatted(5512) == "5500")
    }
}
