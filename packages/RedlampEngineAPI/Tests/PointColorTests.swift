import Foundation
import RedlampEngineAPI
import Testing

struct PointColorTests {
    private let skin = OKLCh(lightness: 0.62, chroma: 0.07, hue: 52)

    @Test func `a swatch keeps only its own settings, clamped, and leaves defaults out`() {
        var swatch = PointColorSwatch(color: .oklch(skin))
        swatch[.pointColorHueUniformity] = 140
        swatch[.pointColorHueRange] = 50
        swatch[.exposure] = 1
        #expect(swatch[.pointColorHueUniformity] == 100)
        #expect(swatch.values == [.pointColorHueUniformity: 100])
        #expect(!swatch.isNeutral)
        swatch[.pointColorHueUniformity] = 0
        #expect(swatch.isNeutral)
        #expect(swatch.values.isEmpty)
    }

    @Test func `a range alone changes nothing`() {
        let swatch = PointColorSwatch(color: .oklch(skin), values: [.pointColorHueRange: 80, .pointColorSmoothness: 10])
        #expect(swatch.isNeutral)
        #expect(!PointColorSwatch(color: .mask, values: [.pointColorLuminanceShift: -5]).isNeutral)
    }

    @Test func `settings and fields a newer build wrote are kept`() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","color":"mask","tone":"warm","#
            + #""values":{"pointColor.uniformity.hue":50,"pointColor.range.fade":3}}"#
        let swatch = try JSONDecoder().decode(PointColorSwatch.self, from: Data(json.utf8))
        #expect(swatch.color == .mask)
        #expect(swatch[.pointColorHueUniformity] == 50)
        #expect(swatch.unknownValues == ["pointColor.range.fade": 3])
        #expect(swatch.unknownFields["tone"] == .string("warm"))
        let again = try JSONDecoder().decode(PointColorSwatch.self, from: JSONEncoder().encode(swatch))
        #expect(again == swatch)
    }

    @Test func `a colour this build doesn't know can't be read`() {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","color":"face"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PointColorSwatch.self, from: Data(json.utf8))
        }
    }

    @Test func `a picked colour reads back as it was written`() throws {
        let swatch = PointColorSwatch(
            color: .oklch(skin), picked: ColorSample(center: ImagePoint(x: 0.4, y: 0.3), radius: 0.01),
            values: [.pointColorSaturationShift: -20],
        )
        let data = try JSONEncoder().encode(swatch)
        guard case let .object(written) = try JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(color)? = written["color"]
        else {
            Issue.record("a swatch and its colour encode as objects")
            return
        }
        #expect(color["hue"] == .number(52))
        #expect(try JSONDecoder().decode(PointColorSwatch.self, from: data) == swatch)
    }

    @Test func `a swatch makes the edit edited, and its sliders aren't the edit's own`() {
        var recipe = EditRecipe()
        recipe[.pointColorHueShift] = 30
        #expect(recipe.isPristine)
        recipe.pointColor = [PointColorSwatch(color: .oklch(skin))]
        #expect(!recipe.isPristine)
    }

    @Test func `an edit without swatches writes no pointColor key, and one with them reads back`() throws {
        guard case let .object(plain) = try JSONDecoder().decode(
            JSONValue.self,
            from: JSONEncoder().encode(EditRecipe()),
        )
        else {
            Issue.record("an edit encodes as an object")
            return
        }
        #expect(plain["pointColor"] == nil)
        var recipe = EditRecipe()
        recipe.pointColor = [PointColorSwatch(color: .oklch(skin), values: [.pointColorHueUniformity: 60])]
        var mask = MaskLayer(name: "Face", components: [])
        mask.pointColor = [PointColorSwatch(color: .mask, values: [.pointColorSaturationUniformity: 35])]
        recipe.masks = [mask]
        #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe)) == recipe)
    }

    @Test func `resetting a mask's adjustments takes its swatches too`() {
        var mask = MaskLayer(name: "Face", components: [])
        mask.pointColor = [PointColorSwatch(color: .mask)]
        mask.resetAdjustments()
        #expect(mask.pointColor.isEmpty)
    }

    @Test func `pasting carries the swatches when Point Color is ticked`() throws {
        var source = EditRecipe()
        source.pointColor = [PointColorSwatch(color: .oklch(skin), values: [.pointColorHueUniformity: 60])]
        var target = EditRecipe()
        target.pointColor = [PointColorSwatch(color: .oklch(OKLCh(lightness: 0.5, chroma: 0.1, hue: 250)))]
        let pointColor = SettingsSelection(items: ["colorMixer.pointColor"])
        #expect(target.pasting(source, pointColor).pointColor == source.pointColor)
        #expect(target.pasting(source, SettingsSelection(items: ["colorMixer.hue"])).pointColor == target.pointColor)
        #expect(target.pasting(EditRecipe(), pointColor).pointColor.isEmpty, "the source's none reset the target's")
        let item = try #require(SettingsGroup.allItems.first { $0.id == "colorMixer.pointColor" })
        #expect(SettingsSelection.default.includes(item))
    }
}
