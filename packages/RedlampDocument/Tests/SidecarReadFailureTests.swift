import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing

/// A sidecar read that fails for a reason other than its content (here, another app's file
/// presenter failing to save it first, as file coordination can also fail for iCloud Drive) must
/// never leave the photo looking unedited, where the next save or rating writes over its edit.
struct SidecarReadFailureTests {
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

    /// Another app presenting the sidecar, failing the requests to save it that `failures` says,
    /// in order; those after succeed. A coordinated read or write fails with its error.
    private final class FailingPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        let failures: Mutex<[Bool]>
        let asked = Mutex(0)

        init(_ url: URL, failures: [Bool]) {
            presentedItemURL = url
            self.failures = Mutex(failures)
        }

        func savePresentedItemChanges(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
            asked.withLock { $0 += 1 }
            let fails = failures.withLock { $0.isEmpty ? false : $0.removeFirst() }
            completionHandler(fails ? CocoaError(.fileReadUnknown) : nil)
        }
    }

    private func edited(_ store: SidecarStore, _ image: URL) throws -> Sidecar {
        let edit = Sidecar(
            recipe: recipe(exposure: 1),
            snapshots: [Snapshot(name: "Mine", recipe: recipe(exposure: 0.3))],
        )
        try store.save(edit, for: image)
        return edit
    }

    @Test func `an edit whose read fails as the photo opens is read-only, and isn't saved over`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        _ = try edited(store, image)
        let presenter = FailingPresenter(store.url(for: image), failures: [true])
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        // As `EditorModel` opens a photo.
        let read = store.readForEditing(for: image)
        #expect(presenter.asked.withLock { $0 } == 1, "the digest, the edit and its protection in one read")
        #expect(read.sidecar == nil)
        #expect(read.failed, "read again")
        #expect(read.protection == .unreadable, "read-only meanwhile")

        let again = store.readForEditing(for: image)
        #expect(!again.failed && again.protection == nil)
        #expect(again.sidecar?.recipe[.exposure] == 1)
        #expect(again.sidecar?.snapshots.map(\.name) == ["Mine"])
    }

    @Test func `a photo with no sidecar reads as unedited, not as one that failed`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let read = SidecarStore().readForEditing(for: image)
        #expect(read.sidecar == nil && read.protection == nil && !read.failed)
    }

    @Test func `a rating while the edit can't be read keeps the edit`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        _ = try edited(store, image)
        let presenter = FailingPresenter(store.url(for: image), failures: [true])
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        // The save queue's `.metadata` write.
        var thrown: (any Error)?
        do {
            try Library.writeMetadata(for: image, store: store) { $0.rating = 3 }
        } catch {
            thrown = error
        }
        #expect(presenter.asked.withLock { $0 } >= 1)
        #expect(thrown != nil, "nothing is written")
        #expect(!(thrown is SidecarStoreError), "not a protected sidecar's error, so the save queue tries it again")
        let onDisk = try #require(store.load(for: image))
        #expect(onDisk.recipe[.exposure] == 1)
        #expect(onDisk.snapshots.map(\.name) == ["Mine"])
        #expect(onDisk.metadata?.rating == nil)

        try Library.writeMetadata(for: image, store: store) { $0.rating = 3 }
        let rated = try #require(store.load(for: image))
        #expect(rated.metadata?.rating == 3, "tried again once it reads")
        #expect(rated.recipe[.exposure] == 1 && rated.snapshots.map(\.name) == ["Mine"])
    }
}
