import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampUI

/// A photo whose sidecar is there but can't be read now (another app's file presenter fails to
/// save it first, as file coordination can also fail for iCloud Drive) is left alone by Paste
/// and Auto Sync, never written as a photo with no edit.
@MainActor
struct SidecarReadFailureTests {
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

    /// An edited photo whose sidecar's protection reads and whose edit then doesn't, once.
    private func edited() throws -> (URL, SidecarStore, FailingPresenter, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appending(path: "IMG_0001.ARW")
        let store = SidecarStore()
        var recipe = EditRecipe()
        recipe[.exposure] = 1
        var snapshot = EditRecipe()
        snapshot[.exposure] = 0.3
        try store.save(Sidecar(recipe: recipe, snapshots: [Snapshot(name: "Mine", recipe: snapshot)]), for: image)
        let presenter = FailingPresenter(store.url(for: image), failures: [false, true])
        NSFileCoordinator.addFilePresenter(presenter)
        return (image, store, presenter, {
            NSFileCoordinator.removeFilePresenter(presenter)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func expectUnchanged(_ image: URL, _ store: SidecarStore, _ sync: SettingsSync) throws {
        let onDisk = try #require(store.load(for: image))
        #expect(onDisk.recipe[.exposure] == 1)
        #expect(onDisk.recipe[.contrast] == 0)
        #expect(onDisk.snapshots.map(\.name) == ["Mine"])
        #expect(sync.report?.contains("1 photo was left alone") == true)
    }

    @Test func `a paste onto a photo whose sidecar can't be read leaves it alone`() async throws {
        let (image, store, presenter, cleanup) = try edited()
        defer { cleanup() }
        let sync = SettingsSync(store: store, makeEngine: { nil })
        var source = EditRecipe()
        source[.contrast] = 40

        sync.run(.paste(source, .everything), on: [image], title: "Paste Settings") { _, _ in }
        await sync.idle()
        #expect(presenter.asked.withLock { $0 } >= 2)
        try expectUnchanged(image, store, sync)
    }

    @Test func `Auto Sync leaves a photo whose sidecar can't be read alone`() async throws {
        let (image, store, presenter, cleanup) = try edited()
        defer { cleanup() }
        let sync = SettingsSync(store: store, makeEngine: { nil })
        var source = EditRecipe()
        source[.contrast] = 40
        let step = SettingsSync.RunStep(
            session: UUID(), id: UUID(), title: "Contrast",
            carried: SettingsSelection.changes(from: EditRecipe(), to: source),
        )

        sync.autoSync(source, step: step, on: [image]) { _, _ in }
        await sync.idle()
        #expect(presenter.asked.withLock { $0 } >= 2)
        try expectUnchanged(image, store, sync)
    }

    @Test func `undoing a sync says which photos it couldn't read to put back`() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appending(path: "IMG_0001.ARW")
        let store = SidecarStore()
        var recipe = EditRecipe()
        recipe[.exposure] = 1
        try store.save(Sidecar(recipe: recipe), for: image)
        let sync = SettingsSync(store: store, makeEngine: { nil })
        var source = EditRecipe()
        source[.contrast] = 40
        sync.run(.paste(source, .everything), on: [image], title: "Paste Settings") { _, _ in }
        await sync.idle()
        try #require(store.load(for: image)?.recipe[.contrast] == 40)

        let presenter = FailingPresenter(store.url(for: image), failures: [true])
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        var undone: [URL] = []
        sync.undo { url, _ in undone.append(url) }
        #expect(presenter.asked.withLock { $0 } >= 1)
        #expect(undone.isEmpty)
        #expect(sync.report == "1 photo couldn't be put back: the edit can't be read.")
        #expect(store.load(for: image)?.recipe[.contrast] == 40)
    }
}
