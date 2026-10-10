import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// A mask preset with several photos selected (UX-25): the open photo gets it as a step of its
/// history, the others in the background, each one's AI masks made for it.
@MainActor
struct MaskPresetSelectionTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    private let a: URL
    private let b: URL
    private let c: URL
    private let store = SidecarStore()
    private let engine = StubEngine()
    private let worker = StubEngine()
    private let model: EditorModel
    private let blueSky = MaskPreset.builtIn.first { $0.id == "redlamp.blueSky" }!

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        (a, b, c) = (folder.appending(path: "A.ARW"), folder.appending(path: "B.ARW"), folder.appending(path: "C.ARW"))
        model = EditorModel(engine: engine)
        model.makeWorkerEngine = { [worker] in worker }
        [a, b, c].forEach { model.library.insert(LibraryItem(url: $0)) }
        engine.computed = [sky("editor")]
        worker.computed = [sky("worker")]
    }

    private func open(_ url: URL) async throws {
        model.select(url, keepingSelection: true)
        for _ in 0 ..< 2000 where model.info?.url != url || model.isLoading {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info?.url == url)
    }

    /// A open, with A, B and C selected.
    private func start() async throws {
        try await open(a)
        model.selectAllPhotos()
        try #require(model.isMultiSelecting)
    }

    private func sky(_ hash: String) -> AIMask {
        AIMask(
            kind: .sky, provider: "stub", revision: 1, analysisHash: hash,
            center: ImagePoint(x: 0.5, y: 0.3), bitmap: MaskBitmap(sha256: hash, width: 4, height: 4),
        )
    }

    /// The analysis each of `masks`' AI components was computed from.
    private func hashes(_ masks: [MaskLayer]?) -> [String] {
        (masks ?? []).flatMap(\.components).compactMap { component in
            if case let .ai(mask) = component.shape {
                mask.analysisHash
            } else {
                nil
            }
        }
    }

    @Test func `a preset reaches every selected photo, its AI masks made for each`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await start()
        await model.applyMaskPreset(blueSky)
        await model.settingsSync.idle()

        #expect(model.recipe.masks.map(\.name) == ["Blue Sky"])
        #expect(hashes(model.recipe.masks) == ["editor"], "A's sky is A's own")
        #expect(model.history.last?.name == "Apply Blue Sky")
        for url in [b, c] {
            let saved = store.load(for: url)
            #expect(saved?.recipe.masks.map(\.name) == ["Blue Sky"])
            #expect(hashes(saved?.recipe.masks) == ["worker"], "computed for \(url.lastPathComponent)")
            #expect(saved?.recipe.masks.first?[.localTemperature] == blueSky.localAdjustments[.localTemperature])
            #expect(store.loadHistory(for: url).last?.steps.last?.title == "Apply Blue Sky")
        }
        #expect(model.settingsSync.report == nil)

        model.undoSync()
        await model.settingsSync.idle()
        #expect(store.load(for: b) == nil, "Undo Sync Settings takes it back on the others")
        #expect(model.recipe.masks.count == 1, "and leaves the open photo's step to its own Undo")
    }

    @Test func `with one photo selected, a preset goes to that photo alone`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await open(a)
        await model.applyMaskPreset(blueSky)
        await model.settingsSync.idle()
        #expect(model.recipe.masks.map(\.name) == ["Blue Sky"])
        #expect(store.load(for: b) == nil)
        #expect(!model.settingsSync.canUndo)
    }

    /// The open photo's step would otherwise reach the others a second time, as a paste of A's mask.
    @Test func `with Auto Sync on, the other photos get the preset once`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await start()
        model.toggleAutoSync()
        await model.applyMaskPreset(blueSky)
        await model.settingsSync.idle()

        #expect(model.recipe.masks.count == 1)
        for url in [b, c] {
            #expect(store.load(for: url)?.recipe.masks.map(\.name) == ["Blue Sky"])
            #expect(hashes(store.load(for: url)?.recipe.masks) == ["worker"])
        }
        model.toggleAutoSync()
    }

    @Test func `a preset reaching a photo opened meanwhile is made there by the editor`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await start()
        model.settingsSync.beforeWriting = { [self] url in
            if url == b {
                try? await open(b)
            }
        }
        await model.applyMaskPreset(blueSky)
        await model.settingsSync.idle()

        #expect(model.info?.url == b)
        #expect(model.recipe.masks.map(\.name) == ["Blue Sky"])
        #expect(hashes(model.recipe.masks) == ["editor"], "computed by the editor for B")
        #expect(model.history.last?.name == "Apply Blue Sky")
        #expect(hashes(store.load(for: c)?.recipe.masks) == ["worker"])
    }

    @Test func `photos the preset's masks can't be made for are left alone, and the report says so`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let smoothSkin = try #require(MaskPreset.builtIn.first { $0.id == "redlamp.smoothSkin" })
        worker.missingParts = [.faceSkin]
        try await start()
        await model.applyMaskPreset(smoothSkin)
        await model.settingsSync.idle()

        #expect(model.recipe.masks.map(\.name) == ["Smooth Skin"], "the open photo has a face")
        #expect(store.load(for: b) == nil)
        #expect(store.load(for: c) == nil)
        #expect(model.settingsSync.report == "2 photos were left alone: Smooth Skin's masks couldn't be made for them.")
    }

    @Test func `a photo with as many masks as it can have is left alone`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var full = EditRecipe()
        full.masks = (0 ..< MaskLayer.maximumLayers).map { MaskLayer(name: "Mask \($0)", components: []) }
        try store.save(Sidecar(recipe: full), for: b)
        try await start()
        await model.applyMaskPreset(blueSky)
        await model.settingsSync.idle()

        #expect(store.load(for: b)?.recipe.masks.count == MaskLayer.maximumLayers)
        #expect(store.load(for: b)?.recipe.masks.contains { $0.name == "Blue Sky" } == false)
        #expect(store.load(for: c)?.recipe.masks.map(\.name) == ["Blue Sky"])
        #expect(model.settingsSync.report == "1 photo was left alone: it has 16 masks already.")
    }
}
