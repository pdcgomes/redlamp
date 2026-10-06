import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// Merge to Focus Stack and Edit Focus Stack: the Photo menu's and the command palette's way
/// into the Stack workspace, besides the filmstrip's banner and its Stack… button.
@MainActor
struct FocusStackCommandTests: PaletteTesting {
    /// `count` empty frames in a new folder, in name order.
    private func frames(_ count: Int) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frames = (1 ... count).map { folder.appending(path: String(format: "IMG_%04d.ARW", $0)) }
        for frame in frames {
            try Data().write(to: frame)
        }
        return frames
    }

    private func remove(_ frames: [URL]) {
        try? FileManager.default.removeItem(at: frames[0].deletingLastPathComponent())
    }

    /// Five frames of one camera and a focus sweep across them, by file name, counting its calls.
    private final class SweepFiles: FileInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [(thumbnails: Bool, count: Int)] = []
        private let start = Date(timeIntervalSince1970: 1_800_000_000)

        var calls: [(thumbnails: Bool, count: Int)] {
            lock.withLock { asked }
        }

        private func frame(_ url: URL) -> Int? {
            Int(url.deletingPathExtension().lastPathComponent.dropFirst(4)).map { $0 - 1 }
        }

        func captures(of urls: [URL], concurrently _: Bool) -> [CaptureSettings?] {
            lock.withLock { asked.append((false, urls.count)) }
            return urls.map { url in
                frame(url).map { CaptureSettings(model: "Body", aperture: 4, date: start + Double($0) / 2) }
            }
        }

        /// A gentle gradient, with a fine checker sharp in frame `f`'s fifth of the width only.
        func focusThumbnails(of urls: [URL], concurrently _: Bool) -> [GreyThumbnail?] {
            lock.withLock { asked.append((true, urls.count)) }
            let (width, height) = (GreyThumbnail.longEdge, 128)
            return urls.map { url in
                frame(url).map { frame in
                    GreyThumbnail(width: width, height: height, pixels: (0 ..< width * height).map { index in
                        let (x, y) = (index % width, index / width)
                        let checker: Float = x * 5 / width == frame ? ((x + y) % 2 == 0 ? 0.1 : -0.1) : 0
                        return 0.1 + 0.5 * Float(x) / Float(width) + 0.3 * Float(y) / Float(height) + checker
                    })
                }
            }
        }
    }

    @Test func `a folder's stacks are found through the engine's reader, its captures in one call`() async throws {
        let engine = StubEngine()
        let files = SweepFiles()
        engine.files = files
        let model = EditorModel(engine: engine)
        let frames = try frames(5)
        defer { remove(frames) }
        model.library.open(frames[0].deletingLastPathComponent())
        let deadline = ContinuousClock.now + .seconds(30)
        while model.stackSuggestions.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.stackSuggestions.map { $0.frames.map(\.lastPathComponent) } == [frames.map(\.lastPathComponent)])
        #expect(files.calls.filter { !$0.thumbnails }.map(\.count) == [5])
        #expect(files.calls.filter(\.thumbnails).map(\.count).reduce(0, +) == 5)
    }

    @Test func `merging needs a detected stack`() throws {
        let model = EditorModel(engine: StubEngine())
        #expect(!model.canPerform(.mergeFocusStack))
        #expect(!model.perform(.mergeFocusStack))
        let frames = try frames(3)
        defer { remove(frames) }
        model.stackSuggestions = [StackSuggestion(frames: frames)]
        #expect(model.canPerform(.mergeFocusStack))
    }

    @Test func `merging saves the detected stack and opens it in the Stack workspace`() throws {
        let model = EditorModel(engine: StubEngine())
        let frames = try frames(3)
        defer { remove(frames) }
        let suggestion = StackSuggestion(frames: frames)
        let document = suggestion.documentURL()
        model.stackSuggestions = [suggestion]
        #expect(model.perform(.mergeFocusStack))
        #expect(FileManager.default.fileExists(atPath: document.path))
        #expect(model.stackWorkspace?.documentURL == document)
        #expect(model.stackSuggestions.isEmpty)
    }

    @Test func `editing needs a stack document selected`() throws {
        let model = EditorModel(engine: StubEngine())
        let frames = try frames(3)
        defer { remove(frames) }
        #expect(!model.canPerform(.editFocusStack))
        model.select(frames[0])
        #expect(!model.canPerform(.editFocusStack))
        let suggestion = StackSuggestion(frames: frames)
        let document = suggestion.documentURL()
        try suggestion.save(to: document)
        model.select(document)
        #expect(model.canPerform(.editFocusStack))
        #expect(model.perform(.editFocusStack))
        #expect(model.stackWorkspace?.documentURL == document)
    }

    @Test func `neither runs while the Stack workspace is open`() throws {
        let model = EditorModel(engine: StubEngine())
        let frames = try frames(6)
        defer { remove(frames) }
        let merged = StackSuggestion(frames: Array(frames.prefix(3)))
        let document = merged.documentURL()
        try merged.save(to: document)
        model.select(document)
        model.stackSuggestions = [StackSuggestion(frames: Array(frames.suffix(3)))]
        model.openStackWorkspace(document)
        #expect(!model.canPerform(.editFocusStack))
        #expect(!model.canPerform(.mergeFocusStack))
        #expect(!model.perform(.mergeFocusStack))
        #expect(model.stackWorkspace?.documentURL == document)
    }

    @Test func `the palette finds both, and Return merges the detected stack`() async throws {
        let (model, _, cleanup) = try await openEditor()
        defer { cleanup() }
        let frames = try frames(3)
        defer { remove(frames) }
        let suggestion = StackSuggestion(frames: frames)
        let document = suggestion.documentURL()
        model.stackSuggestions = [suggestion]
        model.openCommandPalette()
        let palette = try palette(model)
        palette.setText("focus stack")
        #expect(Set(palette.rows.prefix(2).map(\.kind)) == [.action(.mergeFocusStack), .action(.editFocusStack)])
        palette.setText("merge to focus stack")
        palette.handle(.submit)
        #expect(model.commandPalette == nil)
        #expect(model.stackWorkspace?.documentURL == document)
    }
}
