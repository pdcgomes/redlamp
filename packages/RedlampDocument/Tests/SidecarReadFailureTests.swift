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

    @Test func `an edit whose read fails as the photo opens isn't saved over`() throws {
        let (image, cleanup) = try temporaryImage()
        defer { cleanup() }
        let store = SidecarStore()
        _ = try edited(store, image)
        // The digest reads; the edit doesn't; its protection reads.
        let presenter = FailingPresenter(store.url(for: image), failures: [false, true])
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        // As `EditorModel` opens a photo: its sidecar and base, then its protection.
        let (sidecar, base) = store.loadWithBase(for: image)
        let protection = store.protection(for: image)
        #expect(presenter.asked.withLock { $0 } >= 3)
        #expect(sidecar == nil, "the read failed")

        withKnownIssue("DATA-18: a read that fails opens the photo unedited, and its next save writes over the edit") {
            #expect(protection != nil, "a sidecar that's there but couldn't be read opens read-only")
            if protection == nil {
                // Read-write, and unedited: the user's first change is saved over the base it read.
                var changed = Sidecar(recipe: EditRecipe())
                changed.recipe[.contrast] = 10
                _ = try store.saveOrRemove(changed, for: image, over: base, opened: Sidecar(recipe: EditRecipe()))
            }
            let onDisk = try #require(store.load(for: image))
            #expect(onDisk.recipe[.exposure] == 1)
            #expect(onDisk.snapshots.map(\.name) == ["Mine"])
        }
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
