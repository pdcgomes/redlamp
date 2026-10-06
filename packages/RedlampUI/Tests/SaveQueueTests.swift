import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// Saves land in the order they were made: what is on disk once they have is what the editor
/// shows, however fast the edits, ratings and photo changes come.
@MainActor
struct SaveQueueTests {
    private struct Folder {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

        var photo: URL {
            url.appending(path: "IMG_0001.ARW")
        }

        var other: URL {
            url.appending(path: "IMG_0002.ARW")
        }

        var saved: Sidecar? {
            SidecarStore().load(for: photo)
        }

        init() throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func remove() {
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

    @Test func `rapid edits each saved at once leave the last on disk`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        for round in 1 ... 100 {
            for step in 1 ... 6 {
                model.setValue(.exposure, Double(round * 6 + step) / 1000)
                model.saveNow()
            }
            await model.saves.flush()
            #expect(folder.saved?.recipe == model.recipe, "round \(round)")
        }
    }

    @Test func `edits that never pause are saved while they go on`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        let deadline = ContinuousClock.now + .seconds(30)
        var step = 0
        while folder.saved == nil, ContinuousClock.now < deadline {
            step += 1
            model.setValue(.exposure, Double(step % 20) / 10)
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(folder.saved != nil, "saved while the edits went on")
    }

    @Test func `a drag is saved once it pauses`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        model.beginEdit(.exposure)
        var longest = Duration.zero
        var last = ContinuousClock.now
        for step in 1 ... 30 {
            model.setSliderValue(.exposure, Double(step) / 10)
            try await Task.sleep(for: .milliseconds(100))
            longest = max(longest, .now - last)
            last = .now
        }
        model.endEdit()
        // A step that stalls (under load) for the 600 ms a save waits is a pause, and saves.
        if longest < .milliseconds(600) {
            #expect(folder.saved == nil, "not while it moved")
        }
        try await eventually { folder.saved?.recipe == model.recipe }
        #expect(folder.saved?.recipe == model.recipe)
    }

    @Test func `a rating and a flag set as the photo opens both reach the file`() async throws {
        for round in 1 ... 20 {
            let folder = try Folder()
            defer { folder.remove() }
            let model = EditorModel(engine: StubEngine())
            model.library.insert(LibraryItem(url: folder.photo))

            model.select(folder.photo)
            _ = model.perform(.rating3)
            _ = model.perform(.flagPick)
            try await open(folder.photo, in: model)
            await model.saves.flush()
            #expect(folder.saved?.metadata == PhotoMetadata(rating: 3, flag: .pick), "round \(round)")
            #expect(model.currentMetadata == PhotoMetadata(rating: 3, flag: .pick))
        }
    }

    @Test func `the same field set twice as the photo opens keeps the later value`() async throws {
        for round in 1 ... 20 {
            let folder = try Folder()
            defer { folder.remove() }
            let model = EditorModel(engine: StubEngine())
            model.library.insert(LibraryItem(url: folder.photo))

            model.select(folder.photo)
            _ = model.perform(.rating3)
            _ = model.perform(.rating5)
            try await open(folder.photo, in: model)
            await model.saves.flush()
            #expect(folder.saved?.metadata?.rating == 5, "round \(round)")
        }
    }

    @Test func `a rating set as the photo opens never lands over a later edit`() async throws {
        for round in 1 ... 20 {
            let folder = try Folder()
            defer { folder.remove() }
            let model = EditorModel(engine: StubEngine())
            model.library.insert(LibraryItem(url: folder.photo))

            model.select(folder.photo)
            _ = model.perform(.rating3)
            try await open(folder.photo, in: model)
            model.setValue(.exposure, 0.5)
            model.saveNow()
            await model.saves.flush()
            #expect(folder.saved?.recipe == model.recipe, "round \(round)")
            #expect(folder.saved?.metadata?.rating == 3, "round \(round)")
        }
    }

    @Test func `leaving a photo and coming back reads what was just saved`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        for round in 1 ... 20 {
            model.setValue(.exposure, Double(round) / 10)
            let edited = model.recipe
            try await open(folder.other, in: model)
            try await open(folder.photo, in: model)
            #expect(model.recipe == edited, "round \(round)")
        }
    }

    @Test func `quitting right after an edit saves it first`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        model.setValue(.exposure, 0.7)
        #expect(model.saveBeforeQuitting(within: .seconds(30)) == .saved)
        #expect(folder.saved?.recipe == model.recipe)
    }

    @Test func `quitting waits no longer than its limit for a disk that doesn't answer`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        model.saves.enqueue(.metadata { _ in gate.wait() }, for: folder.other)
        model.setValue(.exposure, 0.7)
        let start = ContinuousClock.now
        #expect(model.saveBeforeQuitting(within: .milliseconds(300)) == .timedOut)
        #expect(ContinuousClock.now - start >= .milliseconds(300))
    }

    @Test func `a photo's last save is reported even when it is tracked again before the editor hears`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let model = EditorModel(engine: StubEngine())
        try await open(folder.photo, in: model)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.url.path) }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        model.setValue(.exposure, 0.8)
        model.saveNow()
        model.saves.enqueue(.metadata { _ in gate.wait() }, for: folder.other)
        model.saves.enqueue(.track(nil, opened: Sidecar(recipe: EditRecipe())), for: folder.photo)
        try await eventually { model.saveError != nil }
        #expect(model.saveError?.url == folder.photo)
    }

    @Test func `writes run in order on the queue's own thread, and reads after them`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let queue = SaveQueue(store: SidecarStore())
        var last = EditRecipe()
        for step in 1 ... 50 {
            last[.exposure] = Double(step) / 100
            queue.enqueue(.sidecar(Sidecar(recipe: last)), for: folder.photo)
            queue.enqueue(.metadata { $0.rating = step % 6 }, for: folder.photo)
        }
        let (read, label) = await queue.read { [photo = folder.photo] in
            (SidecarStore().load(for: photo), String(cString: __dispatch_queue_get_label(nil)))
        }
        #expect(read?.recipe == last)
        #expect(read?.metadata?.rating == 50 % 6)
        #expect(label == SaveQueue.label)
    }

    @Test func `waiting for one photo's saves returns once they have landed`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let queue = SaveQueue(store: SidecarStore())
        await queue.wait(for: folder.photo)

        var recipe = EditRecipe()
        recipe[.exposure] = 1
        queue.enqueue(.sidecar(Sidecar(recipe: recipe)), for: folder.photo)
        await queue.wait(for: folder.photo)
        #expect(folder.saved?.recipe == recipe)
    }

    @Test func `a save that replaces a waiting one keeps its Clear History`() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let store = SidecarStore()
        var recipe = EditRecipe()
        recipe[.exposure] = 1
        let earlier = HistorySession(steps: [
            HistoryStep(action: .open, title: "Opened", recipe: EditRecipe()),
            HistoryStep(action: .adjustment(.exposure), title: "Exposure", recipe: recipe),
        ])
        var first = Sidecar(recipe: recipe, session: earlier)
        try store.saveOrRemove(first, for: folder.photo)
        #expect(store.loadHistory(for: folder.photo).count == 1)

        let queue = SaveQueue(store: store)
        let session = HistorySession(steps: [HistoryStep(action: .clear, title: "History Cleared", recipe: recipe)])
        // Held up behind a write of another photo, so the two below coalesce.
        let gate = DispatchSemaphore(value: 0)
        queue.enqueue(.metadata { _ in gate.wait() }, for: folder.other)
        first = Sidecar(recipe: recipe, session: session)
        first.clearsHistory = true
        queue.enqueue(.sidecar(first), for: folder.photo)
        recipe[.exposure] = 2
        queue.enqueue(.sidecar(Sidecar(recipe: recipe, session: session)), for: folder.photo)
        gate.signal()
        await queue.flush()
        #expect(folder.saved?.recipe == recipe)
        #expect(store.loadHistory(for: folder.photo).allSatisfy { $0.id == session.id })
    }
}
