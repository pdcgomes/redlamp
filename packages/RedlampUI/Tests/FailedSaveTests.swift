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
