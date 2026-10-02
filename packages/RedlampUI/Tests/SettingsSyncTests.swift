import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// Sync Settings and Paste across a selection: the other photos' sidecars are written in the
/// background, with a history step, their pasted AI masks computed for them, and Undo puts them back.
@MainActor
struct SettingsSyncTests {
    private func open(_ model: EditorModel, _ url: URL) async throws {
        model.select(url)
        for _ in 0 ..< 200 where model.info?.url != url {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func `sync writes the other photos, with history, and undo puts them back`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photos = ["A", "B", "C", "D"].map { folder.appending(path: "\($0).ARW") }
        let (a, b, c, d) = (photos[0], photos[1], photos[2], photos[3])
        let store = SidecarStore()
        var edited = EditRecipe()
        edited[.contrast] = 30
        try store.save(Sidecar(recipe: edited), for: b)
        var newer = EditRecipe()
        newer.processVersion = EditRecipe.currentProcessVersion + 1
        try store.save(Sidecar(recipe: newer), for: d)

        let engine = StubEngine()
        let mask = AIMask(
            kind: .subject, provider: "stub", revision: 1, analysisHash: "h", center: ImagePoint(x: 0.5, y: 0.5),
            bitmap: MaskBitmap(sha256: "s", width: 4, height: 4),
        )
        engine.computed = [mask]
        let worker = StubEngine()
        worker.computed = [mask]
        let model = EditorModel(engine: engine)
        model.makeWorkerEngine = { worker }
        photos.forEach { model.library.insert(LibraryItem(url: $0)) }
        try await open(model, a)
        model.setValue(.exposure, 1)
        await model.createAIMask(.subject)
        model.selectAllPhotos()
        #expect(model.selection == a && model.selectedPhotos == photos)

        model.copySelection = .default
        model.syncSettings()
        await model.settingsSync.idle()

        let synced = try #require(store.load(for: b))
        #expect(synced.recipe[.exposure] == 1)
        #expect(synced.recipe[.contrast] == 0, "the active photo's untouched contrast resets B's")
        #expect(synced.recipe.masks.count == 1)
        #expect(!worker.requests.isEmpty && worker.requests.allSatisfy { $0.kind == .subject })
        let history = store.loadHistory(for: b).flatMap(\.steps).map(\.title)
        #expect(history.contains("Sync Settings"))
        #expect(store.load(for: c)?.recipe[.exposure] == 1, "a photo without a sidecar gets one")
        #expect(store.load(for: d)?.recipe[.exposure] == 0, "a newer Redlamp's edit is left alone")
        #expect(model.settingsSync.report?.contains("left alone") == true)
        #expect(model.library.item(for: c)?.hasEdits == true)

        #expect(model.canPerform(.undoSync))
        model.undoSync()
        #expect(store.load(for: b)?.recipe[.contrast] == 30)
        #expect(store.load(for: b)?.recipe[.exposure] == 0)
        #expect(store.load(for: c) == nil, "a sidecar the sync made is removed")
        #expect(!model.canPerform(.undoSync))
        model.copySelection = .default
    }

    /// Paste with several photos selected reaches all of them.
    @Test func `paste reaches the whole selection`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photos = ["A", "B", "C"].map { folder.appending(path: "\($0).ARW") }
        let model = EditorModel(engine: StubEngine())
        photos.forEach { model.library.insert(LibraryItem(url: $0)) }
        model.copySelection = .default
        try await open(model, photos[0])
        model.setValue(.exposure, 2)
        model.copySettings()
        try await open(model, photos[1])
        model.click(photos[2], toggling: true)
        for _ in 0 ..< 200 where model.info?.url != photos[2] {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.selectedPhotos == [photos[1], photos[2]])
        model.pasteSettings()
        await model.settingsSync.idle()
        #expect(model.recipe[.exposure] == 2, "C, the active photo, as a step of its own")
        #expect(model.history.last?.name == "Paste Settings")
        #expect(SidecarStore().load(for: photos[1])?.recipe[.exposure] == 2, "B, in the background")
    }

    /// With Auto Sync on, each step carries only what it changed: B keeps its own clarity.
    @Test func `auto sync repeats each change on the rest of the selection`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photos = ["A", "B"].map { folder.appending(path: "\($0).ARW") }
        var own = EditRecipe()
        own[.clarity] = 10
        try SidecarStore().save(Sidecar(recipe: own), for: photos[1])
        let model = EditorModel(engine: StubEngine())
        photos.forEach { model.library.insert(LibraryItem(url: $0)) }
        try await open(model, photos[0])
        model.selectAllPhotos()
        model.setValue(.exposure, 1)
        await model.settingsSync.idle()
        #expect(SidecarStore().load(for: photos[1])?.recipe[.exposure] == 0, "off: nothing synced")

        model.toggleAutoSync()
        defer { model.toggleAutoSync() }
        model.setValue(.exposure, 0.5)
        model.setValue(.contrast, 20)
        model.setValue(.vibrance, 15)
        await model.settingsSync.idle()
        let synced = try #require(SidecarStore().load(for: photos[1])?.recipe)
        #expect(synced[.exposure] == 0.5 && synced[.contrast] == 20 && synced[.vibrance] == 15)
        #expect(synced[.clarity] == 10, "only what the steps changed")
        let titles = SidecarStore().loadHistory(for: photos[1]).flatMap(\.steps).map(\.title)
        #expect(titles.contains("Auto Sync"))
    }
}
