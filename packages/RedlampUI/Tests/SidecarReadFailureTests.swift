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

    /// An edited photo whose sidecar's reads fail as `failures` says: by default its protection
    /// reads and its edit then doesn't, once.
    private func edited(failures: [Bool] = [false, true]) throws -> (URL, SidecarStore, FailingPresenter, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appending(path: "IMG_0001.ARW")
        let store = SidecarStore()
        var recipe = EditRecipe()
        recipe[.exposure] = 1
        var snapshot = EditRecipe()
        snapshot[.exposure] = 0.3
        try store.save(Sidecar(recipe: recipe, snapshots: [Snapshot(name: "Mine", recipe: snapshot)]), for: image)
        let presenter = FailingPresenter(store.url(for: image), failures: failures)
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

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The editor's reads as a photo opens: before, the digest, the edit and the protection
    /// were read apart, and any of them could fail alone.
    @Test(arguments: [[true], [false, true], [false, false, true]])
    func `a photo whose sidecar read fails is read-only until it reads, never unedited`(failures: [Bool]) async throws {
        let (image, store, presenter, cleanup) = try edited(failures: failures)
        defer { cleanup() }
        let model = EditorModel(engine: StubEngine())
        model.sidecarReadRetryDelay = .milliseconds(50)

        model.select(image)
        try await eventually { model.info?.url == image }
        try #require(model.info?.url == image)
        #expect(model.isReadOnly || model.recipe[.exposure] == 1, "never open unedited and saved over")
        try await eventually { !model.isReadOnly && model.recipe[.exposure] == 1 }
        #expect(!model.isReadOnly)
        #expect(model.recipe[.exposure] == 1)
        #expect(model.snapshots.map(\.name) == ["Mine"])

        NSFileCoordinator.removeFilePresenter(presenter)
        model.setValue(.contrast, 10)
        model.saveNow()
        await model.saves.flush()
        let onDisk = try #require(store.load(for: image))
        #expect(onDisk.recipe[.exposure] == 1)
        #expect(onDisk.recipe[.contrast] == 10)
        #expect(onDisk.snapshots.map(\.name) == ["Mine"])
    }

    @Test func `copying the settings of a photo whose sidecar can't be read copies nothing`() async throws {
        let (image, _, presenter, cleanup) = try edited(failures: [true])
        defer { cleanup() }
        let model = EditorModel(engine: StubEngine())

        await model.copySettings(from: image)
        #expect(presenter.asked.withLock { $0 } >= 1)
        #expect(!model.hasClipboard, "not the default edit in its place")
    }

    @Test func `Remove Dust leaves out a photo whose edit can't be read`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photos = ["A", "B", "C"].map { folder.appending(path: "\($0).ARW") }
        let damaged = Data(
            #"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,"values":{"basic.expo"#
                .utf8,
        )
        try damaged.write(to: SidecarStore().editURL(for: photos[2]))
        let worker = StubEngine()
        let model = EditorModel(engine: StubEngine())
        model.makeWorkerEngine = { worker }
        photos.forEach { model.library.insert(LibraryItem(url: $0)) }
        model.select(photos[0])
        try await eventually { model.info?.url == photos[0] }
        model.selectAllPhotos()
        model.activeTool = .heal

        await model.removeDustInSelection()
        await model.settingsSync.idle()
        #expect(worker.shootPhotos == Array(photos.prefix(2)), "not looked for in the default edit")
        #expect(try Data(contentsOf: SidecarStore().editURL(for: photos[2])) == damaged)
    }
}
