import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampUI

/// Several photos selected in the filmstrip: ⌘ adds or takes away, ⇧ selects a range, a plain
/// click or the next photo selects one.
@MainActor
struct PhotoSelectionTests {
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
        #expect(model.selection == photos[3], "taking away another photo keeps the active one")
        model.click(photos[3], toggling: true)
        #expect(model.selectedPhotos == [photos[1]])
        #expect(model.selection == photos[1], "taking away the active photo makes another active")
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

    /// Photos A and B, decoded ahead, in a temporary folder; A open.
    private struct Decoded {
        let model: EditorModel
        let engine: StubEngine
        let a: URL
        let b: URL
        let cleanup: () -> Void
    }

    private func openDecoded() async throws -> Decoded {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (a, b) = (folder.appending(path: "A.ARW"), folder.appending(path: "B.ARW"))
        let engine = StubEngine()
        engine.ready = [a, b]
        let model = EditorModel(engine: engine)
        [a, b].forEach { model.library.insert(LibraryItem(url: $0)) }
        model.select(a)
        try await opened(a, in: model)
        return Decoded(model: model, engine: engine, a: a, b: b) { try? FileManager.default.removeItem(at: folder) }
    }

    private func opened(_ url: URL, in model: EditorModel) async throws {
        for _ in 0 ..< 200 where model.info?.url != url {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info?.url == url)
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

    @Test func `an edit made while the next photo's edit is read stays with the photo it was made on`() async throws {
        let photos = try await openDecoded()
        defer { photos.cleanup() }
        let (model, engine, a, b) = (photos.model, photos.engine, photos.a, photos.b)

        model.select(b)
        model.setValue(.exposure, 1)
        #expect(engine.lastRender?.recipe[.exposure] != 1, "A's edit isn't rendered over B")
        try await opened(b, in: model)
        #expect(model.recipe[.exposure] == 0)
        await model.saves.wait(for: a)
        await model.saves.wait(for: b)
        #expect(SidecarStore().load(for: a)?.recipe[.exposure] == 1)
        #expect((SidecarStore().load(for: b)?.recipe[.exposure] ?? 0) == 0)
    }

    @Test func `going back before the next photo is read keeps the first one open`() async throws {
        let photos = try await openDecoded()
        defer { photos.cleanup() }
        let (model, a, b) = (photos.model, photos.a, photos.b)

        model.select(b)
        model.select(a)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.selection == a && model.info?.url == a)
    }
}
