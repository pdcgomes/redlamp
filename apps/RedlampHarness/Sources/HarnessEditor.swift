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
        if let photo = samplePhoto {
            model.open([photo])
        }
        return model
    }()

    /// The photos a scene can switch between, for controls that depend on what's open.
    enum Photo: String, CaseIterable, Identifiable {
        case raw = "Sample raw"
        case jpeg = "JPEG (no white balance)"
        case none = "No photo"

        var id: String {
            rawValue
        }
    }

    /// Opens the sample raw, a JPEG exported from it (no white balance), or nothing.
    static func show(_ photo: Photo) async {
        let model = model
        switch photo {
        case .raw:
            if let samplePhoto {
                model.select(samplePhoto)
            }
        case .jpeg:
            let jpeg = folder.appending(path: "sample.jpg")
            if !FileManager.default.fileExists(atPath: jpeg.path), let samplePhoto {
                model.select(samplePhoto)
                while model.info == nil, model.errorMessage == nil {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? await model.exportCurrent(to: jpeg, format: .jpeg)
            }
            model.select(jpeg)
        case .none:
            // A file that isn't there: the editor shows no photo, as before one opens.
            model.select(folder.appending(path: "no-photo.ARW"))
        }
    }

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

    private static let folder = FileManager.default.temporaryDirectory.appending(
        path: "redlamp-harness",
        directoryHint: .isDirectory,
    )

    private static let samplePhoto: URL? = {
        let files = (try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? []
        guard let source = files
            .filter({ SupportedFormats.isSupported($0) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first
        else { return nil }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: source.lastPathComponent)
        return (try? FileManager.default.copyItem(at: source, to: copy)) != nil ? copy : nil
    }()
}
