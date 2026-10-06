import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// Undo Sync, Paste from Previous and Remove Dust across a selection read and write sidecars off
/// the main actor: on a busy disk, or with another app's file presenter slow to let go, one
/// coordinated read or write can take seconds (RESP-14).
@MainActor
struct SidecarIOOffMainTests {
    /// Holds each coordinated read or write of a sidecar for `delay`, as a slow file presenter does.
    final class SlowPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        let delay: TimeInterval

        init(_ url: URL, delay: TimeInterval = 1) {
            presentedItemURL = url
            self.delay = delay
        }

        func savePresentedItemChanges(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
            Thread.sleep(forTimeInterval: delay)
            completionHandler(nil)
        }
    }

    /// Far less than the presenter's hold, and far more than a loaded machine's hiccups.
    private let mostHeld = Duration.milliseconds(500)

    private func folder(_ names: [String]) throws -> ([URL], () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (names.map { folder.appending(path: "\($0).ARW") }, { try? FileManager.default.removeItem(at: folder) })
    }

    private func open(_ model: EditorModel, _ url: URL) async throws {
        model.select(url)
        for _ in 0 ..< 2000 where model.info?.url != url || model.isReadOnly {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info?.url == url)
    }

    /// Off the main actor: removing a presenter waits for the coordinations it is part of.
    private func slowing(_ urls: [URL]) -> () async -> Void {
        let presenters = urls.map { SlowPresenter(SidecarStore().url(for: $0)) }
        presenters.forEach(NSFileCoordinator.addFilePresenter)
        return { await Task.detached { presenters.forEach(NSFileCoordinator.removeFilePresenter) }.value }
    }

    @Test func `Undo Sync puts the photos back without holding the main actor`() async throws {
        let (photos, cleanup) = try folder(["A", "B"])
        defer { cleanup() }
        let model = EditorModel(engine: StubEngine())
        photos.forEach { model.library.insert(LibraryItem(url: $0)) }
        model.copySelection = .default
        defer { model.copySelection = .default }
        try await open(model, photos[0])
        model.setValue(.exposure, 1)
        model.selectAllPhotos()
        model.syncSettings()
        await model.settingsSync.idle()
        try #require(SidecarStore().load(for: photos[1])?.recipe[.exposure] == 1)

        let stopSlowing = slowing([photos[1]])
        let started = ContinuousClock.now
        model.undoSync()
        let held = ContinuousClock.now - started
        #expect(held < mostHeld)
        #expect(!model.settingsSync.canUndo)
        await model.settingsSync.idle()
        await stopSlowing()
        #expect(SidecarStore().load(for: photos[1]) == nil, "the sidecar the sync made is removed")
    }

    @Test func `Paste from Previous reads the previous photo's edit without holding the main actor`() async throws {
        let (photos, cleanup) = try folder(["A", "B"])
        defer { cleanup() }
        var edited = EditRecipe()
        edited[.exposure] = 2
        try SidecarStore().save(Sidecar(recipe: edited), for: photos[1])
        let model = EditorModel(engine: StubEngine())
        photos.forEach { model.library.insert(LibraryItem(url: $0)) }
        model.copySelection = .default
        defer { model.copySelection = .default }
        try await open(model, photos[1])
        try await open(model, photos[0])
        try #require(model.previousSelection == photos[1])

        let stopSlowing = slowing([photos[1]])
        let started = ContinuousClock.now
        model.pasteFromPrevious()
        let held = ContinuousClock.now - started
        #expect(held < mostHeld)
        for _ in 0 ..< 2000 where model.recipe[.exposure] != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        await stopSlowing()
        #expect(model.recipe[.exposure] == 2)
        #expect(model.history.last?.name == "Paste from Previous")
    }

    @Test func `Remove Dust across a selection reads the photos' edits without holding the main actor`() async throws {
        let (photos, cleanup) = try folder(["A", "B", "C"])
        defer { cleanup() }
        var edited = EditRecipe()
        edited[.exposure] = 0.5
        for url in photos.dropFirst() {
            try SidecarStore().save(Sidecar(recipe: edited), for: url)
        }
        let speck = DetectedSpot(center: ImagePoint(x: 0.3, y: 0.2), radius: 0.01, strength: 20)
        let worker = StubEngine()
        worker.shootDust = [photos[0]: [speck], photos[1]: [speck]]
        let model = EditorModel(engine: StubEngine())
        model.makeWorkerEngine = { worker }
        photos.forEach { model.library.insert(LibraryItem(url: $0)) }
        try await open(model, photos[0])
        model.selectAllPhotos()
        model.activeTool = .heal

        let stopSlowing = slowing(Array(photos.dropFirst()))
        let removing = Task { await model.removeDustInSelection() }
        let started = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(10))
        let held = ContinuousClock.now - started
        #expect(held < mostHeld)
        await removing.value
        await model.settingsSync.idle()
        await stopSlowing()
        #expect(worker.shootPhotos == photos)
        let healed = try #require(SidecarStore().load(for: photos[1]))
        #expect(healed.recipe.spots.map(\.center) == [speck.center])
        #expect(healed.recipe[.exposure] == 0.5, "found in, and healed over, B's own edit")
    }
}
