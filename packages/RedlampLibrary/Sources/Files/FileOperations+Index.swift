import Foundation
import RedlampDocument

/// What steps did to the index's rows, gathered for one write: the photos' and folders' new paths,
/// folders made and removed, rows taken out and put back. Each is where things are now, so writing
/// the same steps twice leaves the index as once. What the steps put somewhere is named as the
/// writes make it, in Unicode's composed form.
struct IndexChanges: Sendable {
    var restoredFolders: [RemovedFolder] = []
    var madeFolders: [String] = []
    var movedFolders: [FolderMove] = []
    var restoredPhotos: [(photo: RemovedPhoto, name: String)] = []
    /// Copies' rows, under their own IDs.
    var copiedPhotos: [RemovedPhoto] = []
    /// Each photo's path now.
    var placed: [Int64: String] = [:]
    /// Photos whose file or sidecar is another one now, by their paths: copied to another volume,
    /// or their sidecars written.
    var refreshed: [Int64: String] = [:]
    var removedPhotos: [Int64] = []
    var removedFolderTrees: [Int64] = []
    var emptiedFolders: [String] = []
    /// Rows taken out with nothing moved (`removeFromLibrary`), and whether each was missing then: one that was goes
    /// only while it still is.
    var leftPhotos: [(id: Int64, missing: Bool)] = []
    /// Rows put back as they were (`returnToLibrary`), unless another photo has taken a place since.
    var returnedPhotos: [RemovedPhoto] = []
    /// Missing photos found again: each one's ID, the path of the file it's found as, and that file as it was planned.
    var relinkedPhotos: [(id: Int64, path: String, file: FileItem)] = []
    /// Relinked photos back where they were, missing again, as their rows were.
    var unlinkedPhotos: [RemovedPhoto] = []

    var isEmpty: Bool {
        restoredFolders.isEmpty && madeFolders.isEmpty && movedFolders.isEmpty && restoredPhotos.isEmpty
            && copiedPhotos.isEmpty && placed.isEmpty && refreshed.isEmpty && removedPhotos.isEmpty
            && removedFolderTrees.isEmpty && emptiedFolders.isEmpty && leftPhotos.isEmpty && returnedPhotos.isEmpty
            && relinkedPhotos.isEmpty && unlinkedPhotos.isEmpty
    }

    mutating func add(_ step: FileStep) {
        switch step.kind {
        case .move:
            // A copy is another file; a sidecar package taken to another folder may have a new date.
            let refreshes = step.items.contains { item in
                item.copies || (item.role == .sidecar || item.role == .sidecarOnThisMac)
                    && FilePlanner.split(item.source).folder != FilePlanner.split(item.destination ?? "").folder
            }
            for photo in step.photos {
                let path = FilePlanner.composedLast(photo.to)
                placed[photo.id] = path
                if refreshes || refreshed[photo.id] != nil {
                    refreshed[photo.id] = path
                }
            }
            movedFolders += step.folders
                .map { FolderMove(id: $0.id, from: $0.from, to: FilePlanner.composedLast($0.to)) }
        case .createFolder:
            if let folder = step.folder.map(FilePlanner.composedLast) {
                madeFolders.append(folder)
                emptiedFolders.removeAll { $0 == folder }
            }
        case .removeFolder:
            if let folder = step.folder {
                emptiedFolders.append(folder)
                madeFolders.removeAll { $0 == folder }
            }
        case .trash:
            let ids = step.removed.map(\.photo.id)
            removedPhotos += ids
            for id in ids {
                placed.removeValue(forKey: id)
                refreshed.removeValue(forKey: id)
            }
            copiedPhotos.removeAll { Set(ids).contains($0.photo.id) }
            if let top = step.removedFolders.first {
                removedFolderTrees.append(top.id)
            }
        case .putBack:
            if let top = step.removedFolders.first?.path {
                // A folder put back whole: its own name as it's made now, the paths below it following.
                let composed = FilePlanner.composedLast(top)
                func moved(_ path: String) -> String {
                    path == top ? composed : path.hasPrefix(top + "/") ? composed + path.dropFirst(top.count) : path
                }
                restoredFolders += step.removedFolders.map { folder in
                    var folder = folder
                    folder.path = moved(folder.path)
                    return folder
                }
                restoredPhotos += step.removed.map { removed in
                    var removed = removed
                    removed.folder = moved(removed.folder)
                    return (removed, removed.photo.name)
                }
            } else {
                restoredPhotos += step.removed.map { ($0, $0.photo.name.precomposedStringWithCanonicalMapping) }
            }
            let ids = Set(step.removed.map(\.photo.id))
            removedPhotos.removeAll { ids.contains($0) }
        case .recordOriginalNames, .clearOriginalNames:
            for photo in step.photos {
                refreshed[photo.id] = photo.to
            }
        case .copy:
            // Another file, whose identifier and sidecar's date are taken from it.
            for copy in step.removed {
                copiedPhotos.append(copy)
                refreshed[copy.photo.id] = FilePlanner.composedLast(copy.folder + "/" + copy.photo.name)
            }
            let ids = Set(step.removed.map(\.photo.id))
            removedPhotos.removeAll { ids.contains($0) }
        case .detachCopies:
            for photo in step.photos {
                refreshed[photo.id] = FilePlanner.composedLast(photo.to)
            }
        case .removeFromLibrary:
            let ids = Set(step.removed.map(\.photo.id))
            leftPhotos += step.removed.map { removed in
                (removed.photo.id, PhotoRecord.State(rawValue: removed.photo.state).contains(.missing))
            }
            returnedPhotos.removeAll { ids.contains($0.photo.id) }
        case .returnToLibrary:
            let ids = Set(step.removed.map(\.photo.id))
            returnedPhotos += step.removed
            leftPhotos.removeAll { ids.contains($0.id) }
        case .relink:
            guard let move = step.photos.first, let file = step.items.first(where: { $0.destination == nil })
            else { return }
            let path = FilePlanner.composedLast(move.to)
            relinkedPhotos.append((move.id, path, file))
            unlinkedPhotos.removeAll { $0.photo.id == move.id }
            refreshed[move.id] = path
        case .unlink:
            let ids = Set(step.removed.map(\.photo.id))
            unlinkedPhotos += step.removed
            relinkedPhotos.removeAll { ids.contains($0.id) }
            for id in ids {
                refreshed.removeValue(forKey: id)
            }
        }
    }
}

extension FileOperations {
    /// The folders `steps` change, which the indexer leaves while their batch runs (`FolderHolds`): those holding the
    /// files they move, and the folders they move, make or remove, with everything below them.
    static func heldFolders(_ steps: [FileStep]) -> Set<FolderHolds.Folder> {
        var held = Set<FolderHolds.Folder>()
        func hold(folder path: String) {
            held.insert(FolderHolds.Folder(path, subtree: true))
            held.insert(FolderHolds.Folder(FilePlanner.split(path).folder))
        }
        for step in steps {
            for item in step.items {
                for path in [item.source, item.destination].compactMap(\.self) {
                    if item.isDirectory {
                        hold(folder: path)
                    } else {
                        held.insert(FolderHolds.Folder(FilePlanner.split(path).folder))
                    }
                }
            }
            step.folder.map(hold(folder:))
            for move in step.folders {
                hold(folder: move.from)
                hold(folder: move.to)
            }
            for folder in step.removedFolders {
                hold(folder: folder.path)
            }
            for removed in step.removed {
                held.insert(FolderHolds.Folder(removed.folder))
            }
        }
        return held
    }

    /// Writes what `steps` did to the index in one transaction, without reading any photo: file
    /// identifiers and sidecars' dates are taken from the files' attributes. Rows of files gone that held a
    /// place a step took go with their XMP merge records, unless a batch can bring them back. Then `live`
    /// hears of it.
    func record(_ changes: IndexChanges, locator: SidecarLocator) async throws {
        guard !changes.isEmpty else { return }
        let fileSystem = fileSystem
        let attributes = try await LibraryIndex.offCaller {
            changes.refreshed.map { id, path -> (Int64, UInt64?, Date?) in
                let photo = URL(fileURLWithPath: path)
                let file = try? fileSystem.attributes(of: photo)
                let sidecar = try? fileSystem.attributes(of: locator.readURL(for: photo))
                return (id, file?.fileIdentifier, sidecar?.modified)
            }
        }
        let written = try await index.write { writer -> (restored: [Int64], stale: [Int64], folders: Set<String>) in
            var folders = Set<String>()
            for folder in changes.restoredFolders {
                try writer.restoreFolder(folder)
                folders.insert(folder.path)
            }
            for path in changes.madeFolders {
                _ = try writer.folderID(forPath: path, makingEmpty: true)
                folders.insert(path)
            }
            for move in changes.movedFolders {
                let parentPath = FilePlanner.split(move.to).folder
                guard let root = try writer.root(containing: move.to),
                      let id = try writer.folder(anyFormOf: move.from)?.id ?? writer.folder(id: move.id)?.id
                else { continue }
                let parent = move.to == root.path ? nil : try writer.folderID(forPath: parentPath)
                try writer.moveFolder(id, to: move.to, parent: parent, root: root.id)
                folders.formUnion([move.from, move.to])
            }
            var (restored, stale) = try Self.writeRelinks(changes, writer: writer)
            for (photo, name) in changes.restoredPhotos {
                guard let folder = try writer.folderID(forPath: photo.folder) else { continue }
                try restored.append(writer.restorePhoto(photo, inFolder: folder, name: name))
            }
            for copy in changes.copiedPhotos {
                guard let folder = try writer.folderID(forPath: copy.folder) else { continue }
                // A row holding the copy's place is of a file that's gone: its collections aren't the copy's.
                if let holder = try writer.photo(folder: folder, name: copy.photo.name), holder.id != copy.photo.id {
                    try writer.deletePhotos([holder.id])
                    stale.append(holder.id)
                }
                try restored.append(writer.restorePhoto(copy, inFolder: folder, name: copy.photo.name))
            }
            var moves: [(photo: Int64, folder: Int64, name: String)] = []
            for (id, path) in changes.placed.sorted(by: { $0.key < $1.key }) {
                let (folderPath, name) = FilePlanner.split(path)
                guard let folder = try writer.folderID(forPath: folderPath) else { continue }
                moves.append((id, folder, name))
            }
            stale += try writer.placePhotos(moves)
            for (id, fileID, sidecar) in attributes {
                if changes.placed[id] != nil || fileID != nil {
                    try writer.setFileID(fileID, forPhoto: id)
                }
                try writer.setSidecarModified(sidecar, forPhoto: id)
            }
            try writer.deletePhotos(changes.removedPhotos)
            for folder in changes.removedFolderTrees {
                if let path = try writer.folder(id: folder)?.path {
                    folders.insert(path)
                }
                try writer.deleteFolder(folder)
            }
            for path in changes.emptiedFolders.reversed() where try writer.removeFolderIfEmpty(path) {
                folders.insert(path)
            }
            return (restored, stale, folders)
        }
        if !written.stale.isEmpty {
            try await removeUnrestorableNow(gone: Set(written.stale))
        }
        guard let live else { return }
        let changed = Set(changes.placed.keys).union(changes.refreshed.keys)
            .union(changes.unlinkedPhotos.map(\.photo.id))
        live.photosChanged(Array(changed))
        if !changes.removedPhotos.isEmpty || !changes.leftPhotos.isEmpty || !written.stale.isEmpty {
            live.receive(.photosRemoved(changes.removedPhotos + changes.leftPhotos.map(\.id) + written.stale))
        }
        if !written.restored.isEmpty {
            live.receive(.photosInserted(written.restored))
        }
        if let folder = written.folders.first {
            live.receive(.folderIndexed(FolderIndexed(path: folder)))
        }
    }

    /// Writes the steps that change rows with nothing moved (DEC-59): rows taken out first, so a relink can take the
    /// place one had; relinked photos put back where they were missing, then photos relinked; then rows put back, in
    /// places an Undo of a relink has freed. A photo doesn't go back to a place another photo has taken since: it stays
    /// relinked, or out. Returns the photos put back, and those of rows removed that held a relinked photo's place.
    private static func writeRelinks(
        _ changes: IndexChanges, writer: LibraryIndex.Writer,
    ) throws -> (restored: [Int64], stale: [Int64]) {
        try writer.deletePhotos(changes.leftPhotos.filter { left in
            try !left.missing || writer.photo(id: left.id)?.state.contains(.missing) == true
        }.map(\.id))
        var restored: [Int64] = []
        var stale: [Int64] = []
        func isFree(_ photo: RemovedPhoto) throws -> Int64? {
            guard let folder = try writer.folderID(forPath: photo.folder) else { return nil }
            let holder = try writer.photo(folder: folder, name: photo.photo.name)
            return holder == nil || holder?.id == photo.photo.id ? folder : nil
        }
        for photo in changes.unlinkedPhotos {
            guard try writer.photo(id: photo.photo.id) != nil, let folder = try isFree(photo) else { continue }
            try writer.deletePhotos([photo.photo.id])
            try restored.append(writer.restorePhoto(photo, inFolder: folder, name: photo.photo.name))
        }
        for relink in changes.relinkedPhotos {
            let (folderPath, name) = FilePlanner.split(relink.path)
            guard let folder = try writer.folderID(forPath: folderPath) else { continue }
            stale += try writer.relinkPhoto(
                relink.id, toFolder: folder, name: name, fileID: relink.file.fileID, size: relink.file.size,
                modified: relink.file.modified,
            )
        }
        for photo in changes.returnedPhotos {
            guard try writer.photo(id: photo.photo.id) == nil, let folder = try isFree(photo) else { continue }
            try restored.append(writer.restorePhoto(photo, inFolder: folder, name: photo.photo.name))
        }
        return (restored, stale)
    }
}
