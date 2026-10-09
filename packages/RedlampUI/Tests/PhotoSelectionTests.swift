import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampUI

/// The photos whose sidecars were read, in order.
private final class ReadLog: Sendable {
    private let read = Mutex<[URL]>([])

    func add(_ url: URL) {
        read.withLock { $0.append(url) }
    }

    var urls: [URL] {
        read.withLock { $0 }
    }
}

/// Several photos selected in the filmstrip: ⌘ adds or takes away, ⇧ selects a range, a plain
/// click or the next photo selects one.
@MainActor
struct PhotoSelectionTests {
    /// 20,000 photos in Library, all of them selected.
    private func allSelected() -> (EditorModel, [URL]) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = EditorModel(engine: StubEngine())
        model.showModule(.library)
        let photos = (0 ..< 20000).map { folder.appending(path: String(format: "IMG_%05d.ARW", $0)) }
        model.library.replace(with: photos.map { LibraryItem(url: $0) })
        model.select(photos[0])
        model.selectAllPhotos()
        return (model, photos)
    }

    @Test func `selecting all of 20,000 photos selects every one, in the filmstrip's order`() {
        let (model, photos) = allSelected()
        #expect(model.selectedPhotos == photos)
        #expect(model.selectedRows == Array(photos.indices))
    }

    @Test(.measuresSpeed)
    func `the photos selected are read with one read of the selection, as a panel's view reads them`() {
        let (model, _) = allSelected()
        /// Each read of the selection inside a view's body is an observed access, which `selectedRows` makes once.
        func median(_ read: () -> Void) -> Duration {
            let clock = ContinuousClock()
            var times: [Duration] = []
            for _ in 0 ..< 9 {
                let start = clock.now
                withObservationTracking(read) {}
                times.append(clock.now - start)
            }
            return times.sorted()[times.count / 2]
        }
        let photosRead = median { _ = model.selectedPhotos }
        let rowsRead = median { _ = model.selectedRows }
        #expect(photosRead < rowsRead * 3 + .milliseconds(1), "selectedPhotos \(photosRead), selectedRows \(rowsRead)")
    }

    @Test func `clicks select several photos, the clicked one active`() {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = EditorModel(engine: StubEngine())
        let photos = ["A", "B", "C", "D", "E"].map { folder.appending(path: "\($0).ARW") }
        photos.forEach { model.library.insert(LibraryItem(url: $0)) }

        model.click(photos[1])
        #expect(model.selectedPhotos == [photos[1]] && !model.isMultiSelecting)
        model.click(photos[3], toggling: true)
        #expect(model.selectedPhotos == [photos[1], photos[3]])
        #expect(model.selection == photos[3], "the clicked photo is active")
        model.click(photos[0], toggling: true)
        #expect(model.selectedPhotos == [photos[0], photos[1], photos[3]], "in filmstrip order")

        model.click(photos[0], toggling: true)
        #expect(model.selectedPhotos == [photos[1], photos[3]])
        #expect(
            model.selection == photos[1],
            "taking away the active photo makes the nearest selected one after it active",
        )
        model.click(photos[3], toggling: true)
        #expect(model.selectedPhotos == [photos[1]])
        #expect(model.selection == photos[1], "taking away another photo keeps the active one")
        #expect(model.photoSelection.count == 1 && model.photoSelection.active == model.library.photoID(of: photos[1]))
        model.click(photos[1], toggling: true)
        #expect(model.selectedPhotos == [photos[1]], "the last photo stays selected")

        model.click(photos[4], extending: true)
        #expect(model.selectedPhotos == Array(photos[1 ... 4]))
        #expect(model.selection == photos[4])

        model.deselectOtherPhotos()
        #expect(model.selectedPhotos == [photos[4]])
        model.selectAllPhotos()
        #expect(model.selectedPhotos == photos && model.selection == photos[4])
        model.selectPrevious()
        #expect(model.selectedPhotos == [photos[3]], "moving to another photo selects only it")
        model.click(photos[3])
        #expect(model.selectedPhotos == [photos[3]])
    }

    /// Photos A, B and C, decoded ahead, in a temporary folder; A open. Sidecar reads wait at
    /// `reads` while it is held, and the editor waits for them for as long as `patience`.
    private struct Decoded {
        let model: EditorModel
        let engine: GatedEngine
        let reads: Gate
        let a: URL
        let b: URL
        let c: URL
        let cleanup: () -> Void
    }

    private func openDecoded(patience: Duration = .seconds(30)) async throws -> Decoded {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (a, b, c) = (
            folder.appending(path: "A.ARW"),
            folder.appending(path: "B.ARW"),
            folder.appending(path: "C.ARW"),
        )
        let engine = GatedEngine()
        engine.base.ready = [a, b, c]
        let reads = Gate()
        let model = EditorModel(engine: engine)
        model.openingPatience = patience
        model.beforeReadingSidecar = { _ in await reads.pass() }
        [a, b, c].forEach { model.library.insert(LibraryItem(url: $0)) }
        model.select(a)
        try await opened(a, in: model)
        return Decoded(model: model, engine: engine, reads: reads, a: a, b: b, c: c) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Waits for `condition` for up to 30 s: an open, or a read let go, can take seconds on a busy Mac.
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func opened(_ url: URL, in model: EditorModel) async throws {
        try await eventually { model.info?.url == url }
        try #require(model.info?.url == url)
    }

    /// Holds sidecar reads, selects `url` (or does `start`), and waits until its read is held.
    private func startOpening(
        _ url: URL? = nil,
        in photos: Decoded,
        by start: (EditorModel) -> Void = { _ in },
    ) async throws {
        photos.reads.hold()
        if let url {
            photos.model.select(url)
        }
        start(photos.model)
        try await eventually { photos.reads.arrived > 0 }
        try #require(photos.reads.arrived > 0, "the read is held")
    }

    @Test func `switching to a decoded photo changes the editor once, never to no photo`() async throws {
        let photos = try await openDecoded()
        defer { photos.cleanup() }
        let (model, a, b) = (photos.model, photos.a, photos.b)
        let changes = Mutex<[String]>([])
        withObservationTracking { _ = model.info } onChange: { changes.withLock { $0.append("info") } }
        withObservationTracking { _ = model.recipeApplication == nil } onChange: {
            changes.withLock { $0.append("recipeApplication") }
        }

        model.select(b)
        #expect(model.info?.url == a, "A stays in the editor until B's edit is read")
        #expect(model.selection == a)
        try await opened(b, in: model)
        #expect(model.selection == b && model.selectedPhotos == [b])
        #expect(changes.withLock { $0 } == ["info"], "info changes once, and an empty recipeApplication not at all")
    }

    @Test func `nothing is edited while the next photo's edit is read`() async throws {
        let photos = try await openDecoded()
        defer { photos.cleanup() }
        let (model, engine, a, b) = (photos.model, photos.engine, photos.a, photos.b)
        let rendered = engine.base.lastRender

        try await startOpening(b, in: photos)
        model.setValue(.exposure, 1)
        model.undo()
        #expect(model.recipe[.exposure] == 0 && model.history.count == 1, "A's edit stays as it was")
        #expect(engine.base.lastRender == rendered, "nothing renders over B")
        photos.reads.release()
        try await opened(b, in: model)
        #expect(model.recipe[.exposure] == 0)
        await model.saves.wait(for: a)
        await model.saves.wait(for: b)
        #expect((SidecarStore().load(for: a)?.recipe[.exposure] ?? 0) == 0)
        #expect((SidecarStore().load(for: b)?.recipe[.exposure] ?? 0) == 0)
    }

    @Test func `going back before the next photo is read keeps the first one as it was`() async throws {
        let photos = try await openDecoded()
        defer { photos.cleanup() }
        let (model, engine, a, b) = (photos.model, photos.engine, photos.a, photos.b)
        model.setValue(.exposure, 1)
        let steps = model.history.count

        try await startOpening(b, in: photos)
        model.select(a)
        photos.reads.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.selection == a && model.info?.url == a)
        #expect(model.recipe[.exposure] == 1 && model.history.count == steps, "the edit stays, read again over nothing")
        #expect(!model.hasUnmergedEdits)
        #expect(engine.base.lastRender?.recipe[.exposure] == 1, "A renders again")
        await model.saves.wait(for: a)
        #expect(SidecarStore().load(for: a)?.recipe[.exposure] == 1)
    }

    @Test func `going back before the next photo is read doesn't read the first one again`() async throws {
        let photos = try await openDecoded()
        defer { photos.cleanup() }
        let (model, a, b, reads) = (photos.model, photos.a, photos.b, photos.reads)
        let read = ReadLog()
        model.beforeReadingSidecar = { url in
            read.add(url)
            if url == b {
                await reads.pass()
            }
        }
        model.setValue(.exposure, 1)
        let steps = model.history.count

        try await startOpening(b, in: photos)
        model.select(a)
        reads.release()
        try await Task.sleep(for: .milliseconds(200))
        #expect(read.urls == [b], "A isn't read again")
        #expect(model.info?.url == a && model.selection == a, "B's late read leaves the editor alone")
        #expect(model.recipe[.exposure] == 1 && model.history.count == steps)
        #expect(!model.hasUnmergedEdits)
    }

    @Test func `going back before the next photo is read drops what was started on the first one`() async throws {
        let photos = try await openDecoded()
        defer { photos.cleanup() }
        let (model, engine, a, b) = (photos.model, photos.engine, photos.a, photos.b)
        engine.gate.hold()
        model.autoTone()
        try await eventually { engine.gate.arrived > 0 }
        try #require(engine.gate.arrived > 0)

        try await startOpening(b, in: photos)
        model.select(a)
        photos.reads.release()
        engine.gate.release()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.info?.url == a)
        #expect(model.recipe[.exposure] == 0, "Auto Tone may have read B meanwhile")
    }

    @Test func `another writer's edit adopted while the next photo is read is kept on going back`() async throws {
        let photos = try await openDecoded()
        defer { photos.cleanup() }
        let (model, a, b) = (photos.model, photos.a, photos.b)
        await model.saves.wait(for: a)
        var recipe = EditRecipe()
        recipe[.contrast] = 40
        try SidecarStore().save(Sidecar(recipe: recipe, metadata: PhotoMetadata(rating: 5)), for: a)
        let base = SidecarStore().loadWithBase(for: a).base

        try await startOpening(b, in: photos)
        model.adopt(base, for: a)
        #expect(model.recipe[.contrast] == 0, "not shown while B is being read")
        model.select(a)
        photos.reads.release()
        try await Task.sleep(for: .milliseconds(200))
        try await eventually { model.recipe[.contrast] == 40 }
        #expect(model.info?.url == a && model.selection == a)
        #expect(model.recipe[.contrast] == 40)
        #expect(model.currentMetadata.rating == 5)
        #expect(model.history.last?.name == "Edit from Another Mac")
        await model.saves.wait(for: a)
        #expect(SidecarStore().load(for: a)?.recipe[.contrast] == 40, "their edit stays as they left it")
    }

    @Test func `snapshots and Clear History wait for the next photo's read`() async throws {
        let photos = try await openDecoded()
        defer { photos.cleanup() }
        let (model, b) = (photos.model, photos.b)
        model.setValue(.exposure, 1)
        let steps = model.history.count

        try await startOpening(b, in: photos)
        model.createSnapshot()
        model.clearHistory()
        #expect(model.snapshots.isEmpty && model.history.count == steps)
        photos.reads.release()
        try await opened(b, in: model)
    }

    @Test func `while the next photo is read, Previous and Next are its neighbours'`() async throws {
        let photos = try await openDecoded()
        defer { photos.cleanup() }
        let model = photos.model
        #expect(!model.canPerform(.previousPhoto), "A is first")

        try await startOpening(photos.b, in: photos)
        #expect(model.canPerform(.previousPhoto) && model.canPerform(.nextPhoto), "B's are A and C")
        try await startOpening(photos.c, in: photos)
        #expect(model.canPerform(.previousPhoto) && !model.canPerform(.nextPhoto), "C is last")
        photos.reads.release()
        try await opened(photos.c, in: model)
    }

    @Test func `the menus are told when a switch starts waiting for its read`() async throws {
        let photos = try await openDecoded()
        defer { photos.cleanup() }
        let model = photos.model
        let changed = Mutex(false)
        withObservationTracking { _ = model.canPerform(.previousPhoto) } onChange: {
            changed.withLock { $0 = true }
        }

        try await startOpening(photos.b, in: photos)
        #expect(changed.withLock { $0 }, "before B's read is done")
        photos.reads.release()
        try await opened(photos.b, in: model)
    }

    @Test func `the first photo opened can be rated while its edit is read`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appending(path: "A.ARW")
        let engine = StubEngine()
        engine.ready = [a]
        let reads = Gate()
        let model = EditorModel(engine: engine)
        model.openingPatience = .seconds(30)
        model.beforeReadingSidecar = { _ in await reads.pass() }
        model.library.insert(LibraryItem(url: a))

        reads.hold()
        model.select(a)
        #expect(model.selection == nil && model.canPerform(.rating3))
        reads.release()
        try await opened(a, in: model)
    }

    @Test func `a rating that fails on a protected photo being opened is left to its banner`() async throws {
        let photos = try await openDecoded()
        defer { photos.cleanup() }
        let (model, b) = (photos.model, photos.b)
        let package = SidecarStore().url(for: b)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(#"{"format":"app.redlamp.edit","recipe":{"version":1,"processVersion":1,"values":{"basic.expo"#.utf8)
            .write(to: package.appending(path: SidecarStore.editFile))

        try await startOpening(b, in: photos)
        _ = model.perform(.rating3)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.saveError == nil, "while B is read")
        photos.reads.release()
        try await opened(b, in: model)
        try await Task.sleep(for: .milliseconds(200))
        try await eventually { model.readOnlyReason == .damaged }
        #expect(model.readOnlyReason == .damaged)
        #expect(model.saveError == nil, "B's banner says why")
    }

    @Test func `rating and moving on while the next photo is read rates that photo`() async throws {
        let photos = try await openDecoded()
        defer { photos.cleanup() }
        let (model, a, b, c) = (photos.model, photos.a, photos.b, photos.c)

        try await startOpening(in: photos) { _ = $0.perform(.rating5, shifted: true) }
        #expect(model.info?.url == a, "B is being read")
        _ = model.perform(.rating1, shifted: true)
        photos.reads.release()
        try await opened(c, in: model)
        #expect(model.library.item(for: a)?.metadata.rating == 5)
        #expect(model.library.item(for: b)?.metadata.rating == 1)
        await model.saves.wait(for: a)
        await model.saves.wait(for: b)
        #expect(SidecarStore().load(for: a)?.metadata?.rating == 5)
        #expect(SidecarStore().load(for: b)?.metadata?.rating == 1)
    }

    @Test func `an edge stroke solved while the next photo is read leaves the first one's mask`() async throws {
        let photos = try await openDecoded()
        defer { photos.cleanup() }
        let (model, engine, a, b) = (photos.model, photos.engine, photos.a, photos.b)
        engine.base.computed = [AIMask(
            kind: .subject, provider: "stub", revision: 1, analysisHash: "h",
            center: ImagePoint(x: 0.5, y: 0.5), bitmap: MaskBitmap(sha256: "s", width: 4, height: 4),
        )]
        await model.createAIMask(.subject)
        let mask = try #require(model.recipe.masks.first)
        let component = try #require(mask.components.first)
        model.startRefiningEdges(component.id, in: mask.id)
        model.beginStroke(at: ImagePoint(x: 0.2, y: 0.2))
        model.continueStroke(to: ImagePoint(x: 0.4, y: 0.2))
        engine.gate.hold()
        let solving = Task { await model.endEdgeStroke() }
        try await eventually { engine.gate.arrived > 0 }
        try #require(engine.gate.arrived > 0)
        model.beginStroke(at: ImagePoint(x: 0.2, y: 0.6))
        model.continueStroke(to: ImagePoint(x: 0.4, y: 0.6))
        await model.endEdgeStroke()

        try await startOpening(b, in: photos)
        engine.gate.release()
        await solving.value
        #expect(engine.base.brushRefinements.count == 1, "the queued stroke isn't solved against B")
        guard case let .ai(kept) = model.recipe.masks.first?.components.first?.shape else {
            Issue.record("A lost its AI mask")
            return
        }
        #expect(kept.bitmap.sha256 == "s")
        photos.reads.release()
        try await opened(b, in: model)
        await model.saves.wait(for: a)
        guard case let .ai(saved) = SidecarStore().load(for: a)?.recipe.masks.first?.components.first?.shape else {
            Issue.record("A's mask wasn't saved")
            return
        }
        #expect(saved.bitmap.sha256 == "s")
    }

    @Test func `a slow read shows the next photo's thumbnail until it is read`() async throws {
        let photos = try await openDecoded(patience: .milliseconds(20))
        defer { photos.cleanup() }
        let (model, b) = (photos.model, photos.b)

        try await startOpening(b, in: photos)
        try await eventually { model.selection == b }
        #expect(model.selection == b && model.info == nil && model.isLoading, "B, waiting for its edit")
        photos.reads.release()
        try await opened(b, in: model)
        #expect(!model.isLoading)
    }
}
