import Foundation
import RedlampEngineAPI
import Testing

/// Effects for a mask's adjustments (UX-27): what choosing one changes on a mask, what saving one
/// keeps, and Redlamp's own.
struct MaskEffectTests {
    private func effect(named name: String) throws -> MaskEffect {
        try #require(MaskEffect.builtIn.first { $0.name == name })
    }

    private var bentCurves: MaskCurves {
        var curves = MaskCurves()
        curves.rgb = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)]
        return curves
    }

    /// A radial mask with every setting moved: its own sliders, Color and Curves, and the
    /// settings that aren't an effect's.
    private func adjustedMask() -> MaskLayer {
        let gradient = RadialMask(center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)
        var mask = MaskLayer(
            name: "Mask 1", components: [MaskComponent(shape: .radial(gradient), operation: .add, inverted: false)],
            amount: 80, adjustments: [
                .localExposure: 1,
                .localClarity: 30,
                .localColorHue: 120,
                .localColorSaturation: 40,
            ],
        )
        mask.detail = 20
        mask.inverted = true
        mask.curves = bentCurves
        mask.pointColor = [PointColorSwatch(color: .mask, values: [.pointColorHueUniformity: 50])]
        return mask
    }

    @Test func `an effect sets the mask's sliders and curves and leaves the rest as it was`() throws {
        let before = adjustedMask()
        var mask = before
        try mask.apply(effect(named: "Dodge"))
        #expect(mask.adjustments == [.localExposure: 0.35], "Clarity and the Color went back to 0")
        #expect(mask.curves == nil, "the curves are straight")
        #expect(mask.components == before.components)
        #expect(mask.amount == 80 && mask.detail == 20 && mask.inverted)
        #expect(mask.pointColor == before.pointColor)
        #expect(mask.name == before.name && mask.isVisible)
    }

    @Test func `a mask has the effect its sliders and curves are, and no other`() throws {
        let (dodge, burn) = try (effect(named: "Dodge"), effect(named: "Burn"))
        var mask = adjustedMask()
        #expect(!mask.has(dodge) && !mask.has(burn))
        mask.apply(dodge)
        #expect(mask.has(dodge) && !mask.has(burn))
        mask[.localClarity] = 5
        #expect(!mask.has(dodge), "a slider moved since")
        mask.apply(dodge)
        mask.curves = bentCurves
        #expect(!mask.has(dodge), "a curve bent since")
        mask.apply(burn)
        #expect(mask.has(burn) && mask.isAdjusted)
        mask.resetAdjustments()
        #expect(!mask.isAdjusted)
    }

    @Test func `an effect saved from a mask keeps its sliders, Color and curves, and sets another mask to them`(
    ) throws {
        let source = adjustedMask()
        let saved = MaskEffect(source, name: "Warm Glow")
        #expect(saved.localAdjustments == source.adjustments)
        #expect(saved.curves == bentCurves)
        #expect(!saved.isEmpty)

        let read = try JSONDecoder().decode(MaskEffect.self, from: JSONEncoder().encode(saved))
        #expect(read == saved, "it reads back as it was written")
        var other = MaskLayer(name: "Mask 2", components: [])
        other.apply(read)
        #expect(other.has(saved))
        #expect(other.adjustments == source.adjustments && other.curves == source.curves)
        #expect(other.amount == 100 && other.detail == 0 && !other.inverted && other.pointColor.isEmpty)
    }

    @Test func `an effect from a newer Redlamp is read, without the settings this build doesn't know`() throws {
        let json = #"""
        {"id": "x", "name": "Later", "adjustments": {"local.exposure": 0.5, "local.future": 3, "mask.amount": 50}}
        """#
        let effect = try JSONDecoder().decode(MaskEffect.self, from: Data(json.utf8))
        #expect(effect.localAdjustments == [.localExposure: 0.5])
        var mask = MaskLayer(name: "Mask 1", components: [], amount: 70)
        mask.apply(effect)
        #expect(mask.adjustments == [.localExposure: 0.5] && mask.amount == 70)
        #expect(MaskEffect(name: "Nothing", adjustments: [.localExposure: 0]).isEmpty)
    }

    @Test func `Redlamp's effects each set something, on their sliders' steps and within their ranges`() {
        #expect(Set(MaskEffect.builtIn.map(\.id)).count == MaskEffect.builtIn.count)
        #expect(Set(MaskEffect.builtIn.map(\.name)).count == MaskEffect.builtIn.count)
        for effect in MaskEffect.builtIn {
            #expect(!effect.isEmpty, "\(effect.name) sets nothing")
            #expect(
                effect.localAdjustments.count == effect.adjustments.count,
                "\(effect.name) names a slider masks lack",
            )
            for (parameter, value) in effect.localAdjustments {
                #expect(parameter.spec.quantize(parameter.spec.clamp(value)) == value, "\(effect.name)'s \(parameter)")
            }
        }
    }

    @Test func `a mask made by the preset of an effect's name has that effect`() {
        let shared = MaskEffect.builtIn.compactMap { effect in
            MaskPreset.builtIn.first { $0.name == effect.name }.map { (effect, $0) }
        }
        #expect(shared.map(\.0.name) == ["Smooth Skin", "Whiten Teeth", "Pop Eyes"])
        for (effect, preset) in shared {
            let mask = MaskLayer(name: preset.name, components: [], adjustments: preset.localAdjustments)
            #expect(mask.has(effect), "\(preset.name)'s adjustments aren't its effect's")
        }
    }
}
