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
@Suite(.timeLimit(.minutes(1)))
struct SidecarReadFailureTests {
    /// Another app presenting the sidecar, failing the requests to save it that `failures` says,
    /// in order; those after succeed. A coordinated read or write fails with its error.
    final class FailingPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
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

    /// Waits for `condition`, for as long as a loaded machine may need.
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
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

        // Off the main actor: removing a presenter waits for the coordinations it is part of.
        await Task.detached { NSFileCoordinator.removeFilePresenter(presenter) }.value
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

    @Test func `a sidecar read that keeps failing is read again until it reads`() async throws {
        let (image, _, presenter, cleanup) = try edited(failures: [true, true, true])
        defer { cleanup() }
        let model = EditorModel(engine: StubEngine())
        model.sidecarReadRetryDelay = .milliseconds(20)

        model.select(image)
        try await eventually { model.info?.url == image }
        #expect(model.isReadOnly || presenter.asked.withLock { $0 } > 1)
        try await eventually { !model.isReadOnly && model.recipe[.exposure] == 1 }
        #expect(presenter.asked.withLock { $0 } >= 4, "three failed reads, then one that read")
        #expect(!model.isReadOnly && model.recipe[.exposure] == 1)
    }

    @Test func `a rating that failed as the photo opened is saved once its sidecar reads`() async throws {
        let (image, store, presenter, cleanup) = try edited(failures: [true, true])
        defer { cleanup() }
        let model = EditorModel(engine: StubEngine())
        model.sidecarReadRetryDelay = .milliseconds(100)
        model.saveRetry.delay = .seconds(60)
        model.library.insert(LibraryItem(url: image))

        model.select(image)
        _ = model.perform(.rating3)
        try await eventually { model.info?.url == image && model.isReadOnly }
        #expect(model.saveError?.canRetry == true)
        try await eventually { !model.isReadOnly }
        await model.saves.flush()
        try await eventually { store.load(for: image)?.metadata?.rating == 3 }
        #expect(presenter.asked.withLock { $0 } >= 3)
        #expect(store.load(for: image)?.metadata?.rating == 3, "saved then, not at the next retry")
        #expect(store.load(for: image)?.recipe[.exposure] == 1)
        #expect(model.photoMetadata.rating == 3)
    }

    @Test func `reading the sidecar again keeps the zoom and where the photo is panned to`() async throws {
        let (image, _, _, cleanup) = try edited(failures: [true])
        defer { cleanup() }
        let engine = GatedEngine()
        engine.sendsFrames = true
        let model = EditorModel(engine: engine)
        model.canvas.updateView(size: CGSize(width: 300, height: 200), backingScale: 1)
        model.sidecarReadRetryDelay = .milliseconds(300)

        model.select(image)
        try await eventually { model.info?.url == image && model.isReadOnly && model.hasFrame }
        try #require(model.isReadOnly && model.hasFrame)
        model.canvas.zoom = .scale(1)
        model.canvas.center = CGPoint(x: 0.3, y: 0.6)
        let (zoom, center) = (model.canvas.zoom, model.canvas.center)
        try await eventually { !model.isReadOnly }
        try #require(!model.isReadOnly && model.recipe[.exposure] == 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.canvas.zoom == zoom)
        #expect(model.canvas.center == center)
    }

    /// A open read-only, B decoded ahead, and B's sidecar reads held at `reads` while it is held.
    private func openReadOnly(
        patience: Duration = .seconds(30), failures: [Bool] = [true],
    ) async throws -> (EditorModel, Gate, URL, URL, () -> Void) {
        let (a, _, _, cleanup) = try edited(failures: failures)
        let b = a.deletingLastPathComponent().appending(path: "IMG_0002.ARW")
        let engine = GatedEngine()
        engine.base.ready = [a, b]
        let reads = Gate()
        let model = EditorModel(engine: engine)
        model.openingPatience = patience
        model.sidecarReadRetryDelay = .milliseconds(100)
        model.beforeReadingSidecar = { url in
            if url == b {
                await reads.pass()
            }
        }
        [a, b].forEach { model.library.insert(LibraryItem(url: $0)) }
        return (model, reads, a, b, cleanup)
    }

    @Test func `going back while the next photo is read finds the sidecar read again`() async throws {
        let (model, reads, a, b, cleanup) = try await openReadOnly()
        defer { cleanup() }
        model.select(a)
        try await eventually { model.info?.url == a && model.isReadOnly }
        try #require(model.isReadOnly)

        reads.hold()
        model.select(b)
        try await eventually { reads.arrived > 0 }
        try #require(model.opening == b)
        try await Task.sleep(for: .milliseconds(300))
        model.select(a)
        #expect(model.opening == nil && model.selection == a)
        try await eventually { !model.isReadOnly && model.recipe[.exposure] == 1 }
        #expect(!model.isReadOnly)
        #expect(model.recipe[.exposure] == 1)
        reads.release()
    }

    @Test func `a photo shown before its sidecar is read is read-only until it reads`() async throws {
        let (model, reads, a, b, cleanup) = try await openReadOnly(patience: .milliseconds(20), failures: [])
        defer { cleanup() }
        model.select(b)
        try await eventually { model.info?.url == b }
        let presenter = FailingPresenter(SidecarStore().url(for: a), failures: [true])
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        reads.hold()
        model.beforeReadingSidecar = { _ in await reads.pass() }
        model.select(a)
        try await eventually { model.selection == a && model.opening == nil }
        #expect(model.isLoading, "its thumbnail, until the read is done")
        reads.release()
        try await eventually { model.info?.url == a && model.isReadOnly }
        #expect(model.readOnlyReason == .unreadable)
        try await eventually { !model.isReadOnly && model.recipe[.exposure] == 1 }
        #expect(model.recipe[.exposure] == 1)
    }

    @Test func `leaving a photo stops reading its sidecar again`() async throws {
        let (model, _, a, b, cleanup) = try await openReadOnly()
        defer { cleanup() }
        model.sidecarReadRetryDelay = .milliseconds(200)
        model.select(a)
        try await eventually { model.info?.url == a && model.isReadOnly }
        model.select(b)
        try await eventually { model.info?.url == b }
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.selection == b && model.info?.url == b, "the read of A doesn't open it")

        model.select(a)
        try await eventually { model.info?.url == a && !model.isReadOnly }
        #expect(model.recipe[.exposure] == 1, "read as it opens again")
    }
}
