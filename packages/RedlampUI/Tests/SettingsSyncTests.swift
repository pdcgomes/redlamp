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
        let photos = ["A", "B", "C", "D", "E"].map { folder.appending(path: "\($0).ARW") }
        let (a, b, c, d, e) = (photos[0], photos[1], photos[2], photos[3], photos[4])
        let store = SidecarStore()
        var edited = EditRecipe()
        edited[.contrast] = 30
        try store.save(Sidecar(recipe: edited), for: b)
        var newer = EditRecipe()
        newer.processVersion = EditRecipe.currentProcessVersion + 1
        try store.save(Sidecar(recipe: newer), for: d)
        let damaged = Data(#"{"format":"app.redlamp.edit","recipe":{"version":3,"#.utf8)
        try damaged.write(to: store.url(for: e))

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
        #expect(try Data(contentsOf: store.editURL(for: e)) == damaged, "an unreadable sidecar is left alone")
        #expect(model.settingsSync.report?.contains("left alone") == true)
        #expect(model.library.item(for: c)?.hasEdits == true)

        #expect(model.canPerform(.undoSync))
        model.undoSync()
        #expect(!model.canPerform(.undoSync), "while it runs")
        await model.settingsSync.idle()
        #expect(store.load(for: b)?.recipe[.contrast] == 30)
        #expect(store.load(for: b)?.recipe[.exposure] == 0)
        #expect(store.load(for: c) == nil, "a sidecar the sync made is removed")
        #expect(!model.canPerform(.undoSync))
        model.copySelection = .default
    }

    @Test func `undo keeps what was added since to a sidecar the sync made`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (a, b) = (folder.appending(path: "A.ARW"), folder.appending(path: "B.ARW"))
        let store = SidecarStore()
        let model = EditorModel(engine: StubEngine())
        [a, b].forEach { model.library.insert(LibraryItem(url: $0)) }
        try await open(model, a)
        model.setValue(.exposure, 1)
        model.selectAllPhotos()
        model.copySelection = .default
        model.syncSettings()
        await model.settingsSync.idle()
        try Library.writeMetadata(for: b, store: store) { $0.rating = 4 }

        model.undoSync()
        await model.settingsSync.idle()
        let kept = try #require(store.load(for: b), "the rating added since keeps the sidecar")
        #expect(kept.metadata?.rating == 4)
        #expect(kept.recipe[.exposure] == 0)
        model.copySelection = .default
    }

    @Test func `Undo Sync reads and writes the sidecars off the main thread`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (a, b) = (folder.appending(path: "A.ARW"), folder.appending(path: "B.ARW"))
        let store = SidecarStore()
        let model = EditorModel(engine: StubEngine())
        [a, b].forEach { model.library.insert(LibraryItem(url: $0)) }
        try await open(model, a)
        model.setValue(.exposure, 1)
        model.selectAllPhotos()
        model.copySelection = .default
        model.syncSettings()
        await model.settingsSync.idle()
        #expect(store.load(for: b)?.recipe[.exposure] == 1)

        // Another writer holds B's sidecar, as a busy disk would: Undo Sync's read of it waits, the main thread
        // doesn't.
        let release = DispatchSemaphore(value: 0)
        let sidecar = store.url(for: b)
        await withCheckedContinuation { held in
            Thread {
                var error: NSError?
                NSFileCoordinator(filePresenter: nil)
                    .coordinate(writingItemAt: sidecar, options: [], error: &error) { _ in
                        held.resume()
                        _ = release.wait(timeout: .now() + 2)
                    }
            }.start()
        }
        let started = ContinuousClock.now
        model.undoSync()
        let returned = ContinuousClock.now - started
        release.signal()
        #expect(returned < .milliseconds(500), "Undo Sync returned in \(returned)")
        await model.settingsSync.idle()
        #expect(store.load(for: b) == nil, "the sidecar the sync made is removed")
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

    /// A paste while a sync is still running waits its turn instead of being dropped.
    @Test func `a batch that arrives while another runs waits its turn`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photos = ["A", "B", "C"].map { folder.appending(path: "\($0).ARW") }
        let model = EditorModel(engine: StubEngine())
        photos.forEach { model.library.insert(LibraryItem(url: $0)) }
        model.copySelection = .default
        try await open(model, photos[0])
        model.setValue(.exposure, 1)
        model.selectAllPhotos()
        model.syncSettings()
        #expect(model.settingsSync.progress != nil)
        model.setValue(.contrast, 20)
        model.copySettings()
        model.pasteSettings()
        await model.settingsSync.idle()
        for url in photos.dropFirst() {
            let recipe = SidecarStore().load(for: url)?.recipe
            #expect(recipe?[.exposure] == 1 && recipe?[.contrast] == 20, "\(url.lastPathComponent)")
        }
        let titles = SidecarStore().loadHistory(for: photos[1]).flatMap(\.steps).map(\.title)
        #expect(titles.contains("Sync Settings") && titles.contains("Paste Settings"))
    }

    /// Paste from Previous reaches every selected photo, as Paste does.
    @Test func `paste from previous reaches the whole selection`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photos = ["A", "B", "C"].map { folder.appending(path: "\($0).ARW") }
        var edited = EditRecipe()
        edited[.exposure] = 2
        try SidecarStore().save(Sidecar(recipe: edited), for: photos[1])
        let model = EditorModel(engine: StubEngine())
        photos.forEach { model.library.insert(LibraryItem(url: $0)) }
        model.copySelection = .default
        try await open(model, photos[0])
        model.click(photos[1], toggling: true)
        for _ in 0 ..< 200 where model.info?.url != photos[1] {
            try await Task.sleep(for: .milliseconds(5))
        }
        model.click(photos[2], toggling: true)
        for _ in 0 ..< 200 where model.info?.url != photos[2] {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.previousSelection == photos[1] && model.selectedPhotos == photos)
        model.pasteFromPrevious()
        for _ in 0 ..< 200 where model.recipe[.exposure] != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        await model.settingsSync.idle()
        #expect(model.recipe[.exposure] == 2, "C, the open photo")
        #expect(SidecarStore().load(for: photos[0])?.recipe[.exposure] == 2, "A, in the background")
    }

    /// A slider on an AI mask keeps the mask B computed for itself; deleting the mask deletes B's.
    @Test func `auto sync keeps each photo's AI mask and carries its deletion`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photos = ["A", "B"].map { folder.appending(path: "\($0).ARW") }
        func subject(_ hash: String) -> AIMask {
            AIMask(
                kind: .subject, provider: "stub", revision: 1, analysisHash: hash,
                center: ImagePoint(x: 0.5, y: 0.5), bitmap: MaskBitmap(sha256: hash, width: 4, height: 4),
            )
        }
        let engine = StubEngine()
        engine.computed = [subject("a")]
        let worker = StubEngine()
        worker.computed = [subject("b")]
        let model = EditorModel(engine: engine)
        model.makeWorkerEngine = { worker }
        photos.forEach { model.library.insert(LibraryItem(url: $0)) }
        try await open(model, photos[0])
        model.selectAllPhotos()
        model.toggleAutoSync()
        defer { model.toggleAutoSync() }

        await model.createAIMask(.subject)
        await model.settingsSync.idle()
        #expect(worker.requests.count == 1)
        let mask = try #require(model.recipe.masks.first)
        model.setMaskValue(.maskAmount, 50)
        await model.settingsSync.idle()
        let synced = try #require(SidecarStore().load(for: photos[1])?.recipe.mask(mask.id))
        #expect(synced.amount == 50)
        #expect(worker.requests.count == 1, "B's own subject is kept")
        guard case let .ai(own) = synced.components.first?.shape else { throw CancellationError() }
        #expect(own.analysisHash == "b")

        model.deleteMask(mask.id)
        await model.settingsSync.idle()
        #expect(SidecarStore().load(for: photos[1])?.recipe.masks.isEmpty == true)
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
        let sessions = SidecarStore().loadHistory(for: photos[1])
        #expect(sessions.count == 1, "one session for the run")
        #expect(sessions.first?.steps.first?.title == "Opened")
        #expect(sessions.first?.steps.dropFirst().allSatisfy { $0.title.hasPrefix("Auto Sync: ") } == true)
    }

    private func autoSyncing(
        _ names: [String],
        own: [String: EditRecipe] = [:],
    ) async throws -> (EditorModel, [URL], URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photos = names.map { folder.appending(path: "\($0).ARW") }
        for (name, recipe) in own {
            try SidecarStore().save(Sidecar(recipe: recipe), for: folder.appending(path: "\(name).ARW"))
        }
        let model = EditorModel(engine: StubEngine())
        photos.forEach { model.library.insert(LibraryItem(url: $0)) }
        try await open(model, photos[0])
        model.selectAllPhotos()
        model.toggleAutoSync()
        return (model, photos, folder)
    }

    private func edit(_ url: URL) -> EditRecipe? {
        SidecarStore().load(for: url)?.recipe
    }

    /// Lightroom's undo: B's own exposure comes back, and Redo takes it to the open photo's again.
    @Test func `undo with auto sync on gives each photo its own edit back`() async throws {
        var own = EditRecipe()
        own[.exposure] = 0.3
        own[.clarity] = 10
        let (model, photos, folder) = try await autoSyncing(["A", "B"], own: ["B": own])
        defer {
            model.toggleAutoSync()
            try? FileManager.default.removeItem(at: folder)
        }
        model.setValue(.exposure, 1)
        await model.settingsSync.idle()
        #expect(edit(photos[1])?[.exposure] == 1)

        model.undo()
        await model.settingsSync.idle()
        #expect(edit(photos[1])?[.exposure] == 0.3 && edit(photos[1])?[.clarity] == 10)
        model.redo()
        await model.settingsSync.idle()
        #expect(edit(photos[1])?[.exposure] == 1 && edit(photos[1])?[.clarity] == 10)
        let sessions = SidecarStore().loadHistory(for: photos[1])
        #expect(sessions.count == 1)
        #expect(sessions.first?.steps.map(\.title) == [
            "Opened", "Auto Sync: Exposure", "Undo Auto Sync", "Redo Auto Sync",
        ])
    }

    /// A click on an earlier step takes B back past several; a new step after it starts a branch.
    @Test func `history clicks and a new step after undo move the other photos with the open one`() async throws {
        var own = EditRecipe()
        own[.exposure] = 0.3
        let (model, photos, folder) = try await autoSyncing(["A", "B", "C"], own: ["B": own])
        defer {
            model.toggleAutoSync()
            try? FileManager.default.removeItem(at: folder)
        }
        model.setValue(.exposure, 1)
        model.setValue(.contrast, 20)
        model.setValue(.vibrance, 15)
        await model.settingsSync.idle()
        #expect(edit(photos[1])?[.vibrance] == 15 && edit(photos[2])?[.vibrance] == 15)

        model.goToHistory(1)
        await model.settingsSync.idle()
        let back = try #require(edit(photos[1]))
        #expect(back[.exposure] == 1 && back[.contrast] == 0 && back[.vibrance] == 0)

        model.setValue(.clarity, 5)
        await model.settingsSync.idle()
        model.undo()
        await model.settingsSync.idle()
        let undone = try #require(edit(photos[1]))
        #expect(undone[.clarity] == 0 && undone[.exposure] == 1 && undone[.contrast] == 0)

        model.goToHistory(0)
        await model.settingsSync.idle()
        #expect(edit(photos[1])?[.exposure] == 0.3, "B's own")
        #expect(edit(photos[2])?.isPristine == true, "C had no edit")
    }

    /// A photo changed elsewhere since Auto Sync wrote it keeps that change.
    @Test func `a photo edited since auto sync wrote it is left alone`() async throws {
        let (model, photos, folder) = try await autoSyncing(["A", "B"])
        defer {
            model.toggleAutoSync()
            try? FileManager.default.removeItem(at: folder)
        }
        model.setValue(.exposure, 1)
        await model.settingsSync.idle()
        var sidecar = try #require(SidecarStore().load(for: photos[1]))
        sidecar.recipe[.contrast] = 40
        try SidecarStore().save(sidecar, for: photos[1])

        model.undo()
        await model.settingsSync.idle()
        #expect(edit(photos[1])?[.exposure] == 1 && edit(photos[1])?[.contrast] == 40)
        #expect(model.settingsSync.report?.contains("edited since") == true)
    }

    /// With Auto Sync on, a paste onto the selection is part of the run: Undo takes it back on B.
    @Test func `undo takes back a paste made while auto sync is on`() async throws {
        var own = EditRecipe()
        own[.exposure] = 0.3
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photos = ["A", "B"].map { folder.appending(path: "\($0).ARW") }
        try SidecarStore().save(Sidecar(recipe: own), for: photos[1])
        let model = EditorModel(engine: StubEngine())
        photos.forEach { model.library.insert(LibraryItem(url: $0)) }
        model.copySelection = .default
        try await open(model, photos[0])
        model.setValue(.exposure, 2)
        model.copySettings()
        model.setValue(.exposure, 0)
        model.selectAllPhotos()
        model.toggleAutoSync()
        defer { model.toggleAutoSync() }

        model.pasteSettings()
        await model.settingsSync.idle()
        #expect(model.recipe[.exposure] == 2 && edit(photos[1])?[.exposure] == 2)
        model.undo()
        await model.settingsSync.idle()
        #expect(model.recipe[.exposure] == 0 && edit(photos[1])?[.exposure] == 0.3)
    }
}
