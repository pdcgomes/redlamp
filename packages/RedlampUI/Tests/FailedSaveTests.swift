import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
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
        try await eventually { model.info?.url == url }
        try #require(model.info?.url == url)
    }

    /// Waits for `condition`, which the save queue's results make true on the main actor.
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
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

    @Test func `a session whose save failed again after reopening keeps its history`() async throws {
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
        model.setValue(.contrast, 20)
        try await open(folder.other, in: model)
        await model.saves.flush()
        try await eventually { model.failedSaves[folder.photo] != nil }

        try folder.unlock()
        model.retrySave()
        await model.saves.flush()
        try await eventually { model.saveError == nil }
        let sessions = SidecarStore().loadHistory(for: folder.photo)
        #expect(sessions.count == 2, "both visits' history")
        #expect(sessions.contains { $0.steps.contains { $0.recipe[.exposure] == 0.6 && $0.recipe[.contrast] == 0 } })
        #expect(sessions.contains { $0.steps.contains { $0.recipe[.contrast] == 20 } })
        #expect(SidecarStore().load(for: folder.photo)?.recipe[.contrast] == 20)
    }

    @Test func `while its saves fail, the open photo shows another writer's edit merged`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let store = SidecarStore()
        var seeded = EditRecipe()
        seeded[.exposure] = 0.3
        try store.save(Sidecar(recipe: seeded), for: folder.photo)
        let package = store.url(for: folder.photo)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path) }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        var recipe = seeded
        recipe[.contrast] = 40
        let theirs = Sidecar(
            recipe: recipe,
            metadata: PhotoMetadata(rating: 5),
            modified: Date(timeIntervalSinceNow: 60),
        )
        try store.save(theirs, for: folder.photo)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.path)
        model.setValue(.exposure, 0.6)
        let ours = model.recipe
        model.saveNow()
        await model.saves.flush()
        try await eventually { model.saveError != nil && model.photoMetadata.rating == 5 }
        #expect(model.saveError?.canRetry == true)
        #expect(model.recipe == theirs.recipe, "theirs is newer")
        #expect(model.photoMetadata.rating == 5)
        #expect(model.snapshots.contains { $0.recipe == ours }, "ours kept as a snapshot")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path)
        model.retrySave()
        await model.saves.flush()
        try await eventually { model.saveError == nil }
        let saved = try #require(store.load(for: folder.photo))
        #expect(saved.recipe == theirs.recipe)
        #expect(saved.metadata?.rating == 5)
        #expect(saved.snapshots.filter { $0.recipe == ours }.count == 1)
        #expect(model.recipe == saved.recipe)
        #expect(model.snapshots.map(\.id) == saved.snapshots.map(\.id))
        #expect(model.snapshots.map(\.recipe) == saved.snapshots.map(\.recipe))
    }

    /// Another app presenting the sidecar: the first writer waits for `held` before it may write and
    /// the second for `overtaking`; the first read after the first writer runs `afterWrite`.
    private final class HoldingPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        let held = DispatchSemaphore(value: 0)
        let overtaking = DispatchSemaphore(value: 0)
        let asked = Mutex(0)
        let afterWrite: Mutex<(@Sendable () -> Void)?>

        init(_ url: URL, afterWrite: @escaping @Sendable () -> Void) {
            presentedItemURL = url
            self.afterWrite = Mutex(afterWrite)
        }

        func relinquishPresentedItem(toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
            let count = asked.withLock { count in
                count += 1
                return count
            }
            if count == 1 {
                held.wait()
            } else if count == 2 {
                overtaking.wait()
            }
            writer(nil)
        }

        func savePresentedItemChanges(completionHandler: @escaping @Sendable (Error?) -> Void) {
            if asked.withLock({ $0 }) > 0, let run = afterWrite.withLock({ run in
                defer { run = nil }
                return run
            }) {
                run()
            }
            completionHandler(nil)
        }
    }

    @Test func `a failed save a later one has overtaken leaves the editor as it is`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let store = SidecarStore()
        var seeded = EditRecipe()
        seeded[.exposure] = 0.3
        try store.save(Sidecar(recipe: seeded), for: folder.photo)
        let package = store.url(for: folder.photo)
        let path = package.path
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)
        var recipe = seeded
        recipe[.vibrance] = 30
        let theirs = Sidecar(
            recipe: recipe,
            metadata: PhotoMetadata(rating: 5),
            modified: Date(timeIntervalSinceNow: -60),
        )
        try store.save(theirs, for: folder.photo)
        let presenter = HoldingPresenter(package) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        NSFileCoordinator.addFilePresenter(presenter)
        defer {
            presenter.held.signal()
            presenter.overtaking.signal()
        }

        model.setValue(.exposure, 0.6)
        model.saveNow()
        try await eventually { presenter.asked.withLock { $0 } == 1 }
        try #require(presenter.asked.withLock { $0 } == 1, "the first save is being written")
        model.setValue(.contrast, 20)
        model.saveNow()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        presenter.held.signal()
        try await eventually { presenter.asked.withLock { $0 } == 2 }
        try #require(presenter.asked.withLock { $0 } == 2, "the second save is being written")
        try #require(presenter.afterWrite.withLock { $0 == nil }, "the first save failed and was read over")
        try await eventually { model.saveError != nil }
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.recipe[.contrast] == 20, "the later change stays on screen")
        #expect(model.recipe[.exposure] == 0.6)

        presenter.overtaking.signal()
        await model.saves.flush()
        try await eventually { model.saveError == nil }
        await Task.detached { NSFileCoordinator.removeFilePresenter(presenter) }.value
        #expect(model.saveError == nil, "the second save went through")
        #expect(model.recipe[.contrast] == 20)
        #expect(model.recipe[.exposure] == 0.6)
        let saved = try #require(store.load(for: folder.photo))
        #expect(saved.recipe[.contrast] == 20, "and on disk")
        #expect(saved.recipe[.exposure] == 0.6)
        #expect(saved.metadata?.rating == 5)
    }

    @Test func `the unsaved sessions kept are no more than a sidecar keeps`() {
        let writes = (0 ..< SidecarStore.keptSessions + 5).map { index in
            let step = HistoryStep(action: .edit, title: "Exposure", recipe: EditRecipe())
            let session = HistorySession(
                id: UUID(), started: Date(timeIntervalSince1970: Double(index)),
                steps: [HistoryStep(action: .open, title: "Opened", recipe: EditRecipe()), step],
            )
            return SaveQueue.Write.sidecar(Sidecar(recipe: EditRecipe(), session: session))
        }
        let sessions = EditorModel.sessions(in: writes)
        #expect(sessions.count == SidecarStore.keptSessions - 1)
        #expect(sessions.first?.started == Date(timeIntervalSince1970: 6), "the newest")
    }
}
