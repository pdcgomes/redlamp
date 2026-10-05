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

    @Test func `each of Point Color's sliders belongs to its own feedback feature`() {
        for parameter in ParameterID.pointColorParameters {
            #expect(FeedbackArea.featureID(for: parameter) == "develop.point-color")
        }
    }
}
