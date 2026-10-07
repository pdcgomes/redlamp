import AppKit
import RedlampDocument
import RedlampEngineAPI
import SwiftUI

/// The Export dialog and Export with Previous.
@MainActor
public enum ExportActions {
    /// What an export needs before it can run.
    public enum Step: Equatable, Sendable {
        /// No previous export to repeat: show the dialog.
        case needsDialog
        case ready(URL, ExportSettings)
        /// The file exists and the settings say to ask.
        case confirmReplace(URL, ExportSettings)
    }

    /// Where `settings` put an export of `photo`, after their rule for existing files. It reads
    /// the files there, through the decode service in the app, so it is never worked out on the
    /// main thread.
    public nonisolated static func step(
        for settings: ExportSettings, photo: URL, reading files: any FileInspecting,
    ) -> Step {
        step(at: ExportDestination.url(for: photo, settings: settings, reading: files), settings: settings)
    }

    /// What `settings`' rule for existing files does with an export to `url`.
    nonisolated static func step(at url: URL, settings: ExportSettings) -> Step {
        guard FileManager.default.fileExists(atPath: url.path) else { return .ready(url, settings) }
        switch settings.existingFiles {
        case .ask: return .confirmReplace(url, settings)
        case .addNumber: return .ready(ExportDestination.firstFree(url), settings)
        case .overwrite: return .ready(url, settings)
        }
    }

    /// What Export with Previous would do for the open photo, worked out off the main thread.
    public static func previousExport(model: EditorModel, store: ExportPresetStore) async -> Step {
        guard let info = model.info, let settings = store.previous else { return .needsDialog }
        let (photo, files) = (info.url, model.engine.files)
        return await Task.detached(priority: .userInitiated) {
            step(for: settings, photo: photo, reading: files)
        }.value
    }

    /// Shows the Export dialog as an app-modal sheet on the editor window: until it closes, no
    /// other window gets events and every editor action is unavailable. Returns when it closes.
    public static func present(model: EditorModel, store: ExportPresetStore) {
        guard let info = model.info, !model.isModalDialogOpen,
              let window = EditorWindowController.frontWindow, window.attachedSheet == nil
        else { return }
        let height = window.sheetHeight(fitting: ExportSheet.size.height)
        let sheetWindow = RinglessWindow(
            contentRect: CGRect(x: 0, y: 0, width: ExportSheet.size.width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        let close = { [weak window, weak sheetWindow] in
            NSApp.stopModal()
            model.isModalDialogOpen = false
            if let window, let sheetWindow {
                window.endSheet(sheetWindow)
            }
        }
        sheetWindow.contentViewController = NSHostingController(rootView: ExportSheet(
            photo: info.url,
            photoSize: info.pixelSize,
            files: model.engine.files,
            store: store,
            height: height,
            onCancel: close,
            onExport: { [weak window] settings, presetID, url in
                close()
                run(Job(settings: settings, presetID: presetID, url: url), model: model, store: store, window: window)
            },
        ).focusEffectDisabled())
        model.isModalDialogOpen = true
        window.beginSheet(sheetWindow)
        NSApp.runModal(for: sheetWindow)
    }

    /// Exports the open photo with the last export's settings, or shows the dialog if there
    /// hasn't been one.
    public static func exportWithPrevious(model: EditorModel, store: ExportPresetStore) {
        let window = EditorWindowController.frontWindow
        Task { await exportWithPrevious(model: model, store: store, window: window) }
    }

    private static func exportWithPrevious(model: EditorModel, store: ExportPresetStore, window: NSWindow?) async {
        switch await previousExport(model: model, store: store) {
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
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Report This Problem…")
                let report: @MainActor (NSApplication.ModalResponse) -> Void = { response in
                    if response == .alertSecondButtonReturn {
                        model.sendFeedback(FeedbackPrefill(
                            featureID: "export.dialog",
                            message: error.localizedDescription,
                        ))
                    }
                }
                if let window, window.attachedSheet == nil {
                    alert.beginSheetModal(for: window, completionHandler: report)
                } else {
                    report(alert.runModal())
                }
            }
        }
    }
}
