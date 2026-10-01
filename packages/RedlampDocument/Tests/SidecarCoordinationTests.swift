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

    @Test func `merging a copy with itself changes nothing`() {
        let sidecar = Sidecar(recipe: recipe(exposure: 0.7), modified: Date(timeIntervalSince1970: 1000))
        #expect(SidecarStore.merge(sidecar, [sidecar]) == sidecar)
    }
}
