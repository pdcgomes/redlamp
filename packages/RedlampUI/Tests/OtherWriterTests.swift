import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// Another writer (another Mac through iCloud Drive or Dropbox, a second Redlamp) saving the
/// open photo's sidecar: the editor never saves over what they wrote.
@MainActor
struct OtherWriterTests {
    private struct Folder {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

        var photo: URL {
            url.appending(path: "IMG_0001.ARW")
        }

        var other: URL {
            url.appending(path: "IMG_0002.ARW")
        }

        /// Every file in the package, with its bytes.
        func contents() throws -> [String: Data] {
            let package = SidecarStore().url(for: photo)
            let enumerator = FileManager.default.enumerator(at: package, includingPropertiesForKeys: nil)
            var files: [String: Data] = [:]
            while let file = enumerator?.nextObject() as? URL {
                guard let data = try? Data(contentsOf: file) else { continue }
                files[String(file.path.dropFirst(package.path.count))] = data
            }
            return files
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

    /// Another Mac's save of the open photo, made while it is open here: contrast 40, five
    /// stars, a pick and a snapshot, with a history session of its own.
    private func saveFromAnotherMac(_ photo: URL) throws -> Sidecar {
        var recipe = EditRecipe()
        recipe[.exposure] = 0.5
        recipe[.contrast] = 40
        let session = HistorySession(steps: [
            HistoryStep(action: .open, title: "Opened", recipe: EditRecipe()),
            HistoryStep(action: .adjustment(.contrast), title: "Contrast", recipe: recipe),
        ])
        var earlier = recipe
        earlier[.contrast] = 20
        let theirs = Sidecar(
            recipe: recipe,
            snapshots: [Snapshot(name: "Made on the other Mac", recipe: earlier)],
            metadata: PhotoMetadata(rating: 5, flag: .pick),
            modified: Date(timeIntervalSinceNow: -60),
            session: session,
        )
        try SidecarStore().save(theirs, for: photo)
        return theirs
    }

    private func seedExposure(_ folder: Folder) throws {
        var recipe = EditRecipe()
        recipe[.exposure] = 0.5
        try SidecarStore().save(Sidecar(recipe: recipe), for: folder.photo)
    }

    @Test func `leaving a photo another writer saved meanwhile keeps their edit as they left it`() async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try seedExposure(folder)
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        _ = try saveFromAnotherMac(folder.photo)
        let theirs = try folder.contents()
        try await open(folder.other, in: model)
        await model.saves.flush()
        #expect(try folder.contents() == theirs)
    }

    @Test func `saving a photo another writer saved meanwhile, unchanged here, shows their edit`() async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try seedExposure(folder)
        let model = EditorModel(engine: StubEngine())
        model.library.insert(LibraryItem(url: folder.photo))
        try await open(folder.photo, in: model)

        let theirs = try saveFromAnotherMac(folder.photo)
        let written = try folder.contents()
        model.saveNow()
        await model.saves.flush()
        try await eventually { model.recipe[.contrast] == 40 }
        #expect(model.recipe == theirs.recipe)
        #expect(model.currentMetadata == PhotoMetadata(rating: 5, flag: .pick))
        #expect(model.snapshots.map(\.name) == ["Made on the other Mac"])
        #expect(model.history.last?.name == "Edit from Another Mac")
        #expect(model.library.item(for: folder.photo)?.metadata.rating == 5)
        #expect(try folder.contents() == written, "viewing writes nothing")

        model.setValue(.exposure, 1)
        try await open(folder.other, in: model)
        await model.saves.flush()
        let saved = try #require(SidecarStore().load(for: folder.photo))
        #expect(saved.recipe[.exposure] == 1)
        #expect(saved.recipe[.contrast] == 40)
        #expect(saved.snapshots.map(\.name) == ["Made on the other Mac"], "their edit taken, so not a clash")
    }

    @Test func `a change here and another writer's are merged, the older kept as a snapshot`() async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try seedExposure(folder)
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        model.setValue(.vibrance, 10)
        let theirs = try saveFromAnotherMac(folder.photo)
        let ours = model.recipe
        try await open(folder.other, in: model)
        await model.saves.flush()

        let saved = try #require(SidecarStore().load(for: folder.photo))
        #expect(saved.recipe == ours, "the newer edit wins")
        #expect(saved.snapshots.contains { $0.name == "Made on the other Mac" })
        let kept = saved.snapshots.first { $0.name.hasPrefix("Edit from another Mac") }
        #expect(kept?.recipe == theirs.recipe, "the other kept as a snapshot")
        #expect(saved.metadata == PhotoMetadata(rating: 5, flag: .pick), "rated only there, so theirs")
        let sessions = SidecarStore().loadHistory(for: folder.photo).map(\.id)
        #expect(try sessions.contains(#require(theirs.session).id), "their history")
        #expect(sessions.count == 2, "and this session's")
    }

    @Test func `the editor's own saves never look like another writer's`() async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try seedExposure(folder)
        let model = EditorModel(engine: StubEngine())
        model.library.insert(LibraryItem(url: folder.photo))
        try await open(folder.photo, in: model)

        for step in 1 ... 10 {
            model.setValue(.exposure, Double(step) / 10)
            model.saveNow()
            if step.isMultiple(of: 3) {
                _ = model.perform(.rating3)
            }
        }
        try await open(folder.other, in: model)
        await model.saves.flush()
        let saved = try #require(SidecarStore().load(for: folder.photo))
        #expect(saved.recipe[.exposure] == 1)
        #expect(saved.snapshots.isEmpty)
    }
}
