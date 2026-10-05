import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// Every brush is sized by `[` and `]` and ⌘-scroll while its tool is active, and Space pans in a
/// tool (UX-15).
@MainActor
struct BrushSizeTests {
    /// An editor with a photo open, in a temporary folder its sidecar can be written to.
    private func openEditor() async throws -> (EditorModel, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = EditorModel(engine: StubEngine())
        let brushes = model.brushes
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info != nil)
        return (model, {
            model.brushes = brushes
            try? FileManager.default.removeItem(at: folder)
        })
    }

    @Test func `brackets size the Healing brush and leave the rating alone`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.activeTool = .heal
        let rating = model.currentMetadata.rating
        let size = model.spotSettings.size

        #expect(model.perform(.increaseRating))
        #expect(model.spotSettings.size > size)
        model.perform(.decreaseRating, shifted: true)
        #expect(model.spotSettings.feather == ParameterID.spotFeather.spec.defaultValue - 10)
        #expect(model.currentMetadata.rating == rating)
    }

    @Test func `brackets resize the selected spot, as its Size slider does`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.activeTool = .heal
        await model.addSpot(at: ImagePoint(x: 0.5, y: 0.5))
        let spot = try #require(model.recipe.spots.first)
        model.selectedSpotID = spot.id

        model.perform(.increaseRating)
        #expect(try #require(model.recipe.spots.first).radius > spot.radius)
    }

    @Test func `without a brush tool the brackets still rate the photo`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let rating = model.currentMetadata.rating

        model.perform(.increaseRating)
        #expect(model.currentMetadata.rating == rating + 1)
        #expect(model.sizedBrush == nil)
    }

    @Test func `the mask brush sizes from the keys and from command-scroll`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.startDrawing(.brush)
        let rating = model.currentMetadata.rating
        let size = model.brushes[model.activeBrush].size

        model.perform(.increaseRating)
        let larger = model.brushes[model.activeBrush].size
        #expect(larger > size)
        #expect(model.scrollSizedBrush(by: -2, feather: false))
        #expect(model.brushes[model.activeBrush].size < larger)
        let feather = model.brushes[model.activeBrush].feather
        #expect(model.scrollSizedBrush(by: 1, feather: true))
        #expect(model.brushes[model.activeBrush].feather == min(feather + 5, 100))
        #expect(model.currentMetadata.rating == rating)
    }

    @Test func `command-scroll sizes the Healing brush but not the spots placed`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.activeTool = .heal
        await model.addSpot(at: ImagePoint(x: 0.5, y: 0.5))
        let spot = try #require(model.recipe.spots.first)
        model.selectedSpotID = spot.id
        let size = model.spotSettings.size

        #expect(model.scrollSizedBrush(by: 3, feather: false))
        #expect(model.spotSettings.size > size)
        #expect(model.recipe.spots.first?.radius == spot.radius)
    }

    @Test func `command-scroll is left to zooming when no brush is active`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        #expect(!model.scrollSizedBrush(by: 1, feather: false))
        model.activeTool = .crop
        #expect(!model.scrollSizedBrush(by: 1, feather: false))
    }

    @Test func `the Stack workspace's retouch brush sizes the same way`() {
        let workspace = StackWorkspaceModel(
            documentURL: URL(fileURLWithPath: "/tmp/stack.redlampstack"),
            engine: StubEngine(),
        )
        let radius = workspace.brushRadius
        workspace.nudgeBrush(direction: 1, hardness: false)
        #expect(workspace.brushRadius > radius)
        workspace.nudgeBrush(direction: 1, hardness: true)
        #expect(abs(workspace.brushHardness - 0.4) < 1e-9)
        workspace.scrollBrush(by: -100, hardness: false)
        #expect(workspace.brushRadius == 0.005)
    }

    @Test func `Space toggles the zoom in a tool only when the photo wasn't clicked`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        model.activeTool = .heal
        #expect(model.hasToolOverlay)
        let zoom = model.canvas.zoom

        model.beginSpacePan()
        #expect(model.isSpacePanning)
        model.endSpacePan()
        #expect(!model.isSpacePanning)
        #expect(model.canvas.zoom != zoom)

        let toggled = model.canvas.zoom
        model.beginSpacePan()
        model.noteSpacePanUse()
        model.endSpacePan()
        #expect(model.canvas.zoom == toggled)
    }
}
