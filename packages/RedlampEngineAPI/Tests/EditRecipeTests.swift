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

    @Test func `round trips masks`() throws {
        var recipe = EditRecipe()
        var mask = MaskLayer(name: "Sky", components: [
            MaskComponent(shape: .linear(LinearMask(start: ImagePoint(x: 0.5, y: 0), end: ImagePoint(x: 0.5, y: 0.4)))),
            MaskComponent(
                shape: .radial(RadialMask(center: ImagePoint(x: 0.3, y: 0.3), radiusX: 0.1, radiusY: 0.1)),
                operation: .subtract,
                inverted: true,
            ),
        ])
        mask[.localExposure] = -1.25
        mask[.exposure] = 3 // global parameters are ignored on masks
        recipe.masks = [mask]
        #expect(!recipe.isPristine)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(decoded == recipe)
        #expect(decoded.masks[0][.localExposure] == -1.25)
        #expect(decoded.masks[0].adjustments.count == 1)
    }

    @Test func `global recipe ignores mask parameters`() {
        var recipe = EditRecipe()
        recipe[.localExposure] = 2
        recipe[.maskAmount] = 50
        #expect(recipe.values.isEmpty)
    }

    @Test func `keeps unknown keys through a round trip`() throws {
        let json = #"""
        {"version":1,"values":{"basic.exposure":0.5,"future.parameter":3},
         "futureStage":{"model":"denoise","strength":[1,2]}}
        """#
        var decoded = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(decoded[.exposure] == 0.5)
        #expect(decoded.values.count == 1)
        #expect(!decoded.isPristine)

        decoded[.contrast] = 10
        let written = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded))
        guard case let .object(root) = written, case let .object(values) = root["values"] else {
            Issue.record("recipe did not encode as an object")
            return
        }
        #expect(values["future.parameter"] == .number(3))
        #expect(values["basic.contrast"] == .number(10))
        #expect(root["futureStage"] == .object([
            "model": .string("denoise"),
            "strength": .array([.number(1), .number(2)]),
        ]))
    }

    @Test(arguments: FrameStyle.allCases)
    func `frame style is written by name and reads back`(style: FrameStyle) throws {
        var recipe = EditRecipe()
        recipe[.frameStyle] = Double(style.rawValue)
        let data = try JSONEncoder().encode(recipe)
        let written = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case let .object(root) = written, case let .object(values) = root["values"] else {
            Issue.record("recipe did not encode as an object")
            return
        }
        #expect(values["effects.frame.style"] == (style == .none ? nil : .string(style.key)))
        #expect(try JSONDecoder().decode(EditRecipe.self, from: data) == recipe)
    }

    @Test func `frame style names are stable`() {
        #expect(FrameStyle.allCases.map(\.key) == ["none", "keyline", "printBorder", "filmRebate", "slideMount"])
    }

    @Test func `frame style reads the index format 3 wrote`() throws {
        let json = #"{"version":3,"values":{"effects.frame.style":3,"basic.exposure":0.5}}"#
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(decoded[.frameStyle] == Double(FrameStyle.filmRebate.rawValue))
        #expect(decoded[.exposure] == 0.5)
    }

    @Test(arguments: [#""sprocketHoles""#, #"true"#])
    func `an unknown frame style doesn't read`(value: String) {
        let json = #"{"version":4,"values":{"effects.frame.style":\#(value)}}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        }
    }

    @Test func `mask adjustments keep unknown keys through a round trip`() throws {
        let json = #"""
        {"id":"9A1F3C2E-0000-4000-8000-000000000001","name":"Sky","isVisible":true,"components":[],
         "amount":100,"detail":0,"adjustments":{"local.exposure":-1,"local.future":2,"basic.exposure":3}}
        """#
        var mask = try JSONDecoder().decode(MaskLayer.self, from: Data(json.utf8))
        #expect(mask.adjustments == [.localExposure: -1])
        mask[.localContrast] = 20
        let written = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(mask))
        guard case let .object(root) = written, case let .object(adjustments) = root["adjustments"] else {
            Issue.record("mask did not encode as an object")
            return
        }
        #expect(adjustments == [
            "local.exposure": .number(-1), "local.future": .number(2), "local.contrast": .number(20),
        ])
    }

    @Test func `process version defaults and round trips`() throws {
        #expect(EditRecipe().processVersion == EditRecipe.currentProcessVersion)
        let legacy = try JSONDecoder().decode(EditRecipe.self, from: Data(#"{"version":1}"#.utf8))
        #expect(legacy.processVersion == 1)
        #expect(!legacy.requiresNewerProcess)

        let future = try JSONDecoder().decode(EditRecipe.self, from: Data(#"{"version":1,"processVersion":99}"#.utf8))
        #expect(future.requiresNewerProcess)
        let reencoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(future))
        #expect(reencoded.processVersion == 99)
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

    @Test func `value fields accept arithmetic`() {
        let exposure = ParameterID.exposure.spec
        #expect(exposure.parse("0.5") == 0.5)
        #expect(exposure.parse("+0.5") == 0.5)
        #expect(exposure.parse("-1") == -1)
        #expect(exposure.parse("2*0.5") == 1)
        #expect(exposure.parse("(1+2)/3") == 1)
        #expect(exposure.parse("x+0.5", current: 1) == 1.5)
        #expect(exposure.parse("x/2", current: 3) == 1.5)
        #expect(exposure.parse("0,5 EV") == 0.5)
        #expect(exposure.parse("99") == 5, "clamped to the slider range")
        #expect(exposure.parse("1/0") == nil)
        #expect(exposure.parse("x+1") == nil, "no current value")
        #expect(exposure.parse("1+") == nil)
        #expect(ParameterID.temperature.spec.parse("5500 K") == 5500)
    }
}
