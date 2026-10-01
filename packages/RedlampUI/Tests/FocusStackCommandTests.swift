import Foundation
import RedlampDocument
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
