import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// Point Color's editing (TON-29): the eyedropper's swatches, the selected swatch's sliders and
/// their history, Visualize Range, and delete.
@MainActor
struct PointColorEditingTests {
    private let engine = StubEngine()

    private func openModel() async throws -> EditorModel {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info != nil)
        return model
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits for what the engine reports off the main thread, such as its AI masks (RESP-15),
    /// which can take seconds on a busy Mac.
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private let skin = OKLCh(lightness: 0.7, chroma: 0.08, hue: 55)
    private let sky = OKLCh(lightness: 0.6, chroma: 0.1, hue: 240)

    @Test func `the eyedropper adds a swatch of the colour it samples, selected`() async throws {
        let model = try await openModel()
        model.pointColorEyedropperActive = true
        model.samplePointColor(at: CGPoint(x: 0.4, y: 0.5))
        try await waitFor { !model.recipe.pointColor.isEmpty }

        let swatch = try #require(model.recipe.pointColor.first)
        #expect(swatch.color == .oklch(skin))
        #expect(swatch.picked?.center == ImagePoint(x: 0.4, y: 0.5))
        #expect(swatch.isNeutral)
        #expect(model.selectedPointColorSwatch?.id == swatch.id)
        #expect(!model.pointColorEyedropperActive)
        #expect(model.history.last?.name == "Add Point Color Swatch")
    }

    @Test func `the eyedroppers turn each other off`() async throws {
        let model = try await openModel()
        model.eyedropperActive = true
        model.pointColorEyedropperActive = true
        #expect(!model.eyedropperActive)
        model.eyedropperActive = true
        #expect(!model.pointColorEyedropperActive)
    }

    @Test func `the sliders edit the selected swatch, each change a step of its own`() async throws {
        let model = try await openModel()
        model.addPointColorSwatch(skin)
        model.addPointColorSwatch(sky)
        let first = model.recipe.pointColor[0].id
        model.selectedPointColorSwatchID = first

        model.setSliderValue(.pointColorHueUniformity, 60)
        #expect(model.sliderValue(.pointColorHueUniformity) == 60)
        #expect(model.recipe.pointColor[0][.pointColorHueUniformity] == 60)
        #expect(model.recipe.pointColor[1].isNeutral)
        #expect(model.history.last?.name == "Point Color Hue Uniformity: 0 → +60")

        model.setSliderValue(.pointColorLuminanceShift, -20)
        #expect(model.recipe.pointColor[0][.pointColorLuminanceShift] == -20)
        #expect(model.history.last?.name == "Point Color Luminance Shift: 0 → -20")

        model.resetSlider(.pointColorHueUniformity)
        #expect(model.recipe.pointColor[0][.pointColorHueUniformity] == 0)

        model.undo()
        #expect(model.recipe.pointColor[0][.pointColorHueUniformity] == 60)
    }

    @Test func `a drag is one step, and without a swatch the sliders do nothing`() async throws {
        let model = try await openModel()
        model.setSliderValue(.pointColorHueShift, 30)
        #expect(model.recipe.pointColor.isEmpty)
        #expect(model.sliderValue(.pointColorHueShift) == 0)

        model.addPointColorSwatch(skin)
        let steps = model.history.count
        model.beginEdit(.pointColorSaturationUniformity)
        for value in stride(from: 5.0, through: 40, by: 5) {
            model.setSliderValue(.pointColorSaturationUniformity, value)
        }
        model.endEdit()
        #expect(model.recipe.pointColor[0][.pointColorSaturationUniformity] == 40)
        #expect(model.history.count == steps + 1)
        #expect(model.history.last?.name == "Point Color Saturation Uniformity: 0 → +40")
    }

    @Test func `a group header resets its sliders on the selected swatch`() async throws {
        let model = try await openModel()
        model.addPointColorSwatch(skin)
        for parameter in [ParameterID.pointColorHueShift, .pointColorSaturationShift, .pointColorHueRange] {
            model.setSliderValue(parameter, 30)
        }
        model.resetParameters(
            [.pointColorHueShift, .pointColorSaturationShift, .pointColorLuminanceShift],
            name: "Reset Shift",
        )
        let swatch = model.recipe.pointColor[0]
        #expect(swatch[.pointColorHueShift] == 0)
        #expect(swatch[.pointColorSaturationShift] == 0)
        #expect(swatch[.pointColorHueRange] == 30)
        #expect(model.history.last?.name == "Reset Shift")
    }

    @Test func `with eight swatches, the eyedropper picks the selected one's colour again`() async throws {
        let model = try await openModel()
        for _ in 0 ..< PointColorSwatch.maximumSwatches {
            model.addPointColorSwatch(sky)
        }
        let selected = model.recipe.pointColor[2].id
        model.selectedPointColorSwatchID = selected

        model.samplePointColor(at: CGPoint(x: 0.5, y: 0.5))
        try await waitFor { model.recipe.pointColor[2].color == .oklch(skin) }
        #expect(model.recipe.pointColor.count == PointColorSwatch.maximumSwatches)
        #expect(model.recipe.pointColor[2].id == selected)
        #expect(model.recipe.pointColor[2].color == .oklch(skin))
        #expect(model.history.last?.name == "Pick Point Color")
    }

    @Test func `deleting the selected swatch moves the sliders to the newest left`() async throws {
        let model = try await openModel()
        model.addPointColorSwatch(skin)
        model.addPointColorSwatch(sky)
        let (first, second) = (model.recipe.pointColor[0].id, model.recipe.pointColor[1].id)
        model.selectedPointColorSwatchID = first

        model.deletePointColorSwatch(first)
        #expect(model.recipe.pointColor.map(\.id) == [second])
        #expect(model.selectedPointColorSwatch?.id == second)
        #expect(model.history.last?.name == "Delete Point Color Swatch")

        model.undo()
        #expect(model.recipe.pointColor.map(\.id) == [first, second])
        #expect(model.selectedPointColorSwatch?.id == first)
    }

    @Test func `the Visualize Range shows the selected swatch, until the mode is left`() async throws {
        let model = try await openModel()
        model.addPointColorSwatch(skin)
        model.addPointColorSwatch(sky)
        let first = model.recipe.pointColor[0].id
        model.selectedPointColorSwatchID = first

        model.visualizePointColorRange = true
        try await waitFor { engine.lastRender?.visualizePointColor == first }
        #expect(engine.lastRender?.visualizePointColor == first)

        model.leavePointColor()
        try await waitFor { engine.lastRender?.visualizePointColor == nil }
        #expect(engine.lastRender?.visualizePointColor == nil)
        #expect(!model.visualizePointColorRange)
    }

    // MARK: - Masks

    private func openWithMask() async throws -> (EditorModel, UUID) {
        let model = try await openModel()
        model.activeTool = .masking
        model.startDrawing(.radial)
        model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)))
        model.finishDrawing()
        return try (model, #require(model.selectedMaskID))
    }

    @Test func `in the Masking tool, Point Color edits the selected mask's swatches`() async throws {
        let (model, mask) = try await openWithMask()
        #expect(model.pointColorTarget == .mask(mask))
        model.addPointColorSwatch(skin)
        model.setSliderValue(.pointColorHueUniformity, 60)

        let swatches = try #require(model.recipe.mask(mask)?.pointColor)
        #expect(swatches.count == 1 && swatches[0][.pointColorHueUniformity] == 60)
        #expect(model.recipe.pointColor.isEmpty, "the edit's own swatches are untouched")
        let name = try #require(model.recipe.mask(mask)?.name)
        #expect(model.history.last?.name == "\(name) Point Color Hue Uniformity: 0 → +60")

        model.activeTool = .edit
        #expect(model.pointColorTarget == .edit && model.selectedPointColorSwatch == nil)
        #expect(model.sliderValue(.pointColorHueUniformity) == 0)
    }

    @Test func `a mask's own colour is a swatch only a mask can have`() async throws {
        let (model, mask) = try await openWithMask()
        model.addMaskColorSwatch()
        #expect(model.recipe.mask(mask)?.pointColor.map(\.color) == [.mask])
        #expect(model.history.last?.name == "Add Point Color Swatch")

        model.activeTool = .edit
        model.addMaskColorSwatch()
        #expect(model.recipe.pointColor.isEmpty)
    }

    @Test func `leaving the Masking tool ends Point Color's eyedropper and Visualize Range`() async throws {
        let (model, _) = try await openWithMask()
        model.addPointColorSwatch(skin)
        model.visualizePointColorRange = true
        model.pointColorEyedropperActive = true
        model.activeTool = .edit
        #expect(!model.visualizePointColorRange && !model.pointColorEyedropperActive)
    }

    @Test func `the Even Skin Tone preset masks the skin, with a swatch of its own colour`() async throws {
        engine.computed = [AIMask(
            kind: .people, provider: "stub", revision: 1, analysisHash: "h", center: ImagePoint(x: 0.5, y: 0.4),
            bitmap: MaskBitmap(sha256: "s", width: 4, height: 4),
        )]
        let model = try await openModel()
        let preset = try #require(MaskPreset.builtIn.first { $0.id == "redlamp.evenSkinTone" })
        try await eventually { model.canApply(preset) }
        #expect(model.canApply(preset))
        await model.applyMaskPreset(preset)
        let mask = try #require(model.masks.last)
        #expect(mask.name == "Even Skin Tone" && mask.components.count == 2, "Face Skin and Body Skin")
        let swatch = try #require(mask.pointColor.first)
        #expect(swatch.color == .mask && swatch[.pointColorHueUniformity] == 50)
        #expect(swatch.id != preset.pointColor?.first?.id, "a swatch of its own")

        engine.missingParts = [.bodySkin]
        await model.applyMaskPreset(preset)
        #expect(model.masks.count == 2 && model.masks.last?.components.count == 1, "Face Skin alone without SAM 3")
        #expect(model.maskMessage == nil)
    }

    @Test func `choosing another mask ends Point Color's eyedropper`() async throws {
        let (model, _) = try await openWithMask()
        model.pointColorEyedropperActive = true
        model.selectedMaskID = nil
        #expect(!model.pointColorEyedropperActive)
    }

    @Test func `a duplicated mask's swatches are its own`() async throws {
        let (model, mask) = try await openWithMask()
        model.addPointColorSwatch(skin)
        model.duplicateMask(mask)
        let copy = try #require(model.masks.last)
        let original = try #require(model.recipe.mask(mask)?.pointColor.first)
        #expect(copy.id != mask && copy.pointColor.count == 1)
        #expect(copy.pointColor.first?.id != original.id && copy.pointColor.first?.color == original.color)
    }

    @Test func `a mask preset keeps the mask's swatches`() async throws {
        let (model, mask) = try await openWithMask()
        model.addPointColorSwatch(skin)
        model.setSliderValue(.pointColorSaturationUniformity, 25)
        let saved = try MaskPreset(#require(model.recipe.mask(mask)), name: "Mine")
        let decoded = try JSONDecoder().decode(MaskPreset.self, from: JSONEncoder().encode(saved))
        #expect(decoded.pointColor?.first?[.pointColorSaturationUniformity] == 25)
        let old = try JSONDecoder().decode(MaskPreset.self, from: Data(#"""
        {"id": "x", "name": "Old", "components": [], "amount": 100, "detail": 0, "adjustments": {}}
        """#.utf8))
        #expect(old.pointColor == nil && old.newSwatches.isEmpty, "presets saved before Point Color still read")
    }

    @Test func `each of Point Color's sliders belongs to its own feedback feature`() {
        for parameter in ParameterID.pointColorParameters {
            #expect(FeedbackArea.featureID(for: parameter) == "develop.point-color")
        }
    }
}
