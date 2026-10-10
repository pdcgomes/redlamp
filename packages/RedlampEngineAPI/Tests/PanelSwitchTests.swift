import Foundation
import Testing
@testable import RedlampEngineAPI

struct PanelSwitchTests {
    @Test func `an edit with every panel on renders as it is`() {
        var recipe = EditRecipe()
        recipe[.sharpenAmount] = 80
        recipe[.transformVertical] = 20
        recipe.pointCurve = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)]
        #expect(recipe.rendered == recipe)
        #expect(EditRecipe().rendered == EditRecipe())
    }

    /// Detail off is no sharpening and no noise reduction, though both have defaults that act.
    @Test func `Detail off renders no sharpening and no noise reduction`() {
        var recipe = EditRecipe()
        recipe[.noiseLuminance] = 30
        recipe.setPanel(.detail, on: false)
        let rendered = recipe.rendered
        #expect(rendered[.sharpenAmount] == 0)
        #expect(rendered[.noiseLuminance] == 0)
        #expect(rendered[.noiseColor] == 0)
        #expect(rendered.panelsOff.isEmpty)
        #expect(recipe[.noiseLuminance] == 30, "the panel keeps its settings")
        #expect(recipe[.sharpenAmount] == 40)
    }

    /// Lens off is no profile correction, so none of the corrections a file carries either: the
    /// geometry's profile and its distortion go.
    @Test func `Lens Corrections off renders no profile and no manual corrections`() {
        var recipe = EditRecipe()
        recipe[.lensDistortion] = 30
        recipe[.defringePurpleAmount] = 5
        recipe[.lensRemoveChromaticAberration] = 1
        recipe.setPanel(.lens, on: false)
        let rendered = recipe.rendered
        #expect(rendered[.lensProfile] == 0)
        #expect(rendered[.lensDistortion] == 0)
        #expect(rendered[.defringePurpleAmount] == 0)
        #expect(rendered[.lensRemoveChromaticAberration] == 0)

        let lens = LensCorrection(
            source: .dng, center: SIMD2(0.5, 0.5), radii: [0, 0.5, 1],
            distortion: [SIMD3(repeating: 1), SIMD3(repeating: 1.01), SIMD3(repeating: 1.03)], vignetting: [],
        )
        var on = recipe
        on.setPanel(.lens, on: true)
        let size = PixelSize(width: 600, height: 400)
        #expect(GeometryMap.profile(lens, recipe: on) != nil)
        #expect(GeometryMap.profile(lens, recipe: recipe) == nil)
        let map = GeometryMap(recipe: recipe, imageSize: size, lens: lens)
        #expect(map.lensProfile == nil && map.lensDistortion == 0 && map.isIdentity)
        #expect(!GeometryMap(recipe: on, imageSize: size, lens: lens).isIdentity)
    }

    @Test func `Tone Curve off renders the parametric sliders and the point curve flat`() {
        var recipe = EditRecipe()
        recipe[.curveLights] = 40
        recipe[.curveSplitMidtones] = 60
        recipe.pointCurve = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)]
        recipe.setPanel(.toneCurve, on: false)
        let rendered = recipe.rendered
        #expect(rendered[.curveLights] == 0)
        #expect(rendered[.curveSplitMidtones] == 50)
        #expect(!rendered.hasPointCurve)
        #expect(recipe.hasPointCurve)
    }

    @Test func `Color Mixer off renders no bands and no Point Color on the edit, masks' kept`() {
        var recipe = EditRecipe()
        recipe[.hueRed] = 20
        recipe.pointColor = [PointColorSwatch(color: .oklch(OKLCh(lightness: 0.5, chroma: 0.1, hue: 30)))]
        var mask = MaskLayer(name: "Mask", components: [])
        mask.pointColor = recipe.pointColor
        recipe.masks = [mask]
        recipe.setPanel(.colorMixer, on: false)
        let rendered = recipe.rendered
        #expect(rendered[.hueRed] == 0)
        #expect(rendered.pointColor.isEmpty)
        #expect(rendered.masks == recipe.masks)
    }

    @Test func `every other panel off renders each of its settings at rest`() {
        var recipe = EditRecipe()
        for panel in [SwitchablePanel.colorGrading, .transform, .effects, .calibration] {
            for parameter in panel.parameters {
                let spec = parameter.spec
                recipe[parameter] = spec.clamp(spec.defaultValue + (spec.range.upperBound - spec.range.lowerBound) / 4)
            }
            recipe.setPanel(panel, on: false)
        }
        recipe[.exposure] = 1
        recipe.crop = CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9)
        let rendered = recipe.rendered
        for panel in [SwitchablePanel.colorGrading, .transform, .effects, .calibration] {
            for parameter in panel.parameters {
                #expect(rendered.isDefault(parameter), "\(parameter)")
            }
        }
        #expect(rendered[.exposure] == 1 && rendered.crop == recipe.crop, "Basic and the crop are never affected")
    }

    @Test func `every global parameter of a panel but Basic has a switch`() {
        let held = SwitchablePanel.allCases.flatMap(\.parameters)
        #expect(Set(held).count == held.count, "a parameter in two panels")
        for parameter in held {
            #expect(SwitchablePanel(holding: parameter) != nil)
            #expect(!parameter.isMaskScoped && !parameter.isSpotScoped && !parameter.isPointColorScoped)
        }
        #expect(SwitchablePanel(holding: .exposure) == nil && SwitchablePanel(holding: .cropAngle) == nil)
    }

    @Test func `changing a setting of a panel that's off turns it back on`() {
        var recipe = EditRecipe()
        recipe.panelsOff = [.detail, .toneCurve, .colorMixer, .lens]
        recipe[.sharpenAmount] = 40
        #expect(!recipe.isOn(.detail), "setting the same value isn't a change")
        recipe[.sharpenAmount] = 60
        #expect(recipe.isOn(.detail))
        recipe.pointCurve = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)]
        #expect(recipe.isOn(.toneCurve))
        recipe.pointColor = [PointColorSwatch(color: .oklch(OKLCh(lightness: 0.5, chroma: 0.1, hue: 30)))]
        #expect(recipe.isOn(.colorMixer))
        recipe[.exposure] = 1
        #expect(!recipe.isOn(.lens))
        recipe.reset([.lensProfile])
        #expect(!recipe.isOn(.lens), "resetting a setting at its default isn't a change")
        recipe[.lensProfile] = 0
        recipe.setPanel(.lens, on: false)
        recipe.reset([.lensProfile])
        #expect(recipe.isOn(.lens))
    }

    @Test func `switched-off panels round trip, and are absent when every panel is on`() throws {
        var recipe = EditRecipe()
        recipe[.sharpenAmount] = 70
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any]
        #expect(plain?["panelsOff"] == nil)

        recipe.panelsOff = [.lens, .detail]
        let data = try JSONEncoder().encode(recipe)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["panelsOff"] as? [String] == ["detail", "lens"], "in panel order")
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        #expect(decoded == recipe)
        #expect(!decoded.isOn(.detail) && decoded[.sharpenAmount] == 70)
        #expect(!decoded.isPristine)
    }

    @Test func `a sidecar without the field has every panel on`() throws {
        let json = #"{"version":3,"processVersion":14,"values":{"detail.sharpen.amount":70}}"#
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(decoded.panelsOff.isEmpty)
        #expect(decoded.rendered == decoded)
    }

    @Test func `a panel a newer Redlamp switched off is written back unchanged`() throws {
        let json = #"{"version":3,"processVersion":14,"values":{},"panelsOff":["basic","effects"]}"#
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(decoded.panelsOff == [.effects])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        #expect(object?["panelsOff"] as? [String] == ["effects", "basic"])
    }
}

struct PanelSwitchPasteTests {
    /// The source's switch for a panel travels with any of that panel's settings, so what was
    /// copied looks the same on the target.
    @Test func `pasting a panel's settings brings its switch`() {
        var source = EditRecipe()
        source[.sharpenAmount] = 90
        source.setPanel(.detail, on: false)
        var target = EditRecipe()
        target[.noiseLuminance] = 20
        target[.grainAmount] = 30
        let pasted = target.pasting(source, SettingsSelection(items: ["detail.sharpening"]))
        #expect(pasted[.sharpenAmount] == 90)
        #expect(!pasted.isOn(.detail), "the source's Detail is off, so the target's is")
        #expect(pasted[.noiseLuminance] == 20)
        #expect(pasted.rendered[.sharpenAmount] == source.rendered[.sharpenAmount])

        var off = EditRecipe()
        off.panelsOff = [.detail, .effects]
        let turnedOn = off.pasting(EditRecipe(), SettingsSelection(items: ["detail.noise"]))
        #expect(turnedOn.isOn(.detail), "the source's Detail is on")
        #expect(!turnedOn.isOn(.effects), "nothing of Effects was pasted")
    }

    @Test func `an item outside the switchable panels brings no switch`() {
        var source = EditRecipe()
        source.panelsOff = [.calibration]
        var target = EditRecipe()
        target.processVersion = 5
        let pasted = target.pasting(source, SettingsSelection(items: ["calibration.processVersion", "basic.exposure"]))
        #expect(pasted.isOn(.calibration))
        #expect(SettingsGroup.allItems.first { $0.id == "calibration.processVersion" }?.panel == nil)
        #expect(SettingsGroup.allItems.first { $0.id == "toneCurve.point" }?.panel == .toneCurve)
        #expect(SettingsGroup.allItems.first { $0.id == "colorMixer.pointColor" }?.panel == .colorMixer)
        #expect(SettingsGroup.allItems.first { $0.id == "effects.camera" }?.panel == .effects)
    }

    /// Auto Sync of a toggle switches the targets' panel and leaves their settings alone.
    @Test func `a switch's change syncs alone`() {
        var before = EditRecipe()
        before[.sharpenAmount] = 90
        var after = before
        after.setPanel(.detail, on: false)
        let changes = SettingsSelection.changes(from: before, to: after)
        #expect(changes.items.isEmpty && changes.panelSwitches == [.detail] && !changes.isEmpty)

        var target = EditRecipe()
        target[.sharpenAmount] = 20
        let synced = target.pasting(after, changes)
        #expect(!synced.isOn(.detail) && synced[.sharpenAmount] == 20)
        let back = synced.pasting(before, SettingsSelection.changes(from: after, to: before))
        #expect(back.isOn(.detail))
        #expect(changes.union(SettingsSelection(items: [])).panelSwitches == [.detail])
    }
}
