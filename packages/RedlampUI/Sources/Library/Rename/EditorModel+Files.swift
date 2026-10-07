import AppKit
import Foundation
import RedlampLibrary
import Synchronization

/// Renaming and moving photos in Library (LIB-25, LIB-26), each one of the library's journaled batches with
/// Undo and Redo on Library's ⌘Z and ⇧⌘Z, in turn with culling's changes.
///
/// - **Shown at once:** the photos go where the batch puts them in the grid and the filmstrip before it runs
///   (`LibraryMoves`), each keeping its ID, so the selection follows; the active photo, leaving Develop's
///   document first, goes with it. The library's lists then find each photo where it already is.
/// - **Saved first:** the sidecars the photos' saves still write are on disk before the batch plans, and the
///   batch runs in the library's changes' turn, after the culling batches asked for before it.
/// - **Afterwards,** each photo is shown where the index has it, so a batch that stopped or was rolled back
///   shows what it left.
/// - **Undo and Redo:** a step is newer than culling's latest change when culling's Undo held that change as
///   the step was made; Redo makes the step again with a batch planned anew, and a culling change made since
///   its Undo ends it, as a new change ends Redo. Steps are made one at a time, in the order they're asked for.
public extension EditorModel {
    /// File steps Undo can take back.
    static let fileUndoLimit = 20

    /// Rename Photos…: the template sheet for the photos selected, with their raw and JPEG pairs.
    @discardableResult
    func renamePhotos() -> Bool {
        guard let sheet = renameSheet() else { return false }
        RenameSheetController.present(sheet, editor: self)
        return true
    }

    /// Rename Photos and Move to Folder act on Library's selection, with the library open.
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

    /// Rename Photos, Move to Folder, and Library's Undo and Redo when a file step is newer than culling's latest
    /// change; nil
    /// for every other action.
    func performFileShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .renamePhotos: renamePhotos()
        case .moveToFolder: moveToFolder()
        case .undo where module == .library && fileUndoIsNewest: undoFiles()
        case .redo where module == .library && fileRedoIsNewest: redoFiles()
        default: nil
        }
    }

    func canPerformFileShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .renamePhotos, .moveToFolder: canRenamePhotos
        case .undo where module == .library && fileUndoIsNewest: true
        case .redo where module == .library && fileRedoIsNewest: true
        default: nil
        }
    }

    /// The renames and moves Undo and Redo take back and make again.
    var fileSteps: LibraryFileSteps {
        if let steps = Self.fileSteps.object(forKey: self) {
            return steps
        }
        let steps = LibraryFileSteps()
        Self.fileSteps.setObject(steps, forKey: self)
        return steps
    }

    private static let fileSteps = NSMapTable<EditorModel, LibraryFileSteps>.weakToStrongObjects()

    /// Undo's latest file step was made when culling's Undo held its latest change, or held none.
    var fileUndoIsNewest: Bool {
        guard let step = fileSteps.undo.last else { return false }
        guard let latest = cullingUndo.last else { return true }
        return step.olderCulling.contains { $0 === latest }
    }

    /// Redo's latest file step was taken back after culling's latest change taken back; a culling change made
    /// since it was taken back ends every file step's Redo.
    var fileRedoIsNewest: Bool {
        guard let step = fileSteps.redo.last else { return false }
        if cullingUndo.contains(where: { change in !step.knownCulling.contains { $0 === change } }) {
            fileSteps.redo.removeAll()
            return false
        }
        guard let latest = cullingRedo.last else { return true }
        return step.undoneAfter.contains { $0 === latest }
    }

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
            await perform(step, undoing: false) { await service.rename(renames) { relay.send($0) } }
        }
        if run.batch != nil {
            sheet.renamed(batch)
            activity.record(.action, step.title)
        }
        return run.error
    }

    // MARK: - Undo and Redo

    /// Takes back the latest file step: shown at once, then its batch's Undo in the background.
    @discardableResult
    func undoFiles() -> Bool {
        guard module == .library, let service = library.service, let step = fileSteps.undo.last,
              let batch = step.batch
        else { return false }
        fileSteps.undo.removeLast()
        step.undoneAfter = cullingRedo
        step.knownCulling = cullingUndo + cullingRedo
        fileSteps.redo.append(step)
        activity.record(.action, "Undo \(step.title)")
        let ids = step.photos.map(\.id)
        fileSteps.enqueue { [weak self] in
            guard let self else { return }
            let run = await perform(step, undoing: true) { await service.undoFiles(batch, photos: ids) }
            guard let error = run.error else { return }
            activity.record(.error, "Undo \(step.title) wasn't done: \(error)")
            if run.batch == nil, let place = fileSteps.redo.lastIndex(where: { $0 === step }) {
                fileSteps.redo.remove(at: place)
                fileSteps.undo.append(step)
            }
        }
        return true
    }

    /// Makes the file step Undo took back last again, with a batch planned anew.
    @discardableResult
    func redoFiles() -> Bool {
        guard module == .library, let service = library.service, let step = fileSteps.redo.popLast() else {
            return false
        }
        step.olderCulling = cullingUndo
        fileSteps.undo.append(step)
        activity.record(.action, "Redo \(step.title)")
        fileSteps.enqueue { [weak self] in
            guard let self else { return }
            let run = await perform(step, undoing: false) {
                switch step.kind {
                case let .rename(renames): await service.rename(renames)
                case let .move(ids, folder): await service.move(ids, to: folder)
                }
            }
            if let batch = run.batch {
                step.batch = batch
            }
            guard let error = run.error else { return }
            activity.record(.error, "Redo \(step.title) wasn't done: \(error)")
            if run.batch == nil, let place = fileSteps.undo.lastIndex(where: { $0 === step }) {
                fileSteps.undo.remove(at: place)
                fileSteps.redo.append(step)
            }
        }
        return true
    }

    // MARK: - Making a step

    /// Shows `step` (or its Undo) at once, waits for its photos' saves, runs `batch`, then shows each photo
    /// where the index has it. A new step goes on Undo once its batch has run, ending Redo.
    func perform(
        _ step: LibraryFileStep, undoing: Bool, batch: @escaping () async -> LibraryService.FileRun,
    ) async -> LibraryService.FileRun {
        let isNew = step.batch == nil && !undoing && !fileSteps.undo.contains { $0 === step }
        let moves = step.photos.map { photo in
            undoing ? (id: photo.id, from: photo.to, to: photo.from) : photo
        }
        let saving = await show(moves, of: step, undoing: undoing)
        await waitForSaves(of: saving)
        let run = await batch()
        await follow(moves, of: step, paths: run.paths)
        if isNew, let made = run.batch {
            step.batch = made
            step.olderCulling = cullingUndo
            fileSteps.undo.append(step)
            if fileSteps.undo.count > Self.fileUndoLimit {
                fileSteps.undo.removeFirst(fileSteps.undo.count - Self.fileUndoLimit)
            }
            fileSteps.redo.removeAll()
            cullingRedo.removeAll()
        }
        return run
    }

    /// Shows `moves` at once: the photos at their new URLs, or out of the folders shown; a move's Undo shows
    /// again the photos it took away, selected as they were. The active photo goes with them, or, when it
    /// leaves the folders shown, the photo after it becomes active. Returns the URLs of the photos as they were,
    /// whose saves the batch waits for.
    private func show(
        _ moves: [(id: Int64, from: String, to: String)], of step: LibraryFileStep, undoing: Bool,
    ) async -> [URL] {
        // What was asked for before reaches the lists first: culling's batches, then the list's changes.
        await cullingTail?.value
        if let core = library.service?.core {
            var sentinel = moves.lazy.compactMap { move -> (id: Int64, url: URL)? in
                guard let url = self.library.listedURL(ofPath: move.from), self.library.contentKey(of: url) != nil
                else { return nil }
                return (move.id, url)
            }.first
            if sentinel == nil, let url = items.first(where: { library.contentKey(of: $0.url) != nil })?.url,
               let id = await LibraryService.indexIDs(of: [url], in: core.index)[url] {
                sentinel = (id, url)
            }
            if let sentinel {
                await library.caughtUp(with: sentinel, live: core.live)
            }
        }
        var shown: [LibraryMoves.Move] = []
        var restoring: [LibraryItem] = []
        var keys: [URL: ContentKey] = [:]
        var saving: [URL] = []
        for move in moves {
            saving.append(URL(fileURLWithPath: move.from))
            let to = library.listedURL(ofPath: move.to)
            guard let from = library.listedURL(ofPath: move.from), library.index(of: from) != nil else {
                if let to, let item = step.items[move.id] {
                    restoring.append(FolderLibrary.item(item, at: to))
                    keys[to] = step.keys[move.id]
                }
                continue
            }
            saving.append(from)
            if !undoing, step.items[move.id] == nil, let item = library.item(for: from) {
                step.items[move.id] = item
                step.keys[move.id] = library.contentKey(of: from)
            }
            shown.append(LibraryMoves.Move(from: from, to: to))
        }
        if !undoing, step.active == nil {
            step.selected = Set(selectedPhotos)
            step.active = selection
        }
        let (active, activeRow) = (selection, selectionIndex)
        let destination = active.flatMap { active in shown.first { $0.from == active } }
        await library.show(LibraryMoves(moves: shown, restoring: restoring, keys: keys)) { [self] in
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
        if !restoring.isEmpty, let active = step.active, library.index(of: active) != nil {
            select(active, keepingSelection: true)
            photoSelection.select(
                step.selected.compactMap(library.photoID(of:)), active: library.photoID(of: active),
                in: library.photoList,
            )
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
        var keys: [URL: ContentKey] = [:]
        for move in moves {
            guard let path = paths[move.id], path != move.to else { continue }
            let actual = library.listedURL(ofPath: path)
            if let shown = library.listedURL(ofPath: move.to), library.index(of: shown) != nil {
                corrections.append(LibraryMoves.Move(from: shown, to: actual))
            } else if let actual, library.index(of: actual) == nil, let item = step.items[move.id] {
                restoring.append(FolderLibrary.item(item, at: actual))
                keys[actual] = step.keys[move.id]
            }
        }
        guard !corrections.isEmpty || !restoring.isEmpty else { return }
        await library.show(LibraryMoves(moves: corrections, restoring: restoring, keys: keys))
    }

    /// Returns once the saves asked for any of `photos` before the call are on disk.
    private func waitForSaves(of photos: [URL]) async {
        let saves = saves
        for photo in await Task.detached(priority: .userInitiated, operation: { saves.pending(photos) }).value {
            await saves.wait(for: photo)
        }
    }
}

/// The renames and moves Library's Undo and Redo take back and make again, made one at a time in the order
/// they're asked for.
@MainActor
final class LibraryFileSteps {
    var undo: [LibraryFileStep] = []
    var redo: [LibraryFileStep] = []
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

/// One of Library's renames or moves, as Undo takes it back and Redo makes it again.
@MainActor
final class LibraryFileStep {
    enum Kind {
        case rename([PhotoRename])
        /// The photos asked for, by index ID, and the folder they go to.
        case move([Int64], URL)
    }

    let kind: Kind
    /// As Undo and the activity log name it: "Rename 12 Photos".
    let title: String
    /// Each photo, by index ID, and its path before and after the step.
    let photos: [(id: Int64, from: String, to: String)]
    /// The batch that made it last, for its Undo.
    var batch: UUID?
    /// The photos as the folders shown listed them before it, and their content keys, by index ID: a move's Undo
    /// shows them again.
    var items: [Int64: LibraryItem] = [:]
    var keys: [Int64: ContentKey] = [:]
    /// The photos selected and the active one, before it.
    var selected: Set<URL> = []
    var active: URL?
    /// Culling's changes on its Undo as the step was made or made again: those older than it.
    var olderCulling: [CullingStep] = []
    /// Culling's changes on its Redo as the step was taken back, which Redo makes after it.
    var undoneAfter: [CullingStep] = []
    /// Every culling change there was as the step was taken back: one not among them is newer.
    var knownCulling: [CullingStep] = []

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
