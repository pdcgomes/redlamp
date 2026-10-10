import Foundation
import RedlampDocument

public extension FileOperations {
    /// The batch that copies photos `ids`, each with its pair and its files, into `folder`, which must be in the
    /// library; the folder they're in is one too. Each copy is a photo of its own, under a new ID, with its
    /// original's `.redlamp` sidecars and other apps', so its edit, rating, label, keywords and metadata, but in
    /// none of its original's collections and not in its stack. A copy whose name is held in `folder` gets a
    /// number, as the Finder numbers a copy it keeps beside another (`IMG_0001 2.JPG`), its pair and sidecars with
    /// it, and its original's name as its original name unless it has one. The index gets each copy's row from its
    /// original's, so no photo is read, and the store's thumbnails serve both. Undo moves the copies to the Trash.
    func planCopy(photos ids: [Int64], to folder: URL) async throws -> FileBatch {
        let destination = try await indexedPath(LibraryIndexer.path(folder))
        guard try await index.read({ try $0.root(containing: destination) }) != nil else {
            throw FileOperationError.notInLibrary(destination)
        }
        let ids = try await withPairs(ids)
        let originals = try await index.read { reader in
            try reader.photosWithPaths(ids).map { photo, folder in
                try (photo: photo, folder: folder, keywords: reader.keywords(forPhoto: photo.id))
            }
        }
        let count = originals.count
        let title = "Copy \(count) photo\(count == 1 ? "" : "s") to \(folder.lastPathComponent)"
        guard !originals.isEmpty else { return FileBatch(kind: .copy, title: title, steps: []) }
        // Given now, so the journal holds them: a batch a forced quit cut short gives the same rows again.
        let copyIDs = try await index.write { writer in try originals.map { _ in try writer.newID(of: .photos) } }
        var groups: [(folder: String, stem: String, members: [Int])] = []
        var byStem: [String: Int] = [:]
        for (number, original) in originals.enumerated() {
            let stem = NamingJob.split(original.photo.name).base
            let key = NamingJob.fold(original.folder + "/" + stem)
            if let group = byStem[key] {
                groups[group].members.append(number)
            } else {
                byStem[key] = groups.count
                groups.append((original.folder, stem, [number]))
            }
        }
        let locator = try await locator()
        let fileSystem = fileSystem
        let steps = try await LibraryIndex.offCaller { [groups] in
            let planner = FilePlanner(fileSystem: fileSystem, locator: locator)
            var taken = Set<String>()
            let copies = groups.map { group -> (moves: [PhotoMove], rows: [RemovedPhoto]) in
                let extensions = group.members.map { NamingJob.split(originals[$0].photo.name).ext }
                let stem = planner.copyStem(
                    group.stem.precomposedStringWithCanonicalMapping, extensions: extensions, in: destination,
                    taken: &taken,
                )
                var moves: [PhotoMove] = []
                var rows: [RemovedPhoto] = []
                for (member, ext) in zip(group.members, extensions) {
                    let original = originals[member]
                    let name = stem + (ext.isEmpty ? "" : "." + ext)
                    moves.append(PhotoMove(
                        id: copyIDs[member], from: group.folder + "/" + original.photo.name,
                        to: destination + "/" + name,
                    ))
                    var row = IndexedPhoto(original.photo)
                    row.id = copyIDs[member]
                    row.name = name
                    row.fileID = nil
                    row.stack = nil
                    row.stackTop = false
                    row.stackPosition = nil
                    rows.append(RemovedPhoto(
                        photo: row, folder: destination, keywords: original.keywords, copyOf: original.photo.id,
                    ))
                }
                return (moves, rows)
            }
            return planner.copySteps(copies)
        }
        return FileBatch(kind: .copy, title: title, steps: steps)
    }
}

extension FileOperations {
    /// The batch that undoes copy batch `batch`: the copies its steps made moved to the Trash with their files,
    /// wherever the index has them now, as `planTrash(photos:)` moves photos. Copies the index no longer has are
    /// left out, taken back already (by an Undo that was stopped, say), and so are those whose files aren't
    /// there any more (`gone`).
    func planUndo(copies batch: FileBatch, logged: FileJournal.Progress) async throws -> FileBatch {
        let made = batch.steps.indices.filter { logged.done.contains($0) && batch.steps[$0].kind == .copy }
            .flatMap { batch.steps[$0].removed.map(\.photo.id) }
        var trash = try await planTrash(photos: made)
        var gone: [String] = []
        trash.steps.removeAll { step in
            guard let photo = step.items.first(where: { $0.role == .photo }), photo.size == nil, !photo.isDirectory
            else { return false }
            gone.append(photo.source)
            return true
        }
        guard !trash.steps.isEmpty else {
            if gone.isEmpty {
                throw FileOperationError.nothingToUndo
            }
            throw FileOperationError.conflicts(gone.map { FileConflict(path: $0, reason: .gone) })
        }
        var undo = FileBatch(kind: .undo, title: "Undo " + batch.title, steps: trash.steps, undoes: batch.id)
        undo.gone = gone
        return undo
    }
}
