import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// Edits whose save failed are kept until a save goes through: leaving the photo, failing on
/// another, opening it again and quitting don't lose them.
@MainActor
struct FailedSaveTests {
    private struct Folder {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

        var photo: URL {
            url.appending(path: "IMG_0001.ARW")
        }

        var other: URL {
            url.appending(path: "IMG_0002.ARW")
        }

        var third: URL {
            url.appending(path: "IMG_0003.ARW")
        }

        init() throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func lock() throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        }

        func unlock() throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func remove() {
            try? unlock()
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func open(_ url: URL, in model: EditorModel) async throws {
        model.select(url)
        for _ in 0 ..< 400 where model.info?.url != url {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info?.url == url)
    }

    /// Waits for `condition`, which the save queue's results make true on the main actor.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func `two photos whose saves failed are both saved once the disk is back`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        try folder.lock()
        model.setValue(.exposure, 0.6)
        try await open(folder.other, in: model)
        model.setValue(.exposure, 0.9)
        try await open(folder.third, in: model)
        await model.saves.flush()
        try await eventually { model.saveError?.url == folder.other }

        try folder.unlock()
        try SidecarStore().save(Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 5)), for: folder.photo)
        model.retrySave()
        await model.saves.flush()
        try await eventually { model.saveError == nil }
        #expect(model.saveError == nil)
        let first = try #require(SidecarStore().load(for: folder.photo))
        #expect(first.recipe[.exposure] == 0.6)
        #expect(first.metadata?.rating == 5, "saved over another writer's edit, so merged with it")
        #expect(SidecarStore().load(for: folder.other)?.recipe[.exposure] == 0.9)
    }

    @Test func `a photo opened again after its save failed shows and saves its edits`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        try folder.lock()
        model.setValue(.exposure, 0.6)
        try await open(folder.other, in: model)
        await model.saves.flush()
        try await eventually { model.saveError?.url == folder.photo }

        try await open(folder.photo, in: model)
        #expect(model.recipe[.exposure] == 0.6)
        try folder.unlock()
        model.retrySave()
        await model.saves.flush()
        try await eventually { model.saveError == nil }
        #expect(SidecarStore().load(for: folder.photo)?.recipe[.exposure] == 0.6)
    }

    @Test func `a photo opened again after its save failed and another writer saved keeps both edits`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        try folder.lock()
        model.setValue(.exposure, 0.6)
        let ours = model.recipe
        try await open(folder.other, in: model)
        await model.saves.flush()
        try await eventually { model.saveError?.url == folder.photo }

        try folder.unlock()
        var recipe = EditRecipe()
        recipe[.contrast] = 40
        let theirs = Sidecar(
            recipe: recipe,
            snapshots: [Snapshot(name: "Made on the other Mac", recipe: EditRecipe())],
            metadata: PhotoMetadata(rating: 5),
            modified: Date(timeIntervalSinceNow: 60),
        )
        try SidecarStore().save(theirs, for: folder.photo)
        try await open(folder.photo, in: model)
        await model.saves.flush()

        let saved = try #require(SidecarStore().load(for: folder.photo))
        #expect(saved.recipe == theirs.recipe, "theirs is newer")
        #expect(saved.snapshots.contains { $0.recipe == ours }, "ours kept as a snapshot")
        #expect(saved.snapshots.contains { $0.name == "Made on the other Mac" })
        #expect(saved.metadata?.rating == 5)
        #expect(model.recipe == saved.recipe, "the editor shows what is on disk")
        #expect(model.snapshots == saved.snapshots)
    }

    @Test func `a quit that runs out of time with a failed save says so`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        try folder.lock()
        model.setValue(.exposure, 0.6)
        try await open(folder.other, in: model)
        await model.saves.flush()
        try await eventually { model.saveError?.url == folder.photo }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        model.saves.enqueue(.metadata { _ in gate.wait() }, for: folder.third)
        #expect(model.saveBeforeQuitting(within: .milliseconds(300)) == .unsaved([folder.photo]))
    }

    @Test func `quitting with a failed save tries it again, and says if it still fails`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        try folder.lock()
        model.setValue(.exposure, 0.6)
        try await open(folder.other, in: model)
        await model.saves.flush()
        try await eventually { model.saveError?.url == folder.photo }
        #expect(model.saveBeforeQuitting() == .unsaved([folder.photo]))
        try await eventually { model.failedSaves[folder.photo] != nil }

        try folder.unlock()
        #expect(model.saveBeforeQuitting() == .saved)
        #expect(SidecarStore().load(for: folder.photo)?.recipe[.exposure] == 0.6)
    }
}
