import Foundation
import RedlampEngine
import RedlampEngineAPI
import RedlampUI

/// The editor every scene shares: the real `EditorModel` on the real engine, with a sample
/// photo open so controls that depend on one (white balance, Auto) behave as in the app.
///
/// The photo is a copy in a temporary folder, so edits made while reviewing never leave
/// sidecars next to the fixtures.
@MainActor
enum HarnessEditor {
    static let model: EditorModel = {
        guard let engine = try? RedlampEngine() else {
            fatalError("The harness needs a Metal GPU")
        }
        let model = EditorModel(engine: engine)
        // Every panel open, so each one's rows are there to review.
        model.expandedPanels = Set(PanelID.allCases)
        // No canvas on screen, but a size to render at, so frames (and the histogram) flow.
        model.canvas.updateView(size: CGSize(width: 800, height: 600), backingScale: 1)
        if let photo = samplePhoto() {
            model.open([photo])
        }
        return model
    }()

    /// Gives the Masking scenes a selected radial mask to show (the debug script draws it
    /// through the same path a drag does).
    static func ensureMask() {
        Task {
            while model.info == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard model.masks.isEmpty else { return }
            model.applyDebugCommand("radial", "0.5:0.5:0.2:0.15")
        }
    }

    /// `tests/fixtures/raw` in this checkout (`mise run fixtures` downloads it).
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "tests/fixtures/raw")

    private static func samplePhoto() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? []
        guard let source = files
            .filter({ SupportedFormats.isSupported($0) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first
        else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "redlamp-harness",
            directoryHint: .isDirectory,
        )
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: source.lastPathComponent)
        return (try? FileManager.default.copyItem(at: source, to: copy)) != nil ? copy : nil
    }
}
