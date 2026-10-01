import AppKit
import RedlampDocument
import RedlampEngineAPI
import SwiftUI

/// The Export dialog and Export with Previous.
@MainActor
public enum ExportActions {
    /// What an export needs before it can run.
    public enum Step: Equatable {
        /// No previous export to repeat: show the dialog.
        case needsDialog
        case ready(URL, ExportSettings)
        /// The file exists and the settings say to ask.
        case confirmReplace(URL, ExportSettings)
    }

    /// Where `settings` put an export of `photo`, after their rule for existing files.
    public static func step(for settings: ExportSettings, photo: URL) -> Step {
        let url = ExportDestination.url(for: photo, settings: settings)
        guard FileManager.default.fileExists(atPath: url.path) else { return .ready(url, settings) }
        switch settings.existingFiles {
        case .ask: return .confirmReplace(url, settings)
        case .addNumber: return .ready(ExportDestination.firstFree(url), settings)
        case .overwrite: return .ready(url, settings)
        }
    }

    /// What Export with Previous would do for the open photo.
    public static func previousExport(model: EditorModel, store: ExportPresetStore) -> Step {
        guard let info = model.info, let settings = store.previous else { return .needsDialog }
        return step(for: settings, photo: info.url)
    }

    /// Shows the Export dialog on the editor window.
    public static func present(model: EditorModel, store: ExportPresetStore) {
        guard let info = model.info, let window = NSApp.keyWindow ?? NSApp.mainWindow,
              window.attachedSheet == nil
        else { return }
        let sheetWindow = NSWindow(
            contentRect: CGRect(origin: .zero, size: ExportSheet.size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        let close = { [weak window, weak sheetWindow] in
            if let window, let sheetWindow {
                window.endSheet(sheetWindow)
            }
        }
        sheetWindow.contentViewController = NSHostingController(rootView: ExportSheet(
            photo: info.url,
            photoSize: info.pixelSize,
            store: store,
            onCancel: close,
            onExport: { [weak window] settings, presetID, url in
                close()
                run(Job(settings: settings, presetID: presetID, url: url), model: model, store: store, window: window)
            },
        ).focusEffectDisabled())
        window.beginSheet(sheetWindow)
    }

    /// Exports the open photo with the last export's settings, or shows the dialog if there
    /// hasn't been one.
    public static func exportWithPrevious(model: EditorModel, store: ExportPresetStore) {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        switch previousExport(model: model, store: store) {
        case .needsDialog:
            present(model: model, store: store)
        case let .ready(url, settings):
            let job = Job(settings: settings, presetID: store.previousPresetID, url: url)
            run(job, model: model, store: store, window: window)
        case let .confirmReplace(url, settings):
            guard let window else { return }
            let alert = NSAlert()
            alert.messageText = ExportSheet.conflictTitle(url)
            alert.informativeText = ExportSheet.conflictMessage(url)
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                let target: URL? = switch response {
                case .alertFirstButtonReturn: url
                case .alertSecondButtonReturn: ExportDestination.firstFree(url)
                default: nil
                }
                guard let target else { return }
                let job = Job(settings: settings, presetID: store.previousPresetID, url: target)
                run(job, model: model, store: store, window: window)
            }
        }
    }

    /// One export: the settings, the preset they started from, and the file to write.
    private struct Job {
        let settings: ExportSettings
        let presetID: UUID?
        let url: URL
    }

    private static func run(_ job: Job, model: EditorModel, store: ExportPresetStore, window: NSWindow?) {
        store.recordExport(job.settings, presetID: job.presetID)
        Task {
            do {
                try await model.export(job.settings, to: job.url)
                if job.settings.revealInFinder {
                    NSWorkspace.shared.activateFileViewerSelecting([job.url])
                }
            } catch {
                let alert = NSAlert(error: error)
                if let window, window.attachedSheet == nil {
                    alert.beginSheetModal(for: window, completionHandler: nil)
                } else {
                    alert.runModal()
                }
            }
        }
    }
}
