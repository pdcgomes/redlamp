import AppKit
import Foundation
import RedlampDocument
import RedlampLibrary

/// Move Edits and Metadata… (LIB-11, DEC-43): from a root's menu in Folders for that root, and from the Library menu
/// and the palette for the root holding the folder open in Folders. Its sheet says where the root keeps its edits and
/// metadata, where they'd go and how many photos have them, then runs the move (`SidecarMoveJob`) with its progress.
///
/// - **Saved first:** the open photo's edit, and every save asked for before Move, are on disk before the move plans,
///   and the sheet holds the editor's commands while it moves, so nothing writes a sidecar where it's leaving.
/// - **The open photo's sidecar moves first,** and its later saves go where the root keeps them from then on.
/// - **Said in words:** a refusal, a move stopped or put back, and the photos it couldn't move, which the activity
///   log names.
/// - **After a quit,** the next launch finishes the move with its sheet up, once the library is open.
public extension EditorModel {
    /// Move Edits and Metadata… for the root holding the folder open in Folders.
    @discardableResult
    func moveEditsAndMetadata() -> Bool {
        guard let root = rootMovingEdits else { return false }
        return moveEditsAndMetadata(of: root)
    }

    /// The root the Library menu's and the palette's Move Edits and Metadata… act on: the one holding the folder open
    /// in Folders, while it's there and the library is open.
    var rootMovingEdits: WorkingFolder? {
        guard let folder, let root = library.root(containing: folder), canMoveEdits(of: root) else { return nil }
        return root
    }

    func canMoveEdits(of root: WorkingFolder) -> Bool {
        !isModalDialogOpen && library.service?.isReady == true && !library.missing.contains(root.id)
            && library.roots.contains { $0.id == root.id }
    }

    /// Move Edits and Metadata… for `root`: its sheet, with where the root keeps its edits and metadata and how many of
    /// its photos have them, from the index.
    @discardableResult
    func moveEditsAndMetadata(of root: WorkingFolder) -> Bool {
        guard canMoveEdits(of: root), let core = library.service?.core,
              let window = EditorWindowController.frontWindow, window.attachedSheet == nil
        else { return false }
        let requested = ContinuousClock.now
        isModalDialogOpen = true
        // The read starts now rather than once the menu that chose the command has let the main thread go.
        let (folder, index) = (root.url, core.index)
        let reading = Task.detached(priority: .userInitiated) { await MoveEditsModel.survey(folder, in: index) }
        Task {
            let survey = await reading.value
            isModalDialogOpen = false
            let model = MoveEditsModel(
                root: root, rootID: survey?.id, placement: survey?.placement ?? .besidePhotos,
                indexed: survey?.photos ?? 0,
            )
            model.surveyed = .now - requested
            MoveEditsSheetController.present(model, editor: self, requested: requested)
        }
        return true
    }
}

extension EditorModel {
    /// Runs the move `sheet` shows, or finishes the one a quit interrupted: the saves first, then the sidecars, with
    /// their progress in the sheet. True once it's over with nothing more to say, so the sheet can close.
    func moveEdits(_ sheet: MoveEditsModel) async -> Bool {
        guard let service = library.service, let core = service.core else {
            sheet.setPhase(.failed("The library isn't open"))
            return false
        }
        let root = sheet.root
        if sheet.unfinished == nil {
            sheet.setPhase(.saving)
            if hasUnsavedChange {
                saveNow()
            }
            await saves.flush()
            await settingsSync.idle()
            if sheet.control.isCancelled {
                return true
            }
            if sheet.destination == .besidePhotos {
                let folder = root.url
                let refusal = await Task.detached(priority: .userInitiated) {
                    SidecarMoveJob.whyNotWritable(folder, probing: true)
                }.value
                if let refusal {
                    sheet.refuse(refusal)
                    return false
                }
            }
        }
        let defaults = library.defaults
        let record = sheet.unfinished ?? SidecarMoveRecord(
            root: LibraryService.path(root.url), destination: sheet.destination,
        )
        record.save(in: defaults)
        sheet.onCancel = {
            var turned = record
            turned.destination = record.destination == .onThisMac ? .besidePhotos : .onThisMac
            turned.puttingBack = !record.puttingBack
            turned.save(in: defaults)
        }
        sheet.setPhase(.moving(FileProgress(done: 0, total: 0, isRollingBack: record.puttingBack)))
        let relay = FileProgressRelay { [weak sheet] progress in
            guard let sheet, sheet.isMoving else { return }
            var shown = progress
            shown.isRollingBack = progress.isRollingBack || record.puttingBack
            sheet.setPhase(.moving(shown))
        }
        let placed: @Sendable () async -> Void = { [weak service] in await service?.placementsChanged() }
        let result: SidecarMoveJob.Result? = if let unfinished = sheet.unfinished {
            await SidecarMoveJob.finish(
                unfinished, core: core, control: sheet.control, placed: placed,
                progress: { relay.send($0) },
            )
        } else if let rootID = sheet.rootID {
            await SidecarMoveJob.run(
                root: rootID, to: sheet.destination, first: selection.flatMap { Self.path(of: $0, below: root.url) },
                core: core, control: sheet.control, placed: placed, progress: { relay.send($0) },
            )
        } else {
            nil
        }
        SidecarMoveRecord.remove(from: defaults)
        await service.placementsChanged()
        return report(result, of: sheet)
    }

    /// Finishes the move of a root's edits and metadata a quit interrupted, once the library is open: with its sheet
    /// up, after any sheet that's up first, or without one where there's no window for it. A root that isn't there now
    /// is left for the next launch.
    func finishSidecarMove(_ record: SidecarMoveRecord) {
        guard let root = library.roots.first(where: { LibraryService.path($0.url) == record.root }) else {
            SidecarMoveRecord.remove(from: library.defaults)
            activity.record(
                .error,
                "A move of edits and metadata a quit interrupted wasn't finished: its folder isn't in Folders any more",
            )
            return
        }
        Task {
            let folder = root.url
            let isThere = await Task.detached { FileManager.default.fileExists(atPath: folder.path) }.value
            guard isThere, let core = library.service?.core else { return }
            for _ in 0 ..< 600 where isModalDialogOpen || EditorWindowController.frontWindow?.attachedSheet != nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
            let survey = await MoveEditsModel.survey(root.url, in: core.index)
            let model = MoveEditsModel(
                root: root, rootID: survey?.id,
                placement: record.destination == .onThisMac ? .besidePhotos : .onThisMac,
                indexed: survey?.photos ?? 0, unfinished: record,
            )
            if !isModalDialogOpen, let sheet = MoveEditsSheetController.present(model, editor: self) {
                sheet.finishUnfinished()
            } else {
                _ = await moveEdits(model)
            }
        }
    }

    /// `photo`'s path below `root`; nil when it isn't in it.
    static func path(of photo: URL, below root: URL) -> String? {
        let (folder, path) = (LibraryService.path(root), LibraryService.path(photo))
        let prefix = folder == "/" ? "/" : folder + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    // MARK: - Saying what happened

    /// Says what the move did: in the activity log, naming the photos it couldn't move, and in the sheet when there's
    /// something to say. True when there isn't.
    private func report(_ result: SidecarMoveJob.Result?, of sheet: MoveEditsModel) -> Bool {
        let root = sheet.root
        let title = "Move Edits and Metadata of \(root.name)"
        let (here, there) = (MoveEditsModel.place(sheet.source), MoveEditsModel.place(sheet.destination))
        guard let result else {
            activity.record(.error, "\(title) wasn't done: the folder isn't in the library any more")
            sheet.setPhase(.failed("“\(root.name)” isn't in the library any more, so nothing was moved"))
            return false
        }
        if !result.conflicts.isEmpty {
            let photos = result.conflicts.map(\.photo)
            activity.record(
                .error,
                "\(title) didn't start: \(who(photos, in: root)) have edits and metadata in both places",
            )
            sheet.refuseConflicts(result.conflicts)
            return false
        }
        if let error = result.error {
            activity.record(.error, "\(title) stopped: \(error)")
            sheet.setPhase(.failed(
                "The move stopped: \(error). What it moved is \(there), the rest \(here), and Redlamp reads both.",
            ))
            return false
        }
        if let putBack = result.putBack {
            activity.record(
                .action,
                "\(title) cancelled: \(MoveEditsModel.photos(putBack.moved)) put back \(here)",
            )
            guard !putBack.failed.isEmpty else { return true }
            let failed = putBack.failed.keys.sorted()
            activity.record(
                .error,
                "\(title) couldn't put back \(who(failed, in: root)): \(reasons(putBack.failed)); they stay \(there)",
            )
            sheet.setPhase(.done(
                "Cancel put back \(MoveEditsModel.photos(putBack.moved)), but \(failed.count) couldn't be put back "
                    + "and stay \(there), where Redlamp still reads them: \(reasons(putBack.failed)). The activity log "
                    + "names them.",
            ))
            return false
        }
        if result.movedNothing {
            let failed = result.outcome.failed.keys.sorted()
            activity.record(
                .error,
                "\(title) moved nothing: \(who(failed, in: root)): \(reasons(result.outcome.failed))",
            )
            sheet.setPhase(.done(
                "Nothing was moved: \(reasons(result.outcome.failed)). The edits and metadata stay \(here).",
            ))
            return false
        }
        let moved = result.outcome.moved
        let finished = sheet.unfinished.map { $0.puttingBack ? "Finished putting back" : "Finished moving" }
        activity.record(
            .action,
            (finished.map { "\($0) the edits and metadata of" } ?? "Moved the edits and metadata of")
                + " \(MoveEditsModel.photos(moved)) in \(root.name) \(sheet.destination == .onThisMac ? "to Redlamp on this Mac" : "beside the photos")"
                + (finished == nil ? "" : ", which a quit interrupted"),
        )
        var problems: [String] = []
        if !result.outcome.failed.isEmpty {
            let failed = result.outcome.failed.keys.sorted()
            activity.record(
                .error,
                "\(title) couldn't move \(who(failed, in: root)): \(reasons(result.outcome.failed)); they stay \(here)",
            )
            problems.append(
                "\(failed.count) couldn't be moved and stay \(here), where Redlamp still reads them: "
                    + "\(reasons(result.outcome.failed)).",
            )
        }
        if !result.outcome.conflicts.isEmpty {
            activity.record(
                .error,
                "\(title) left \(who(result.outcome.conflicts, in: root)) as they were: their edits and metadata "
                    + "turned up in both places while they moved",
            )
            problems.append(
                "\(result.outcome.conflicts.count) turned up in both places while they moved and were left as they are.",
            )
        }
        if result.outcome.gone > 0 {
            activity.record(
                .message,
                "\(title): \(MoveEditsModel.photos(result.outcome.gone))' edits and metadata were gone before they moved",
            )
        }
        guard !problems.isEmpty else { return true }
        sheet.setPhase(.done(
            "Moved \(MoveEditsModel.photos(moved))' edits and metadata \(sheet.destination == .onThisMac ? "to Redlamp on this Mac" : "beside the photos"). "
                + problems.joined(separator: " ") + " The activity log names them.",
        ))
        return false
    }

    /// The photos at `paths` below `root` as the activity log names them: "Photo C", "Photo C and Photo D",
    /// "Photo C, Photo D, … and 12 more".
    private func who(_ paths: [String], in root: WorkingFolder) -> String {
        let named = paths.prefix(10).map { activity.alias(for: root.url.appending(path: $0)) }
        let rest = paths.count - named.count
        guard named.count > 1 else { return named.first ?? "no photo" }
        if rest > 0 {
            return named.joined(separator: ", ") + " and \(rest) more"
        }
        return named.dropLast().joined(separator: ", ") + " and " + (named.last ?? "")
    }

    /// Why sidecars weren't moved: each reason once, up to three.
    private func reasons(_ failed: [String: String]) -> String {
        let reasons = Set(failed.values.map(SidecarMoveJob.reason)).sorted()
        let shown = reasons.prefix(3).joined(separator: "; ")
        return reasons.count > 3 ? shown + "; and \(reasons.count - 3) more reasons" : shown
    }
}
