import Foundation
import RedlampLibrary

/// Renames and moves in the app (LIB-26): each one of the library's journaled file operations, planned and run
/// off the main thread in the library's changes' turn (`LibraryCore.change`), after the culling batches asked
/// for before it. The index follows as the steps go, without reading a photo, and the open lists hear of it.
extension LibraryService {
    /// What a batch made of its photos.
    struct FileRun: Sendable {
        /// The batch run, for its Undo; nil when nothing ran.
        var batch: UUID?
        var outcome: FileOutcome?
        /// Why nothing, or not everything, was done, in words.
        var error: String?
        /// Where each of the photos is now, as the index has it, by index ID.
        var paths: [Int64: String] = [:]
    }

    /// Gives each photo of `renames` its new name, with its pair, its sidecars and other apps' `.xmp`, as one
    /// batch; `progress` hears of each step, off the main thread.
    func rename(
        _ renames: [PhotoRename], title: String? = nil, progress: (@Sendable (FileProgress) -> Void)? = nil,
    ) async -> FileRun {
        await runFiles(renames.map(\.id), progress: progress) { files in
            try await files.planRename(renames, title: title)
        }
    }

    /// Moves photos `ids`, each with its pair and its files, into `folder`, as one batch: across volumes
    /// each file is copied and checked before its original goes.
    func move(_ ids: [Int64], to folder: URL, progress: (@Sendable (FileProgress) -> Void)? = nil) async -> FileRun {
        await runFiles(ids, progress: progress) { files in
            try await files.planMove(photos: ids, to: folder)
        }
    }

    /// Takes back batch `id` by running its Undo, planned from where its photos `ids` are then.
    func undoFiles(_ id: UUID, photos ids: [Int64], progress: (@Sendable (FileProgress) -> Void)? = nil) async
        -> FileRun {
        await runFiles(ids, progress: progress) { files in
            try await files.planUndo(id)
        }
    }

    /// Where photos `ids` are, as the index has them.
    func paths(of ids: [Int64]) async -> [Int64: String] {
        guard let core else { return [:] }
        return await Self.paths(of: ids, in: core.index)
    }

    private func runFiles(
        _ ids: [Int64], progress: (@Sendable (FileProgress) -> Void)?,
        plan: @escaping @Sendable (FileOperations) async throws -> FileBatch,
    ) async -> FileRun {
        guard let core else { return FileRun(error: "The library isn't open") }
        return await core.change {
            var run = FileRun()
            do {
                let batch = try await plan(core.files)
                if !batch.steps.isEmpty {
                    let outcome = try await core.files.run(batch, progress: progress)
                    run.outcome = outcome
                    run.batch = outcome.batch
                    if outcome.state != .finished {
                        run.error = "\(batch.title) stopped partway"
                    }
                }
                if !batch.gone.isEmpty {
                    run.error = Self.left(batch.gone)
                }
            } catch {
                run.error = Self.describe(error)
            }
            run.paths = await Self.paths(of: ids, in: core.index)
            return run
        }
    }

    private nonisolated static func paths(of ids: [Int64], in index: LibraryIndex) async -> [Int64: String] {
        await (try? index.read { reader in
            try reader.photosWithPaths(ids).reduce(into: [Int64: String]()) { paths, found in
                paths[found.photo.id] = found.folder + "/" + found.photo.name
            }
        }) ?? [:]
    }

    /// What a batch left out, no longer where it had left it.
    private nonisolated static func left(_ gone: [String]) -> String {
        let names = gone.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return gone.count == 1 ? "\(names) is no longer where it was left"
            : "\(gone.count) files are no longer where they were left (\(names)\(gone.count > 3 ? "…" : ""))"
    }

    /// A file operation's error in words.
    nonisolated static func describe(_ error: any Error) -> String {
        guard let error = error as? FileOperationError else { return String(describing: error) }
        switch error {
        case let .conflicts(conflicts):
            let shown = conflicts.prefix(3).map(\.description).joined(separator: "; ")
            return "Nothing was moved: \(shown)\(conflicts.count > 3 ? ", and \(conflicts.count - 3) more" : "")"
        case .unfinished:
            return "A rename or move a forced quit cut short is still being finished"
        case .noSuchBatch, .damagedJournal:
            return "The journal no longer has it, so it can't be undone"
        case .newerJournal:
            return "A newer Redlamp wrote it in the journal, so this one can't undo it"
        case .nothingToUndo:
            return "Nothing it did is left to undo"
        case let .notInLibrary(path):
            return "\((path as NSString).lastPathComponent) isn't in the library's folders"
        case let .insideItself(path):
            return "\((path as NSString).lastPathComponent) can't go inside itself"
        case let .isRoot(path):
            return "\((path as NSString).lastPathComponent) is a folder added to the library"
        case let .failed(path, message):
            return "\((path as NSString).lastPathComponent): \(message); everything it had done was put back"
        case let .stuck(_, path, message):
            return "\((path as NSString).lastPathComponent): \(message); it couldn't be put back, and waits in "
                + "the journal for the next launch"
        }
    }
}
