import AppKit
import RedlampLibrary

/// What dropping photos on a row of the left panel does: the operation the drag shows, and the change made once
/// it's dropped.
struct PhotoDrop {
    var operation: NSDragOperation
    var perform: @MainActor () -> Void
}

/// Photos dragged from the grid onto the left panel (LIB-23, LIB-26). Onto a folder of Folders they move there as
/// Move to Folder moves them: one journaled batch with its progress in a sheet, each photo with its pair, sidecars
/// and other apps' `.xmp`, and Library's ⌘Z and ⇧⌘Z take it back and make it again. The library's batches don't
/// copy photos, so with ⌥ held the drop says so and moves nothing. A drop that can't happen is refused as the drag
/// passes over: onto the folder every photo is in already, a missing folder, one outside the library's folders,
/// or of photos the library doesn't have or that are in the Trash.
extension EditorModel {
    /// What dropping `photos` on `folder`, a row of Folders, does, given the operations the drag offers; nil refuses
    /// it.
    func photoDrop(
        _ photos: DraggedPhotos, onFolder folder: URL, isMissing: Bool, operations: NSDragOperation,
    ) -> PhotoDrop? {
        guard !isModalDialogOpen, photos.fromLibrary, !isMissing, library.service?.isReady == true,
              MoveFolderPanel.isInLibrary(folder, roots: library.roots.map(\.url))
        else { return nil }
        if let folders = photos.listed?.folders, folders == [LibraryService.path(folder)] {
            return nil
        }
        if !operations.contains(.move), operations.contains(.copy) {
            return PhotoDrop(operation: .copy) { [weak self] in self?.sayPhotosAreNotCopied(to: folder) }
        }
        guard let operation = [NSDragOperation.move, .generic].first(where: { operations.contains($0) }) else {
            return nil
        }
        return PhotoDrop(operation: operation) { [weak self] in
            Task { await self?.drop(photos, onFolder: folder) }
        }
    }

    /// Moves the photos dropped on `folder` there, the batch's progress in a sheet, and says in an alert why it
    /// didn't happen.
    func drop(_ photos: DraggedPhotos, onFolder folder: URL) async {
        let urls = await photos.urls()
        let sheet = FileProgressSheet.present("Moving to \(folder.lastPathComponent)", editor: self)
        let error = await movePhotos(urls, to: folder) { sheet?.show($0) }
        sheet?.close()
        guard let error, let window = EditorWindowController.frontWindow else { return }
        let alert = NSAlert()
        alert.messageText = "The photos weren't moved to \(folder.lastPathComponent)"
        alert.informativeText = error
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    /// Moves the photos at `urls`, with their pairs, into `folder` as one batch with Undo, `progress` hearing of its
    /// steps: Move to Folder's batch, for photos given rather than the selection. Why it didn't happen, or nil once
    /// it has.
    @discardableResult
    func movePhotos(
        _ urls: [URL], to folder: URL, progress: (@MainActor @Sendable (FileProgress) -> Void)? = nil,
    ) async -> String? {
        guard let service = library.service, let core = service.core, service.isReady else {
            return "The library isn't open"
        }
        guard MoveFolderPanel.isInLibrary(folder, roots: library.roots.map(\.url)) else {
            return "\(folder.lastPathComponent) isn't in the library's folders"
        }
        let found = await LibraryService.indexIDs(of: urls, in: core.index)
        let ids = urls.compactMap { found[$0] }
        guard !ids.isEmpty else { return "The library hasn't read these photos yet" }
        let destination = LibraryService.path(folder)
        let indexed = await (try? core.index.read { reader in
            try LibraryService.folder(at: destination, in: reader)?.path
        }) ?? nil
        let target = indexed ?? destination
        let all = await (try? core.files.withPairs(ids)) ?? ids
        let before = await service.paths(of: all)
        let photos = all.compactMap { id -> (id: Int64, from: String, to: String)? in
            guard let path = before[id], (path as NSString).deletingLastPathComponent != target else { return nil }
            let name = (path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
            return (id, path, target + "/" + name)
        }
        guard !photos.isEmpty else { return nil }
        let count = Set(photos.map(\.id)).count
        let step = LibraryFileStep(
            kind: .move(ids, folder),
            title: "Move \(count) Photo\(count == 1 ? "" : "s") to \(folder.lastPathComponent)", photos: photos,
        )
        let relay = FileProgressRelay { progress?($0) }
        let run = await fileSteps.make { [self] in
            await perform(step, undoing: false) { await service.move(ids, to: folder) { relay.send($0) } }
        }
        if let error = run.error {
            activity.record(.error, "\(step.title) wasn't done: \(error)")
        } else {
            activity.record(.action, step.title)
        }
        return run.error
    }

    /// ⌥ held as photos were dropped on `folder`: the library's batches move photos but don't copy them.
    func sayPhotosAreNotCopied(to folder: URL) {
        activity.record(.error, Self.notCopied)
        guard let window = EditorWindowController.frontWindow, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = Self.notCopied
        alert.informativeText = "Redlamp moves photos into a folder of the library, and Undo moves them back, but it "
            + "doesn't copy them yet. Drag them without ⌥ to move them to \(folder.lastPathComponent)."
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    @_spi(Harness) public static let notCopied = "Photos can't be copied to a folder yet"
}
