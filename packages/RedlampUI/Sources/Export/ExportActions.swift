import AppKit
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import RedlampRecipes
import SwiftUI

/// The Export dialog and Export with Previous, on the photos selected in the filmstrip or the grid (EDT-16): the open
/// photo alone is rendered by the editor's engine, as it always was; several, or a photo that isn't open, as in the
/// Library once another is chosen, go to the batch exporter (`BatchExport`).
@MainActor
public enum ExportActions {
    /// What an export of one photo needs before it can run.
    public enum Step: Equatable, Sendable {
        /// No previous export to repeat: show the dialog.
        case needsDialog
        case ready(URL, ExportSettings)
        /// The file exists and the settings say to ask.
        case confirmReplace(URL, ExportSettings)
        /// The file exists and the settings say to skip it.
        case skip(URL, ExportSettings)
    }

    /// Where `settings` put an export of `photo` named from its URL alone, after their rule for existing files.
    /// It reads the files there, through the decode service in the app, so it is never worked out on the main
    /// thread.
    public nonisolated static func step(
        for settings: ExportSettings, photo: URL, reading files: any FileInspecting,
    ) -> Step {
        guard let names = try? ExportNames([ExportNames.Photo(url: photo)], settings: settings, reading: files),
              let target = names.targets.first
        else { return .needsDialog }
        return step(target, settings: settings)
    }

    nonisolated static func step(_ target: ExportNames.Target, settings: ExportSettings) -> Step {
        switch target.existing {
        case .none, .replaced: .ready(target.url, settings)
        case .asked: .confirmReplace(target.url, settings)
        case .skipped: .skip(target.url, settings)
        }
    }

    /// What Export with Previous would do for the open photo alone, worked out off the main thread.
    public static func previousExport(model: EditorModel, store: ExportPresetStore) async -> Step {
        guard let info = model.info, let settings = store.previous else { return .needsDialog }
        let read = reader(for: SelectedPhotos([model.openPhoto ?? PhotoAddress(url: info.url)]), model: model)
        guard case let (names, _)? = await names(read, settings: settings, model: model),
              let target = names.targets.first
        else { return .needsDialog }
        return step(target, settings: settings)
    }

    // MARK: - The dialog

    /// Shows the Export dialog for the photos selected as an app-modal sheet on the editor window: until it
    /// closes, no other window gets events and every editor action is unavailable. Returns when it closes.
    public static func present(model: EditorModel, store: ExportPresetStore) {
        let info = model.info
        guard model.canExport, let active = info?.url ?? model.selection, !model.isModalDialogOpen,
              let window = EditorWindowController.frontWindow, window.attachedSheet == nil
        else { return }
        let photos = model.selectionForAction()
        let presets = namingPresets(model)
        let plan = ExportPlan(
            count: photos.count, folder: active.deletingLastPathComponent(), files: model.engine.files,
            counters: presets?.counters ?? NamingCounters(), read: reader(for: photos, model: model),
        )
        let height = window.sheetHeight(fitting: ExportSheet.size.height)
        let sheetWindow = NSWindow(
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
            plan: plan,
            photoSize: info?.pixelSize,
            recipe: info == nil ? nil : model.unobservedRecipe,
            borders: model.recipes.library.all.filter(\.isBorderOnly).map { recipe in
                ExportBorder(recipeID: recipe.id, name: recipe.name, values: recipe.settings.values)
            },
            store: store,
            namingPresets: presets,
            height: height,
            onCancel: close,
            onExport: { [weak window] settings, presetID, targets in
                close()
                let job = Job(
                    settings: settings, presetID: presetID, targets: targets, photos: plan.photos,
                    counters: plan.names?.counters,
                )
                run(job, model: model, store: store, window: window)
            },
        ).focusEffectDisabled())
        model.isModalDialogOpen = true
        window.beginSheet(sheetWindow)
        NSApp.runModal(for: sheetWindow)
    }

    // MARK: - Export with Previous

    /// Exports the photos selected with the last export's settings, or shows the dialog if there hasn't been one.
    public static func exportWithPrevious(model: EditorModel, store: ExportPresetStore) {
        let window = EditorWindowController.frontWindow
        Task { await exportWithPrevious(model: model, store: store, window: window) }
    }

    private static func exportWithPrevious(model: EditorModel, store: ExportPresetStore, window: NSWindow?) async {
        guard model.canExport, let settings = store.previous else { return present(model: model, store: store) }
        let presets = namingPresets(model)
        let read = reader(for: model.selectionForAction(), model: model)
        guard case let (names, photos)? = await names(
            read,
            settings: settings,
            counters: presets?.counters,
            model: model,
        )
        else { return present(model: model, store: store) }
        let job = { (targets: [ExportNames.Target]) in
            Job(
                settings: settings, presetID: store.previousPresetID, targets: targets, photos: photos,
                counters: names.counters,
            )
        }
        guard names.asked > 0 else { return run(job(names.targets), model: model, store: store, window: window) }
        guard let window else { return }
        let several = names.targets.count > 1
        let alert = NSAlert()
        if several {
            alert.messageText = ExportSheet.conflictTitle(names.asked, of: names.targets.count)
            alert.informativeText = ExportSheet.conflictMessage(several: names.asked)
        } else if let url = names.targets.first?.url {
            alert.messageText = ExportSheet.conflictTitle(url)
            alert.informativeText = ExportSheet.conflictMessage(url)
        }
        let answers: [ExistingFilePolicy] = several ? [.overwrite, .addNumber, .skip] : [.overwrite, .addNumber]
        for answer in answers {
            alert.addButton(withTitle: answer == .overwrite ? "Replace" : answer == .addNumber ? "Keep Both" : "Skip")
        }
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard answers.indices.contains(index) else { return }
            run(job(names.answering(answers[index])), model: model, store: store, window: window)
        }
    }

    // MARK: - Running

    /// An export: the settings, the preset they started from, where each photo goes and the edit of it exported, its
    /// file's own or a version's (LIB-48), in the targets' order, and the named counters as they'll be after it.
    private struct Job {
        let settings: ExportSettings
        let presetID: UUID?
        let targets: [ExportNames.Target]
        let photos: [PhotoAddress]
        let counters: NamingCounters?
    }

    private static func run(_ job: Job, model: EditorModel, store: ExportPresetStore, window: NSWindow?) {
        store.recordExport(job.settings, presetID: job.presetID)
        if let counters = job.counters {
            namingPresets(model)?.setCounters(counters)
        }
        // One photo is the editor's to render, unless it's another of the open photo's edits than the one open.
        guard job.targets.count > 1 || job.photos.first.map({ $0 != model.openPhoto }) == true else {
            guard let target = job.targets.first else { return }
            return runOne(target, settings: job.settings, model: model, window: window)
        }
        let open = model.openPhoto.flatMap { photo in
            job.photos.contains(photo) ? BatchExport.Open(
                photo: photo, recipe: model.unobservedRecipe,
                metadata: photo.version == nil ? nil : model.photoMetadata,
            ) : nil
        }
        // The open photo's other edits are read from its sidecar.
        model.saveNow()
        model.activity.record(.export, "Export of \(job.targets.count) photos")
        model.batchExport.run(BatchExport.Job(
            targets: job.targets, photos: job.photos, settings: job.settings, open: open,
        ) { report in
            finished(report, settings: job.settings, model: model, window: window)
        })
    }

    private static func runOne(
        _ target: ExportNames.Target, settings: ExportSettings, model: EditorModel, window: NSWindow?,
    ) {
        guard target.existing != .skipped else {
            model.activity.record(.export, "\(target.url.lastPathComponent) exists, so it was skipped")
            return
        }
        Task {
            do {
                try await model.export(settings, to: target.url)
                if settings.revealInFinder {
                    NSWorkspace.shared.activateFileViewerSelecting([target.url])
                }
            } catch {
                let alert = NSAlert(error: error)
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Report This Problem…")
                show(alert, on: window) { response in
                    if response == .alertSecondButtonReturn {
                        model.sendFeedback(FeedbackPrefill(
                            featureID: "export.dialog",
                            message: error.localizedDescription,
                        ))
                    }
                }
            }
        }
    }

    /// Shows what a batch wrote in Finder when the settings say to, and the photos it couldn't export, each with
    /// why, in one alert.
    private static func finished(
        _ report: BatchExport.Report, settings: ExportSettings, model: EditorModel, window: NSWindow?,
    ) {
        model.activity.record(.export, BatchExport.summary(of: report))
        guard !report.failures.isEmpty else {
            if settings.revealInFinder, !report.written.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(report.written)
            }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = report.failures.count == 1
            ? "1 of the \(report.total) photos wasn't exported."
            : "\(report.failures.count) of the \(report.total) photos weren't exported."
        alert.informativeText = failureList(report.failures)
        alert.addButton(withTitle: "OK")
        if !report.written.isEmpty {
            alert.addButton(withTitle: "Show in Finder")
        }
        alert.addButton(withTitle: "Report This Problem…")
        let showsFinder = !report.written.isEmpty
        show(alert, on: window) { response in
            switch response {
            case .alertSecondButtonReturn where showsFinder:
                NSWorkspace.shared.activateFileViewerSelecting(report.written)
            case .alertSecondButtonReturn, .alertThirdButtonReturn:
                model.sendFeedback(FeedbackPrefill(featureID: "export.batch", message: failureList(report.failures)))
            default:
                break
            }
        }
    }

    /// Each photo and why, the first ten, then how many more.
    static func failureList(_ failures: [BatchExport.Failure]) -> String {
        let shown = failures.prefix(10).map { "\($0.photo.lastPathComponent): \($0.reason)" }
        let more = failures.count > shown.count ? ["And \(failures.count - shown.count) more."] : []
        return (shown + more).joined(separator: "\n")
    }

    private static func show(
        _ alert: NSAlert, on window: NSWindow?,
        then answered: @escaping @MainActor (NSApplication.ModalResponse) -> Void,
    ) {
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: answered)
        } else {
            answered(alert.runModal())
        }
    }

    // MARK: - The photos

    /// The naming templates and counters renaming and importing keep in the library's folder, when it's open.
    static func namingPresets(_ model: EditorModel) -> NamingPresetStore? {
        model.library.service.map { NamingPresetStore.shared(for: $0.paths) }
    }

    /// Reads what `photos`' names are made from, off the main thread: the index's fields for those it has, the
    /// fields their files and sidecars hold for the others. A version (LIB-48) has its own name and metadata, its
    /// row's,
    /// and the version open its own as they are on screen (EDT-09).
    static func reader(
        for photos: SelectedPhotos, model: EditorModel,
    ) -> @Sendable () async -> [ExportPhoto] {
        let core = model.library.service?.core
        let sidecars = model.library.sidecars
        let open = model.openPhoto.flatMap {
            $0.version == nil ? nil : (photo: $0, name: model.openEditName, metadata: model.photoMetadata)
        }
        return {
            let addresses = await photos.all()
            var indexed: [PhotoAddress: NamingFields] = [:]
            if let core {
                let ids = await LibraryService.indexIDs(of: addresses, in: core.index)
                let versions = ids.filter { $0.key.version != nil }.map(\.value)
                let found = try? await core.index.read { reader in
                    try (
                        NamingFields.read(Array(Set(ids.values)), from: reader),
                        Dictionary(versions.compactMap { id in
                            try reader.photo(id: id)?.versionName.map { (id, $0) }
                        }) {
                            first, _ in first
                        },
                    )
                }
                let byID = Dictionary(
                    (found?.0 ?? []).map { ($0.id, $0.fields) },
                    uniquingKeysWith: { first, _ in first },
                )
                for (photo, id) in ids {
                    indexed[photo] = byID[id]
                    indexed[photo]?.version = found?.1[id]
                }
            }
            return addresses.map { photo in
                var fields = indexed[photo] ?? Self.unindexedFields(of: photo, sidecars: sidecars)
                if let open, open.photo == photo {
                    fields.apply(open.metadata)
                    fields.keywords = open.metadata.keywords ?? fields.keywords
                    fields.version = open.name
                }
                return ExportPhoto(address: photo, naming: ExportNames.Photo(url: photo.url, fields: fields))
            }
        }
    }

    /// What a photo the index doesn't have is named from: its file's fields and its sidecar's, a version's own over
    /// its file's.
    private nonisolated static func unindexedFields(
        of photo: PhotoAddress,
        sidecars: SidecarPlacement,
    ) -> NamingFields {
        let url = photo.url
        let name = url.lastPathComponent, folder = url.deletingLastPathComponent().path
        var fields = PhotoMetadataReader.read(url: url).map { NamingFields(name: name, folder: folder, metadata: $0) }
            ?? NamingFields(name: name, folder: folder)
        guard let sidecar = sidecars.store(for: url).load(for: url) else { return fields }
        if let metadata = sidecar.metadata {
            fields.apply(metadata)
        }
        if let version = photo.version.flatMap(sidecar.version) {
            let metadata = version.metadata ?? PhotoMetadata()
            fields.apply(metadata)
            fields.keywords = metadata.keywords ?? fields.keywords
            fields.version = version.name
        }
        return fields
    }

    /// The names `settings` give the photos `read` reads, worked out off the main thread, and the edits they're for in
    /// their order; nil when the template doesn't read.
    private static func names(
        _ read: @escaping @Sendable () async -> [ExportPhoto], settings: ExportSettings,
        counters: NamingCounters? = nil, model: EditorModel,
    ) async -> (ExportNames, [PhotoAddress])? {
        let files = model.engine.files
        let counters = counters ?? NamingCounters()
        return await Task.detached(priority: .userInitiated) {
            let photos = await read()
            return try? (
                ExportNames(photos.map(\.naming), settings: settings, counters: counters, reading: files),
                photos.map(\.address),
            )
        }.value
    }
}
