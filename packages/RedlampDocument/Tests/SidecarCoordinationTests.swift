import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing

/// Coordinated sidecar I/O for iCloud Drive: presenters are told about writes, reads wait for
/// writers, and conflicting copies merge without losing an edit.
struct SidecarCoordinationTests {
    private func temporaryImage() throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory.appending(path: "IMG_0001.ARW"), { try? FileManager.default.removeItem(at: directory) })
    }

    private func recipe(exposure: Double) -> EditRecipe {
        var recipe = EditRecipe()
        recipe[.exposure] = exposure
        return recipe
    }

    /// Records what file coordination tells it about the sidecar.
    private final class Presenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        let events = Mutex<[String]>([])

        init(_ url: URL) {
            presentedItemURL = url
        }

        func relinquishPresentedItem(toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
            events.withLock { $0.append("relinquish") }
            writer(nil)
        }
    }

    @Test func `saves tell the sidecar's presenters`() async throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        try store.save(Sidecar(recipe: recipe(exposure: 0.5)), for: image)
        let presenter = Presenter(store.url(for: image))
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        try store.save(Sidecar(recipe: recipe(exposure: 1)), for: image)
        for _ in 0 ..< 100 where presenter.events.withLock({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(presenter.events.withLock { $0 }.contains("relinquish"))
    }

    @Test func `a load waits for a writer and sees what it wrote`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        try store.save(Sidecar(recipe: recipe(exposure: 0.5)), for: image)
        let sidecar = store.url(for: image)
        let writing = DispatchSemaphore(value: 0)

        // Another process's coordinated write: it holds the sidecar, then replaces the edit.
        let writer = Thread {
            var error: NSError?
            NSFileCoordinator(filePresenter: nil)
                .coordinate(writingItemAt: sidecar, options: [], error: &error) { url in
                    writing.signal()
                    Thread.sleep(forTimeInterval: 0.3)
                    let edited = Sidecar(recipe: recipe(exposure: 2))
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    try? encoder.encode(edited).write(to: url.appending(path: SidecarStore.editFile), options: .atomic)
                }
        }
        writer.start()
        writing.wait()
        let loaded = try #require(store.load(for: image))
        #expect(loaded.recipe[.exposure] == 2)
    }

    @Test func `the newest copy wins and the others become snapshots`() {
        let older = Sidecar(
            recipe: recipe(exposure: 0.5), snapshots: [Snapshot(name: "Mine", recipe: recipe(exposure: 0.1))],
            modified: Date(timeIntervalSince1970: 1000),
        )
        var newer = Sidecar(
            recipe: recipe(exposure: 1.5), metadata: PhotoMetadata(rating: 4),
            modified: Date(timeIntervalSince1970: 2000),
        )
        newer.unknownFields = ["future": .string("kept")]
        let same = Sidecar(recipe: recipe(exposure: 1.5), modified: Date(timeIntervalSince1970: 1500))

        let merged = SidecarStore.merge(older, [newer, same])
        #expect(merged.recipe == newer.recipe)
        #expect(merged.metadata == PhotoMetadata(rating: 4))
        #expect(merged.modified == newer.modified)
        #expect(merged.unknownFields["future"] == .string("kept"))
        #expect(merged.snapshots.map(\.name).contains("Mine"))
        let fromOther = merged.snapshots.filter { $0.name.hasPrefix("Edit from another Mac") }
        #expect(fromOther.map(\.recipe) == [older.recipe], "only the edit that lost is kept, once")
    }

    /// Conflicting copies another Mac's Redlamp wrote: one this build can't read, one by a newer
    /// build, and one it would save back with a value clamped.
    static let unmergeable = [
        #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,"treatment":"infrared"}}"#,
        #"{"format":"app.redlamp.edit","recipe":{"version":99,"processVersion":1}}"#,
        #"{"format":"app.redlamp.edit","recipe":{"version":3,"processVersion":1,"values":{"basic.exposure":9}}}"#,
    ]

    @Test(arguments: unmergeable)
    func `a conflicting copy this build can't merge losslessly leaves every copy unresolved`(json: String) throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        let other = image.deletingLastPathComponent().appending(path: "IMG_0002.ARW")
        try store.save(Sidecar(recipe: recipe(exposure: 1.5)), for: other)
        let readable = store.url(for: other)
        let unmergeable = store.url(for: image)
        try Data(json.utf8).write(to: unmergeable)

        let current = Sidecar(recipe: recipe(exposure: 0.5), modified: Date(timeIntervalSince1970: 1000))
        #expect(SidecarStore.merge(current, conflictsAt: [readable, unmergeable]) == nil)
        #expect(SidecarStore.merge(current, conflictsAt: [readable])?.recipe[.exposure] == 1.5)
    }

    @Test func `merging a copy with itself changes nothing`() {
        let sidecar = Sidecar(recipe: recipe(exposure: 0.7), modified: Date(timeIntervalSince1970: 1000))
        #expect(SidecarStore.merge(sidecar, [sidecar]) == sidecar)
    }

    // MARK: - Another writer while the photo is open

    @Test func `a save over an unchanged base writes, and the next goes over what it wrote`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        try store.save(Sidecar(recipe: recipe(exposure: 0.5)), for: image)
        let (loaded, base) = store.loadWithBase(for: image)
        let opened = try #require(loaded)

        let first = Sidecar(recipe: recipe(exposure: 1))
        guard case let .saved(next) = try store.saveOrRemove(first, for: image, over: base, opened: opened) else {
            Issue.record("saved")
            return
        }
        let second = Sidecar(recipe: recipe(exposure: 2))
        guard case .saved = try store.saveOrRemove(second, for: image, over: next, opened: first) else {
            Issue.record("its own save isn't another writer's")
            return
        }
        #expect(store.load(for: image)?.recipe[.exposure] == 2)
    }

    @Test func `with nothing changed here, another writer's save is left as they wrote it`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        try store.save(Sidecar(recipe: recipe(exposure: 0.5)), for: image)
        let (loaded, base) = store.loadWithBase(for: image)
        let opened = try #require(loaded)
        try store.save(Sidecar(recipe: recipe(exposure: 3), metadata: PhotoMetadata(rating: 5)), for: image)
        let theirs = try Data(contentsOf: store.editURL(for: image))

        guard case let .theirs(now) = try store.saveOrRemove(opened, for: image, over: base, opened: opened) else {
            Issue.record("theirs")
            return
        }
        #expect(now.sidecar?.recipe[.exposure] == 3)
        #expect(try Data(contentsOf: store.editURL(for: image)) == theirs)
    }

    @Test func `what each side changed alone is kept, and the older of two edits becomes a snapshot`() {
        let base = Sidecar(recipe: recipe(exposure: 0.5), modified: Date(timeIntervalSince1970: 1000))
        var ours = base
        ours.recipe[.vibrance] = 10
        ours.modified = Date(timeIntervalSince1970: 3000)
        var theirs = base
        theirs.recipe[.contrast] = 40
        theirs.metadata = PhotoMetadata(rating: 5)
        theirs.modified = Date(timeIntervalSince1970: 2000)

        let merged = SidecarStore.merge(ours, theirs, base: base, opened: base)
        #expect(merged.recipe == ours.recipe)
        #expect(merged.snapshots.map(\.recipe) == [theirs.recipe])
        #expect(merged.metadata == PhotoMetadata(rating: 5))

        var rated = base
        rated.metadata = PhotoMetadata(rating: 2)
        let onlyTheirEdit = SidecarStore.merge(rated, theirs, base: base, opened: base)
        #expect(onlyTheirEdit.recipe == theirs.recipe, "edited only there")
        #expect(onlyTheirEdit.snapshots.isEmpty)
        #expect(onlyTheirEdit.metadata == PhotoMetadata(rating: 2), "rated in both: this one's, the save being newer")
    }

    @Test func `an edit a newer version saved meanwhile is never saved over`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        try store.save(Sidecar(recipe: recipe(exposure: 0.5)), for: image)
        let (loaded, base) = store.loadWithBase(for: image)
        let opened = try #require(loaded)
        let newer = Data(#"{"format":"app.redlamp.edit","recipe":{"version":999,"processVersion":1}}"#.utf8)
        try newer.write(to: store.editURL(for: image))

        #expect(throws: SidecarStoreError.self) {
            try store.saveOrRemove(Sidecar(recipe: recipe(exposure: 1)), for: image, over: base, opened: opened)
        }
        #expect(try Data(contentsOf: store.editURL(for: image)) == newer)
    }
}
