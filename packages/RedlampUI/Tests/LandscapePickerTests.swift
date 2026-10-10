import Foundation
import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// The Landscape picker (UX-26): the regions SAM 3 finds in the photo, with their share of it,
/// and which of them become masks.
@MainActor
struct LandscapePickerTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    /// A photo of water, vegetation and mountains, with Landscape available.
    private func landscape(_ engine: StubEngine = StubEngine()) async throws -> (EditorModel, StubEngine) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        engine.availableKinds.insert(.landscape)
        engine.regions = [
            LandscapeFound(landscape: .water, share: 0.2),
            LandscapeFound(landscape: .vegetation, share: 0.35),
            LandscapeFound(landscape: .mountains, share: 0.15),
        ]
        engine.computed = [AIMask(
            kind: .landscape, provider: "stub", revision: 1, analysisHash: "h", center: ImagePoint(x: 0.5, y: 0.5),
            bitmap: MaskBitmap(sha256: "l", width: 4, height: 4),
        )]
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0004.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info != nil)
        return (model, engine)
    }

    private func open(_ model: EditorModel, _ mode: MaskPickerMode = .new) async throws {
        model.openLandscapePicker(mode)
        for _ in 0 ..< 200 where model.landscapePicker?.regions == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.landscapePicker?.regions != nil)
    }

    private func drawRadial(in model: EditorModel) throws -> UUID {
        model.startDrawing(.radial)
        model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)))
        model.finishDrawing()
        return try #require(model.recipe.masks.first?.id)
    }

    /// The Landscape class each of the mask's components was made for.
    private func classes(_ mask: MaskLayer?) -> [LandscapeClass] {
        (mask?.components ?? []).compactMap { component in
            if case let .ai(ai) = component.shape {
                ai.part.flatMap(LandscapeClass.init(rawValue:))
            } else {
                nil
            }
        }
    }

    @Test func `the picker lists the regions found with their share of the photo, none ticked`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _) = try await landscape()
        try await open(model)
        let picker = try #require(model.landscapePicker)
        #expect(picker.regions?.map(\.landscape) == [.water, .vegetation, .mountains])
        #expect(picker.chosen.isEmpty)
        #expect(!picker.canCreate)
        #expect(model.activeTool == .masking)
        #expect(LandscapePickerView.share(0.346) == "35%")
        #expect(LandscapePickerView.share(0.004) == "<1%")
    }

    @Test func `a region alone in the photo starts ticked`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, engine) = try await landscape()
        engine.regions = [LandscapeFound(landscape: .water, share: 0.6)]
        try await open(model)
        #expect(model.landscapePicker?.chosen == [.water])
    }

    @Test func `regions ticked make one mask with a component for each`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, engine) = try await landscape()
        try await open(model)
        model.toggleLandscape(.vegetation)
        model.toggleLandscape(.water)
        await model.createLandscapeMasks()
        #expect(engine.requests.suffix(2).map(\.landscape) == [.water, .vegetation])
        #expect(model.recipe.masks.map(\.name) == ["Landscape"])
        #expect(classes(model.recipe.masks.first) == [.water, .vegetation])
        #expect(model.recipe.masks.first?.components.allSatisfy { $0.operation == .add } == true)
        #expect(model.history.last?.name == "New Landscape")
        #expect(model.landscapePicker == nil)
    }

    @Test func `one region ticked makes a mask named for it`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _) = try await landscape()
        try await open(model)
        model.toggleLandscape(.mountains)
        await model.createLandscapeMasks()
        #expect(model.recipe.masks.map(\.name) == ["Mountains"])
        #expect(model.history.last?.name == "New Mountains")
    }

    @Test func `separate masks make one for each region ticked, in one step`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _) = try await landscape()
        try await open(model)
        model.toggleLandscape(.water)
        model.toggleLandscape(.vegetation)
        model.setLandscapeSeparate(true)
        let steps = model.history.count
        await model.createLandscapeMasks()
        #expect(model.recipe.masks.map(\.name) == ["Water", "Vegetation"])
        #expect(model.recipe.masks.map { classes($0) } == [[.water], [.vegetation]])
        #expect(model.history.count == steps + 1)
        #expect(model.history.last?.name == "New Landscape Masks")
    }

    @Test func `the picker adds regions to a mask, and subtracts every one ticked`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _) = try await landscape()
        let target = try drawRadial(in: model)
        try await open(model, .component(.add, target: target))
        model.toggleLandscape(.water)
        await model.createLandscapeMasks()
        #expect(model.recipe.masks.count == 1)
        #expect(model.recipe.masks.first?.components.last?.operation == .add)
        #expect(model.history.last?.name == "Add Water")

        try await open(model, .component(.subtract, target: target))
        model.toggleLandscape(.vegetation)
        model.toggleLandscape(.mountains)
        await model.createLandscapeMasks()
        let subtracted = try #require(model.recipe.masks.first?.components.suffix(2))
        #expect(subtracted.allSatisfy { $0.operation == .subtract })
        #expect(model.history.last?.name == "Subtract Landscape")
        #expect(model.selectedMaskID == target)
    }

    @Test func `the picker intersects a mask with one region at a time`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _) = try await landscape()
        let target = try drawRadial(in: model)
        try await open(model, .component(.intersect, target: target))
        model.toggleLandscape(.water)
        model.toggleLandscape(.vegetation)
        #expect(model.landscapePicker?.canCreate == false)
        await model.createLandscapeMasks()
        #expect(model.recipe.masks.first?.components.count == 1, "nothing intersected")
        model.toggleLandscape(.vegetation)
        await model.createLandscapeMasks()
        #expect(model.recipe.masks.first?.components.count == 2)
        #expect(model.recipe.masks.first?.components.last?.operation == .intersect)
    }

    @Test func `a region that can't be made is named, and the rest are made`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, engine) = try await landscape()
        engine.missingLandscapes = [.vegetation]
        try await open(model)
        model.toggleLandscape(.water)
        model.toggleLandscape(.vegetation)
        await model.createLandscapeMasks()
        #expect(model.recipe.masks.map(\.name) == ["Water"])
        #expect(model.maskMessage == "Not found: Vegetation.")
    }

    @Test func `with no regions found the picker says so and makes nothing`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, engine) = try await landscape()
        engine.regions = []
        try await open(model)
        #expect(model.landscapePicker?.regions == [])
        await model.createLandscapeMasks()
        #expect(model.recipe.masks.isEmpty)
    }

    @Test func `Esc closes the picker before it leaves the Masking tool`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _) = try await landscape()
        try await open(model)
        #expect(model.perform(.cancel))
        #expect(model.landscapePicker == nil)
        #expect(model.activeTool == .masking, "the first Esc closes the picker")
    }

    @Test func `opening another photo, or the People picker, closes it`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _) = try await landscape()
        try await open(model)
        model.openPeoplePicker(.new)
        #expect(model.landscapePicker == nil)
        #expect(model.peoplePicker != nil)
        try await open(model)
        #expect(model.peoplePicker == nil, "and the other way round")
        let other = folder.appending(path: "IMG_0005.ARW")
        model.select(other)
        for _ in 0 ..< 400 where model.info?.url != other {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info?.url == other)
        #expect(model.landscapePicker == nil)
    }

    /// App Review 4.2.3: nothing downloads without consent.
    @Test func `Landscape asks for SAM 3 first, and opens the picker once it's downloaded`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        engine.neededModel = ModelInfo(
            id: "sam3", name: "SAM 3", purpose: "Landscape", downloadBytes: 1, state: .notDownloaded,
        )
        engine.kindsNeedingModel = [.landscape]
        let (model, _) = try await landscape(engine)
        await model.startAIMask(.landscape)
        #expect(model.pendingModel?.kind == .landscape)
        #expect(model.landscapePicker == nil)
        await model.downloadPendingModel()
        #expect(engine.downloaded == ["sam3"])
        #expect(model.landscapePicker?.mode == .new)
    }
}
