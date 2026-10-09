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
    /// Each photo's path now.
    var placed: [Int64: String] = [:]
    /// Photos whose file or sidecar is another one now, by their paths: copied to another volume,
    /// or their sidecars written.
    var refreshed: [Int64: String] = [:]
    var removedPhotos: [Int64] = []
    var removedFolderTrees: [Int64] = []
    var emptiedFolders: [String] = []

    var isEmpty: Bool {
        restoredFolders.isEmpty && madeFolders.isEmpty && movedFolders.isEmpty && restoredPhotos.isEmpty
            && placed.isEmpty && refreshed.isEmpty && removedPhotos.isEmpty && removedFolderTrees.isEmpty
            && emptiedFolders.isEmpty
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
        }
    }
}

extension FileOperations {
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
            var restored: [Int64] = []
            for (photo, name) in changes.restoredPhotos {
                guard let folder = try writer.folderID(forPath: photo.folder) else { continue }
                try restored.append(writer.restorePhoto(photo, inFolder: folder, name: name))
            }
            var moves: [(photo: Int64, folder: Int64, name: String)] = []
            for (id, path) in changes.placed.sorted(by: { $0.key < $1.key }) {
                let (folderPath, name) = FilePlanner.split(path)
                guard let folder = try writer.folderID(forPath: folderPath) else { continue }
                moves.append((id, folder, name))
            }
            let stale = try writer.placePhotos(moves)
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
        let changed = Array(Set(changes.placed.keys).union(changes.refreshed.keys))
        live.photosChanged(changed)
        if !changes.removedPhotos.isEmpty || !written.stale.isEmpty {
            live.receive(.photosRemoved(changes.removedPhotos + written.stale))
        }
        if !written.restored.isEmpty {
            live.receive(.photosInserted(written.restored))
        }
        if let folder = written.folders.first {
            live.receive(.folderIndexed(FolderIndexed(path: folder)))
        }
    }
}
