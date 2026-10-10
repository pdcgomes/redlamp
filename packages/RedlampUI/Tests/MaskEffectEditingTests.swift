import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The Masks panel's Effect menu (UX-27) as the model has it: choosing an effect, what the menu
/// shows, and the user's own effects, saved and deleted in a defaults suite of the test's own.
@MainActor
struct MaskEffectEditingTests {
    /// An editor with a photo open, in a temporary folder its sidecar can be written to, keeping the
    /// user's effects in `defaults`.
    private func openEditor() async throws -> (EditorModel, UserDefaults, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "MaskEffectEditingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = EditorModel(engine: StubEngine())
        model.maskEffectStore = MaskEffectStore(defaults: defaults)
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info != nil)
        model.activeTool = .masking
        return (model, defaults, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        })
    }

    private func drawMask(_ model: EditorModel, at x: Double = 0.5) throws -> UUID {
        model.startDrawing(.radial)
        model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: x, y: 0.5), radiusX: 0.1, radiusY: 0.1)))
        model.finishDrawing()
        return try #require(model.selectedMaskID)
    }

    private func builtIn(_ name: String) throws -> MaskEffect {
        try #require(MaskEffect.builtIn.first { $0.name == name })
    }

    @Test func `choosing an effect sets the mask's sliders as one step, which Undo takes back`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        let mask = try drawMask(model)
        let name = try #require(model.recipe.mask(mask)?.name)
        model.setMaskValue(.localClarity, 30)
        let steps = model.history.count

        try model.applyMaskEffect(builtIn("Whiten Teeth"), to: mask)
        #expect(model.sliderValue(.localExposure) == 0.25)
        #expect(model.sliderValue(.localSaturation) == -45)
        #expect(model.sliderValue(.localClarity) == 0, "the effect doesn't set Clarity")
        #expect(model.history.count == steps + 1)
        #expect(model.history.last?.title == "Apply Whiten Teeth to \(name)")

        model.undo()
        #expect(model.sliderValue(.localClarity) == 30 && model.sliderValue(.localExposure) == 0)
        try model.applyMaskEffect(builtIn("Whiten Teeth"), to: mask)
        let applied = model.history.count
        try model.applyMaskEffect(builtIn("Whiten Teeth"), to: mask)
        #expect(model.history.count == applied, "choosing the effect the mask has adds no step")
    }

    @Test func `the menu shows the effect a mask has, Custom once its settings are its own, or None`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        let mask = try drawMask(model)
        #expect(model.effectTitle(of: mask) == "None")
        #expect(model.maskEffect(of: mask) == nil)

        try model.applyMaskEffect(builtIn("Burn"), to: mask)
        #expect(model.effectTitle(of: mask) == "Burn")
        model.setMaskValue(.localExposure, -0.5)
        #expect(model.effectTitle(of: mask) == "Custom")
        model.setMaskValue(.localExposure, -0.35)
        #expect(model.effectTitle(of: mask) == "Burn", "back on the effect's values")
        model.setMaskCurve(.rgb, [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)])
        #expect(model.effectTitle(of: mask) == "Custom", "the curves are part of the effect")
        model.resetMaskAdjustments(mask)
        #expect(model.effectTitle(of: mask) == "None")
    }

    @Test func `an effect saved from a mask sets another mask to it, and is kept for the next launch`() async throws {
        let (model, defaults, cleanup) = try await openEditor()
        defer { cleanup() }
        let first = try drawMask(model, at: 0.3)
        model.setMaskValue(.localExposure, 0.5)
        model.setMaskValue(.localTexture, 12)
        model.setMaskCurve(.red, [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 1)])
        model.saveMaskEffect(from: first, name: "  Glow ")
        let glow = try #require(model.userMaskEffects.first)
        #expect(model.userMaskEffects.count == 1 && glow.name == "Glow")
        #expect(model.maskEffects.last == glow, "after Redlamp's own")
        #expect(model.effectTitle(of: first) == "Glow")

        let second = try drawMask(model, at: 0.7)
        model.applyMaskEffect(glow, to: second)
        #expect(model.recipe.mask(second)?.adjustments == model.recipe.mask(first)?.adjustments)
        #expect(model.recipe.mask(second)?.curves == model.recipe.mask(first)?.curves)
        #expect(model.effectTitle(of: second) == "Glow")

        let relaunched = MaskEffectStore(defaults: defaults)
        #expect(relaunched.effects == [glow])
        defaults.set(Data("not effects".utf8), forKey: "app.redlamp.maskEffects")
        #expect(MaskEffectStore(defaults: defaults).effects.isEmpty, "unreadable")
    }

    @Test func `saving under a name kept already replaces that effect, and a blank name is the mask's`() async throws {
        let (model, defaults, cleanup) = try await openEditor()
        defer { cleanup() }
        let first = try drawMask(model, at: 0.3)
        model.setMaskValue(.localExposure, 0.5)
        model.saveMaskEffect(from: first, name: "Glow")
        let second = try drawMask(model, at: 0.7)
        model.setMaskValue(.localExposure, 1)
        model.saveMaskEffect(from: second, name: "Glow")
        #expect(model.userMaskEffects.map(\.name) == ["Glow"])
        #expect(model.userMaskEffects.first?.localAdjustments == [.localExposure: 1])
        #expect(model.effectTitle(of: first) == "Custom", "the first mask keeps the values it had")

        model.saveMaskEffect(from: second, name: " ")
        let name = try #require(model.recipe.mask(second)?.name)
        #expect(model.userMaskEffects.map(\.name) == ["Glow", name])

        let replaced = try #require(model.userMaskEffects.first)
        model.deleteMaskEffect(replaced.id)
        #expect(model.userMaskEffects.map(\.name) == [name])
        #expect(MaskEffectStore(defaults: defaults).effects.map(\.name) == [name], "deleted for the next launch too")
        #expect(model.effectTitle(of: second) == name)
    }
}
