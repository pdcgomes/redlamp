import AppKit
import Foundation
import RedlampLibrary
import Synchronization

/// Renaming photos in Library (LIB-25, LIB-26), each rename one of the library's journaled batches.
///
/// - **Shown at once:** the photos go where the batch puts them in the grid and the filmstrip before it runs
///   (`LibraryMoves`), each keeping its ID, so the selection follows; the active photo, leaving Develop's
///   document first, goes with it. The library's lists then find each photo where it already is.
/// - **Saved first:** the sidecars the photos' saves still write are on disk before the batch plans, and the
///   batch runs in the library's changes' turn, after the culling batches asked for before it.
/// - **Afterwards,** each photo is shown where the index has it, so a batch that stopped or was rolled back
///   shows what it left. Steps are made one at a time, in the order they're asked for.
public extension EditorModel {
    /// Rename Photos…: the template sheet for the photos selected, with their raw and JPEG pairs.
    @discardableResult
    func renamePhotos() -> Bool {
        guard let sheet = renameSheet() else { return false }
        RenameSheetController.present(sheet, editor: self)
        return true
    }

    /// Rename Photos acts on Library's selection, with the library open.
    var canRenamePhotos: Bool {
        module == .library && !isModalDialogOpen && selection != nil && library.service?.isReady == true
    }
}

extension EditorModel {
    /// What Rename Photos shows for the photos selected, in their order, read once it starts.
    func renameSheet(presets: NamingPresetStore? = nil) -> RenameModel? {
        guard canRenamePhotos, let service = library.service, let core = service.core else { return nil }
        let urls = selectedPhotos
        return RenameModel(
            photos: urls.count, presets: presets ?? NamingPresetStore.shared(for: service.paths),
            sidecars: library.sidecars,
        ) {
            let ids = await LibraryService.indexIDs(of: urls, in: core.index)
            return try await RenameJob.read(urls.compactMap { ids[$0] }, core: core)
        }
    }

    // MARK: - Keys, menus and the palette

    /// Rename Photos; nil for every other action.
    func performFileShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .renamePhotos: renamePhotos()
        default: nil
        }
    }

    func canPerformFileShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .renamePhotos: canRenamePhotos
        default: nil
        }
    }

    /// The renames made one at a time.
    var fileSteps: LibraryFileSteps {
        if let steps = Self.fileSteps.object(forKey: self) {
            return steps
        }
        let steps = LibraryFileSteps()
        Self.fileSteps.setObject(steps, forKey: self)
        return steps
    }

    private static let fileSteps = NSMapTable<EditorModel, LibraryFileSteps>.weakToStrongObjects()

    // MARK: - Renaming

    /// Renames the photos `sheet` names, as one batch: shown at once, then made in the background, after the
    /// file steps asked for before it, with its progress in the sheet. Returns why it didn't happen, or nil.
    func rename(_ sheet: RenameModel) async -> String? {
        guard let service = library.service, service.isReady else { return "The library isn't open" }
        guard let (renames, batch) = await sheet.renames() else { return "The template has an error" }
        guard !renames.isEmpty else { return nil }
        let photos = renames.map { rename in
            (
                id: rename.id,
                from: rename.path,
                to: (rename.path as NSString).deletingLastPathComponent + "/" + rename.name,
            )
        }
        let count = Set(renames.map(\.id)).count
        let step = LibraryFileStep(
            kind: .rename(renames), title: "Rename \(count) Photo\(count == 1 ? "" : "s")", photos: photos,
        )
        let relay = FileProgressRelay { progress in
            sheet.setPhase(.renaming(done: progress.done, total: progress.total))
        }
        let run = await fileSteps.make { [self] in
            await perform(step) { await service.rename(renames) { relay.send($0) } }
        }
        if run.batch != nil {
            sheet.renamed(batch)
            activity.record(.action, step.title)
        }
        return run.error
    }

    // MARK: - Making a step

    /// Shows `step` at once, waits for its photos' saves, runs `batch`, then shows each photo where the index
    /// has it.
    func perform(_ step: LibraryFileStep, batch: @escaping () async -> LibraryService.FileRun) async
        -> LibraryService.FileRun {
        let saving = await show(step.photos, of: step)
        await waitForSaves(of: saving)
        let run = await batch()
        await follow(step.photos, of: step, paths: run.paths)
        if let made = run.batch {
            step.batch = made
        }
        return run
    }

    /// Shows `moves` at once: the photos at their new URLs, or out of the folders shown. The active photo goes
    /// with them, or, when it leaves the folders shown, the photo after it becomes active. Returns the URLs of the
    /// photos as they were, whose saves the batch waits for.
    private func show(_ moves: [(id: Int64, from: String, to: String)], of step: LibraryFileStep) async -> [URL] {
        // What was asked for before reaches the lists first: culling's batches, then the list's changes.
        await cullingTail?.value
        if let live = library.service?.core?.live, let photo = moves.lazy.compactMap({ move -> (Int64, URL)? in
            guard let url = self.library.listedURL(ofPath: move.from), self.library.index(of: url) != nil
            else { return nil }
            return (move.id, url)
        }).first {
            await library.caughtUp(with: (id: photo.0, url: photo.1), live: live)
        }
        var shown: [LibraryMoves.Move] = []
        var saving: [URL] = []
        for move in moves {
            saving.append(URL(fileURLWithPath: move.from))
            guard let from = library.listedURL(ofPath: move.from), library.index(of: from) != nil else { continue }
            saving.append(from)
            if step.items[move.id] == nil, let item = library.item(for: from) {
                step.items[move.id] = item
            }
            shown.append(LibraryMoves.Move(from: from, to: library.listedURL(ofPath: move.to)))
        }
        if step.active == nil {
            step.selected = Set(selectedPhotos)
            step.active = selection
        }
        let (active, activeRow) = (selection, selectionIndex)
        let destination = active.flatMap { active in shown.first { $0.from == active } }
        await library.show(LibraryMoves(moves: shown)) { [self] in
            if let destination {
                if let to = destination.to {
                    select(to, keepingSelection: true)
                } else if !items.isEmpty {
                    select(items[min(activeRow ?? 0, items.count - 1)].url)
                }
            }
            if let anchor = selectionAnchor, let moved = shown.first(where: { $0.from == anchor }) {
                selectionAnchor = moved.to
            }
        }
        return saving
    }

    /// Once a batch has run: each photo shown where the index has it, should the batch have stopped, been rolled
    /// back or left some out.
    private func follow(
        _ moves: [(id: Int64, from: String, to: String)], of step: LibraryFileStep, paths: [Int64: String],
    ) async {
        var corrections: [LibraryMoves.Move] = []
        var restoring: [LibraryItem] = []
        for move in moves {
            guard let path = paths[move.id], path != move.to else { continue }
            let actual = library.listedURL(ofPath: path)
            if let shown = library.listedURL(ofPath: move.to), library.index(of: shown) != nil {
                corrections.append(LibraryMoves.Move(from: shown, to: actual))
            } else if let actual, library.index(of: actual) == nil, let item = step.items[move.id] {
                restoring.append(FolderLibrary.item(item, at: actual))
            }
        }
        guard !corrections.isEmpty || !restoring.isEmpty else { return }
        await library.show(LibraryMoves(moves: corrections, restoring: restoring))
    }

    /// Returns once the saves asked for any of `photos` before the call are on disk.
    private func waitForSaves(of photos: [URL]) async {
        let saves = saves
        for photo in await Task.detached(priority: .userInitiated, operation: { saves.pending(photos) }).value {
            await saves.wait(for: photo)
        }
    }
}

/// Library's renames, made one at a time in the order they're asked for.
@MainActor
final class LibraryFileSteps {
    private var tail: Task<Void, Never>?

    /// Runs `body` once the steps asked for before it are made.
    func enqueue(_ body: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await body()
        }
    }

    /// `body` in its turn, and what it returns.
    func make<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            enqueue { await continuation.resume(returning: body()) }
        }
    }

    /// Returns once every step asked for is made.
    func made() async {
        while let tail {
            await tail.value
            if self.tail == tail {
                break
            }
        }
    }
}

/// One of Library's renames.
@MainActor
final class LibraryFileStep {
    enum Kind {
        case rename([PhotoRename])
    }

    let kind: Kind
    /// As the activity log names it: "Rename 12 Photos".
    let title: String
    /// Each photo, by index ID, and its path before and after the step.
    let photos: [(id: Int64, from: String, to: String)]
    /// The batch that made it.
    var batch: UUID?
    /// The photos as the folders shown listed them before it, by index ID.
    var items: [Int64: LibraryItem] = [:]
    /// The photos selected and the active one, before it.
    var selected: Set<URL> = []
    var active: URL?

    init(kind: Kind, title: String, photos: [(id: Int64, from: String, to: String)]) {
        self.kind = kind
        self.title = title
        self.photos = photos
    }
}

/// A batch's progress for the main thread: the latest only, with at most one hop to it waiting.
final class FileProgressRelay: Sendable {
    private let state = Mutex<(latest: FileProgress?, waiting: Bool)>((nil, false))
    private let deliver: @MainActor @Sendable (FileProgress) -> Void

    init(_ deliver: @escaping @MainActor @Sendable (FileProgress) -> Void) {
        self.deliver = deliver
    }

    func send(_ progress: FileProgress) {
        let hop = state.withLock { state -> Bool in
            state.latest = progress
            defer { state.waiting = true }
            return !state.waiting
        }
        guard hop else { return }
        Task { @MainActor [self] in
            let latest = state.withLock { state -> FileProgress? in
                state.waiting = false
                return state.latest
            }
            if let latest {
                deliver(latest)
            }
        }
    }
}
