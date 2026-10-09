import AppKit
import RedlampLibrary

/// What dropping photos on a row of the left panel does: the operation the drag shows, and the change made once
/// it's dropped.
struct PhotoDrop {
    var operation: NSDragOperation
    var perform: @MainActor () -> Void
}

/// A batch under way in Library (LIB-26), shown in the grid's toolbar rather than in a sheet: a drop's move or copy,
/// with actions off meanwhile as they are under a sheet, and an Undo or Redo of a rename, move or copy, which leave
/// them on. A sheet dims the window as it comes and goes by drawing the window into a bitmap, a tenth of a second and
/// more on the main thread with thousands of thumbnails on screen. Its Stop stops the batch after the photo in hand.
@MainActor
@Observable
public final class LibraryMoveProgress {
    /// What's being done ("Moving to Picked"), while it is.
    public internal(set) var title: String?
    public internal(set) var progress: FileProgress?
    /// Its Stop was pressed, and the batch is finishing the photo in hand.
    public internal(set) var isStopping = false
    /// What stops the batch shown.
    private(set) var stop: FileStop?
    /// What `begin` gave for what's shown.
    private var shown: UUID?

    /// Shows `title` for a batch `stop` stops, until `end` is given what this returns.
    func begin(_ title: String, stop: FileStop?) -> UUID {
        let token = UUID()
        shown = token
        self.title = title
        progress = nil
        self.stop = stop
        isStopping = false
        return token
    }

    /// Shows `progress` for what `token` began, while it's shown.
    func show(_ progress: FileProgress, for token: UUID) {
        if shown == token {
            self.progress = progress
        }
    }

    /// Takes away what `token` began, unless something else was shown since; whether it did.
    @discardableResult
    func end(_ token: UUID) -> Bool {
        guard shown == token else { return false }
        shown = nil
        title = nil
        progress = nil
        stop = nil
        isStopping = false
        return true
    }

    /// Stop, as its button presses it.
    @_spi(Harness) public func pressStop() {
        guard let stop, !isStopping else { return }
        isStopping = true
        stop.stop()
    }

    @_spi(Harness) public var canStop: Bool {
        stop != nil && !isStopping
    }
}

/// Photos dragged from the grid onto the left panel (LIB-23, LIB-26). Onto a folder of Folders they move there as
/// Move to Folder moves them: one journaled batch, its progress and Stop in the grid's toolbar, each photo with its
/// pair, sidecars and other apps' `.xmp`, and Library's ⌘Z and ⇧⌘Z take it back and make it again. With ⌥ held they're
/// copied there, as Copy to Folder copies them, the pointer showing the copy badge, onto the folder they're in too; a
/// copy's Undo moves the copies to the Trash. A drop that can't happen is refused as the drag passes over: a move
/// onto the folder every photo is in already, a missing folder, one outside the library's folders, or of photos the
/// library doesn't have or that are in the Trash.
extension EditorModel {
    /// What dropping `photos` on `folder`, a row of Folders, does, given the operations the drag offers; nil refuses
    /// it.
    func photoDrop(
        _ photos: DraggedPhotos, onFolder folder: URL, isMissing: Bool, operations: NSDragOperation,
    ) -> PhotoDrop? {
        guard !isModalDialogOpen, photos.fromLibrary, !isMissing, library.service?.isReady == true,
              MoveFolderPanel.isInLibrary(folder, roots: library.roots.map(\.url))
        else { return nil }
        if !operations.contains(.move), operations.contains(.copy) {
            return PhotoDrop(operation: .copy) { [weak self] in
                Task { await self?.drop(photos, onFolder: folder, copying: true) }
            }
        }
        if let folders = photos.listed?.folders, folders == [LibraryService.path(folder)] {
            return nil
        }
        guard let operation = [NSDragOperation.move, .generic].first(where: { operations.contains($0) }) else {
            return nil
        }
        return PhotoDrop(operation: operation) { [weak self] in
            Task { await self?.drop(photos, onFolder: folder, copying: false) }
        }
    }

    /// Moves or copies the photos dropped on `folder` there, the batch's progress and Stop in the grid's toolbar,
    /// and says in an alert why it didn't happen. Actions come back in the batch's own turn, as it ends, so ⌘Z is
    /// there the moment it's done, before anything asked for after it.
    func drop(_ photos: DraggedPhotos, onFolder folder: URL, copying: Bool) async {
        let urls = await photos.urls()
        let stop = FileStop()
        let shown = moveProgress
        let token = shown.begin("\(copying ? "Copying" : "Moving") to \(folder.lastPathComponent)", stop: stop)
        isModalDialogOpen = true
        let done: @MainActor () -> Void = { [weak self] in
            if shown.end(token) {
                self?.isModalDialogOpen = false
            }
        }
        let error = await place(
            urls, in: folder, copying: copying, progress: { shown.show($0, for: token) }, done: done, stop: stop,
        )
        done()
        guard let error, let window = EditorWindowController.frontWindow else { return }
        let alert = NSAlert()
        alert.messageText = "The photos weren't \(copying ? "copied" : "moved") to \(folder.lastPathComponent)"
        alert.informativeText = error
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    /// Moves the photos at `urls`, with their pairs, into `folder` as one batch with Undo, `progress` hearing of its
    /// steps and `done` called in its turn once the batch has run: Move to Folder's batch, for photos given rather
    /// than the selection. Why it didn't happen, or nil once it has.
    @discardableResult
    func movePhotos(
        _ urls: [URL], to folder: URL, progress: (@MainActor @Sendable (FileProgress) -> Void)? = nil,
        done: (@MainActor () -> Void)? = nil, stop: FileStop? = nil,
    ) async -> String? {
        await place(urls, in: folder, copying: false, progress: progress, done: done, stop: stop)
    }

    /// Copies the photos at `urls`, with their pairs, into `folder` as one batch with Undo, as `movePhotos` moves
    /// them: Copy to Folder's batch.
    @discardableResult
    func copyPhotos(
        _ urls: [URL], to folder: URL, progress: (@MainActor @Sendable (FileProgress) -> Void)? = nil,
        done: (@MainActor () -> Void)? = nil, stop: FileStop? = nil,
    ) async -> String? {
        await place(urls, in: folder, copying: true, progress: progress, done: done, stop: stop)
    }

    private func place(
        _ urls: [URL], in folder: URL, copying: Bool, progress: (@MainActor @Sendable (FileProgress) -> Void)?,
        done: (@MainActor () -> Void)?, stop: FileStop?,
    ) async -> String? {
        guard let core = library.service?.core else { return "The library isn't open" }
        let found = await LibraryService.indexIDs(of: urls, in: core.index)
        return await place(
            urls.compactMap { found[$0] }, in: folder, copying: copying, progress: progress, done: done, stop: stop,
        )
    }

    /// Moves or copies photos `ids`, with their pairs, into `folder` as one batch with Undo, `progress` hearing of its
    /// steps until `stop` stops it, and `done` called in its turn once the batch has run. Why it didn't happen, or nil
    /// once it has.
    func place(
        _ ids: [Int64], in folder: URL, copying: Bool, progress: (@MainActor @Sendable (FileProgress) -> Void)?,
        done: (@MainActor () -> Void)?, stop: FileStop?,
    ) async -> String? {
        guard let service = library.service, let core = service.core, service.isReady else {
            return "The library isn't open"
        }
        guard MoveFolderPanel.isInLibrary(folder, roots: library.roots.map(\.url)) else {
            return "\(folder.lastPathComponent) isn't in the library's folders"
        }
        guard !ids.isEmpty else { return "The library hasn't read these photos yet" }
        let destination = LibraryService.path(folder)
        let indexed = await (try? core.index.read { reader in
            try LibraryService.folder(at: destination, in: reader)?.path
        }) ?? nil
        let target = indexed ?? destination
        let all = await (try? core.files.withPairs(ids)) ?? ids
        let before = await service.paths(of: all)
        let photos = all.compactMap { id -> (id: Int64, from: String, to: String)? in
            guard let path = before[id] else { return nil }
            guard !copying else { return (id, path, path) }
            guard (path as NSString).deletingLastPathComponent != target else { return nil }
            let name = (path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
            return (id, path, target + "/" + name)
        }
        guard !photos.isEmpty else { return nil }
        let step = LibraryFileStep(kind: copying ? .copy(ids, folder) : .move(ids, folder), photos: photos)
        let relay = FileProgressRelay { progress?($0) }
        let report: @Sendable (FileProgress) -> Void = { relay.send($0) }
        push(step)
        let run = await fileSteps.make { [self] in
            let run = await perform(step, undoing: false) {
                if copying {
                    await service.copy(ids, to: folder, progress: report, stop: stop)
                } else {
                    await service.move(ids, to: folder, progress: report, stop: stop)
                }
            }
            done?()
            return run
        }
        record(run, of: step)
        return run.error
    }

    /// A batch under way, for the grid's toolbar.
    @_spi(Harness) public var moveProgress: LibraryMoveProgress {
        if let progress = Self.moveProgresses.object(forKey: self) {
            return progress
        }
        let progress = LibraryMoveProgress()
        Self.moveProgresses.setObject(progress, forKey: self)
        return progress
    }

    private static let moveProgresses = NSMapTable<EditorModel, LibraryMoveProgress>.weakToStrongObjects()
}

/// Photos dragged onto a collection go in it, as Photo › Add to Collection puts them (LIB-23): one change with
/// Undo on Library's ⌘Z and ⇧⌘Z. A set and a smart collection, whose photos are their query's, refuse them.
extension LibrarySources {
    /// What dropping `photos` on the place at `path` in the collection list does, given the operations the drag
    /// offers; nil refuses it.
    func photoDrop(_ photos: DraggedPhotos, onto path: CollectionPath, operations: NSDragOperation) -> PhotoDrop? {
        guard let model, !model.isModalDialogOpen, photos.fromLibrary, collections[path]?.kind == .collection,
              let operation = [NSDragOperation.copy, .generic, .move].first(where: { operations.contains($0) })
        else { return nil }
        return PhotoDrop(operation: operation) { [weak self] in
            Task { await self?.add(photos, to: path) }
        }
    }

    /// Puts the photos dropped in the collection at `path`, then counts again.
    func add(_ photos: DraggedPhotos, to path: CollectionPath) async {
        let urls = await photos.urls()
        let ids = await indexIDs(of: urls)
        guard !ids.isEmpty, let panels = model?.libraryPanels, panels.make(
            [.collections(.add(ids, to: path))], title: "Add \(Self.count(ids.count)) to “\(path.displayName)”",
            photos: (urls, ids),
        ) else { return }
        await panels.written()
        recount()
    }
}
