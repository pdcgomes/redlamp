import Foundation
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampUI

/// The editor window closed and opened again: the engine lets go of the photo meanwhile, and
/// decodes it again for the window.
@MainActor
struct EditorWindowTests {
    @Test func `closing the window releases the engine, and reopening it opens the photo again`() async throws {
        let engine = StubEngine()
        let model = EditorModel(engine: engine)
        let photo = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/A.ARW")
        model.library.insert(LibraryItem(url: photo))
        model.select(photo)
        for _ in 0 ..< 400 where model.info?.url != photo {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.info?.url == photo)

        model.windowClosed()
        for _ in 0 ..< 400 where engine.releases.withLock({ $0 }) == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(engine.releases.withLock { $0 } == 1)
        #expect(!model.hasFrame)
        #expect(model.info?.url == photo, "the edit stays open")

        let opens = engine.opened.withLock { $0.count }
        let renders = engine.renders.count
        model.windowReopened()
        for _ in 0 ..< 400 where engine.renders.count == renders {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(engine.opened.withLock { Array($0.dropFirst(opens)) } == [photo])
        #expect(engine.renders.count > renders)
    }

    /// Shown again before the engine let go: nothing to open again.
    @Test func `a window shown again at once keeps its photo`() async throws {
        let engine = StubEngine()
        let model = EditorModel(engine: engine)
        model.windowReopened()
        model.windowClosed()
        model.windowReopened()
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.releases.withLock { $0 } == 0)
        #expect(engine.opened.withLock { $0.isEmpty })
    }
}
