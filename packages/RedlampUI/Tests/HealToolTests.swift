import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The Healing tool (RM-01).
@MainActor
struct HealToolTests {
    private func openEditor(_ engine: StubEngine = StubEngine()) async throws -> (EditorModel, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info != nil)
        return (model, { try? FileManager.default.removeItem(at: folder) })
    }

    @Test func `a click adds a spot copying from the source the engine finds`() async throws {
        let engine = StubEngine()
        engine.retouchSource = ImagePoint(x: 0.3, y: 0.42)
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        #expect(model.perform(.healTool))
        #expect(model.activeTool == .heal)
        model.setSliderValue(.spotSize, 40)
        await model.addSpot(at: ImagePoint(x: 0.5, y: 0.4))
        let spot = try #require(model.recipe.spots.first)
        #expect(spot.mode == .heal && spot.source == ImagePoint(x: 0.3, y: 0.42))
        #expect(abs(spot.radius - RetouchSpot.radius(size: 40)) < 1e-12)
        #expect(model.selectedSpotID == spot.id)
        #expect(model.history.last?.name == "Heal")
        #expect(abs(model.sliderValue(.spotSize) - 40) < 1e-9)
    }

    @Test func `with no source found, a spot copies from beside itself, inside the photo`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.activeTool = .heal
        model.setSpotMode(.clone)
        await model.addSpot(at: ImagePoint(x: 0.995, y: 0.5))
        let spot = try #require(model.recipe.spots.first)
        #expect(spot.mode == .clone)
        #expect(spot.source.x < spot.center.x && spot.source.y == spot.center.y, "at the right edge, to the left")
        #expect(model.history.last?.name == "Clone")
    }

    @Test func `a drag brushes a spot that follows the stroke`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.activeTool = .heal
        let points = (0 ... 40).map { ImagePoint(x: 0.3 + Double($0) * 0.005, y: 0.4) }
        await model.addStroke(points)
        let spot = try #require(model.recipe.spots.first)
        #expect(spot.center == points[0])
        #expect(spot.stroke.count > 4 && spot.stroke.count < points.count, "thinned to a quarter brush apart")
        let end = try #require(spot.points().last)
        #expect(abs(end.x - 0.5) < 0.02 && end.y == 0.4)
        #expect(spot.source.y > 0.4 + spot.radius * 2, "no source found: below the stroke")
        #expect(model.history.last?.name == "Heal Brush")

        // A stroke that barely moves is a click.
        await model.addStroke([ImagePoint(x: 0.7, y: 0.7), ImagePoint(x: 0.7001, y: 0.7)])
        #expect(model.recipe.spots.last?.stroke.isEmpty == true)
    }

    @Test func `Remove Dust heals every speck found, in one step`() async throws {
        let engine = StubEngine()
        engine.dust = [
            DetectedSpot(center: ImagePoint(x: 0.2, y: 0.2), radius: 0.01, strength: 30),
            DetectedSpot(center: ImagePoint(x: 0.7, y: 0.3), radius: 0.02, strength: 12),
        ]
        engine.retouchSource = ImagePoint(x: 0.5, y: 0.5)
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        model.activeTool = .heal
        let steps = model.history.count
        await model.removeDust()
        #expect(model.recipe.spots.map(\.center) == engine.dust.map(\.center))
        #expect(model.recipe.spots.allSatisfy { $0.mode == .heal && $0.source == ImagePoint(x: 0.5, y: 0.5) })
        #expect(model.recipe.spots.map(\.radius) == [0.01, 0.02])
        #expect(model.history.count == steps + 1 && model.history.last?.name == "Remove Dust")
        #expect(model.dustMessage == "Healed 2 specks of dust.")
        engine.dust = []
        await model.removeDust()
        #expect(model.dustMessage == "No dust found." && model.recipe.spots.count == 2)
        model.activeTool = .edit
        #expect(model.dustMessage == nil)
    }

    @Test func `Visualize Spots shows in the Healing tool only`() async throws {
        let engine = StubEngine()
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        model.activeTool = .heal
        model.visualizeSpots = true
        #expect(engine.lastRender?.visualizeSpots == 50)
        model.setSliderValue(.spotVisualize, 80)
        #expect(engine.lastRender?.visualizeSpots == 80)
        #expect(model.recipe[.spotVisualize] == 50, "a tool setting, never in the edit")
        model.activeTool = .edit
        #expect(engine.lastRender?.visualizeSpots == nil)
    }

    @Test func `the sliders change the selected spot, and the next one`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.activeTool = .heal
        await model.addSpot(at: ImagePoint(x: 0.5, y: 0.5))
        model.setSliderValue(.spotOpacity, 60)
        #expect(model.recipe.spots[0].opacity == 60)
        #expect(model.history.last?.name == "Spot Opacity")
        model.selectedSpotID = nil
        #expect(model.sliderValue(.spotOpacity) == 60, "the next spot's too")
        model.resetSlider(.spotOpacity)
        #expect(model.recipe.spots[0].opacity == 60, "nothing selected: only the next spot's")
        #expect(model.sliderValue(.spotOpacity) == 100)
        #expect(model.recipe[.spotOpacity] == ParameterID.spotOpacity.spec.defaultValue, "never in the edit")
    }

    @Test func `a drag is one step, and Delete removes the selected spot`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.activeTool = .heal
        await model.addSpot(at: ImagePoint(x: 0.5, y: 0.5))
        let id = try #require(model.selectedSpotID)
        let steps = model.history.count
        model.beginEdit()
        model.updateSpot(id) { $0.center = ImagePoint(x: 0.55, y: 0.5) }
        model.updateSpot(id) { $0.center = ImagePoint(x: 0.6, y: 0.5) }
        model.endEdit(.retouch, "Move Spot")
        #expect(model.history.count == steps + 1 && model.history.last?.name == "Move Spot")
        #expect(model.recipe.spots[0].center == ImagePoint(x: 0.6, y: 0.5))

        #expect(model.canPerform(.deleteMask))
        #expect(model.perform(.deleteMask))
        #expect(model.recipe.spots.isEmpty && model.selectedSpotID == nil)
        model.undo()
        #expect(model.recipe.spots.count == 1)
    }
}
