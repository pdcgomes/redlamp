import Foundation
import RedlampDesign
import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// Collects what the palette reports.
final class PaletteEvents {
    var all: [PaletteEvent] = []
}

/// An editor with a photo open, and the calls the palette's keys make.
@MainActor
protocol PaletteTesting {}

extension PaletteTesting {
    /// An editor with a photo open, its palette events recorded.
    func openEditor() async throws -> (EditorModel, PaletteEvents, () -> Void) {
        CommandPaletteModel.previewDelay = .milliseconds(20)
        CommandPaletteModel.burstGap = .milliseconds(400)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = EditorModel(engine: StubEngine())
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info != nil)
        let events = PaletteEvents()
        model.onCommandPaletteEvent = { events.all.append($0) }
        return (model, events, { try? FileManager.default.removeItem(at: folder) })
    }

    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func palette(_ model: EditorModel) throws -> CommandPaletteModel {
        try #require(model.commandPalette)
    }

    /// Opens the palette, types `query` and presses ↵ on the first row.
    func open(_ query: String, in model: EditorModel) throws -> CommandPaletteModel {
        model.openCommandPalette()
        let palette = try palette(model)
        palette.setText(query)
        palette.handle(.submit)
        return palette
    }
}

extension PaletteEvent {
    var isHighlightOrSearch: Bool {
        switch self {
        case .highlighted, .searchedFromSlider, .previewed: true
        default: false
        }
    }
}
