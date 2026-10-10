import Foundation
import RedlampDocument

/// A missing photo (DEC-59) and the file it's found as, in one of the library's folders: what a relink takes.
public struct PhotoRelink: Sendable, Hashable {
    public var id: Int64
    public var path: String

    public init(id: Int64, path: String) {
        self.id = id
        self.path = path
    }
}

public extension FileOperations {
    /// The batch that takes missing photos `ids` out of the library (DEC-59) with nothing moved, their rows as they are
    /// kept in the journal for Undo; those that aren't missing are left out.
    func planRemoval(ofMissing ids: [Int64]) async throws -> FileBatch {
        let removed = try await index.read { reader in
            try reader.photosWithPaths(ids).filter { $0.photo.state.contains(.missing) }.map { photo, folder in
                try Self.removed(photo, folder: folder, reader)
            }
        }
        let steps = stride(from: 0, to: removed.count, by: Self.removalStep).map { start in
            FileStep(
                kind: .removeFromLibrary,
                removed: Array(removed[start ..< min(start + Self.removalStep, removed.count)]),
            )
        }
        let count = removed.count
        return FileBatch(kind: .remove, title: "Remove \(count) missing photo\(count == 1 ? "" : "s")", steps: steps)
    }

    /// The batch that relinks each missing photo of `relinks` to the file it's found as (DEC-59): its row moved there,
    /// keeping its ID, everything decided about it and its collections, and read again from the file; the row the file
    /// had, indexed as a new photo meanwhile, taken out. When the file has no `.redlamp` sidecar, the one the photo
    /// left
    /// behind comes beside it, or, with none left behind, one is written with what the photo's row holds. Photos that
    /// aren't missing, files gone or outside the library's folders, files another missing photo had, and a second photo
    /// for one file are left out.
    func planRelink(_ relinks: [PhotoRelink]) async throws -> FileBatch {
        let found = try await index.read { reader in
            var found: [(relink: PhotoRelink, photo: RemovedPhoto, holder: RemovedPhoto?)] = []
            var files = Set<String>()
            for relink in relinks {
                let path = relink.path
                guard try reader.root(containing: path) != nil, files.insert(NamingJob.fold(path)).inserted,
                      let (photo, folder) = try reader.photosWithPaths([relink.id]).first,
                      photo.state.contains(.missing)
                else { continue }
                var holder: RemovedPhoto?
                if let held = try reader.photo(path: path), held.id != photo.id {
                    guard !held.state.contains(.missing) else { continue }
                    holder = try Self.removed(held, folder: FilePlanner.split(path).folder, reader)
                }
                try found.append((relink, Self.removed(photo, folder: folder, reader), holder))
            }
            return found
        }
        let locator = try await locator()
        let fileSystem = fileSystem
        let steps = try await LibraryIndex.offCaller {
            let planner = FilePlanner(fileSystem: fileSystem, locator: locator)
            var holders: [RemovedPhoto] = []
            var relinked: [FileStep] = []
            for (relink, photo, holder) in found {
                guard let file = planner.entry(relink.path), !file.isDirectory else { continue }
                let was = photo.folder + "/" + photo.photo.name
                var step = FileStep(
                    kind: .relink, items: [Self.item(.photo, relink.path, to: nil, file)],
                    photos: [PhotoMove(id: photo.photo.id, from: was, to: relink.path)], removed: [photo],
                )
                let (at, from) = (URL(fileURLWithPath: relink.path), URL(fileURLWithPath: was))
                let beside = SidecarLocator.besidePhoto(at).path
                let onThisMac = locator.onThisMac(at)?.path
                if planner.entry(beside) == nil, onThisMac.flatMap(planner.entry) == nil {
                    let leftBeside = SidecarLocator.besidePhoto(from).path
                    if let left = planner.entry(leftBeside) {
                        step.items.append(Self.item(.sidecar, leftBeside, to: beside, left))
                    } else if let leftOnThisMac = locator.onThisMac(from)?.path, let onThisMac,
                              let left = planner.entry(leftOnThisMac) {
                        step.items.append(Self.item(.sidecarOnThisMac, leftOnThisMac, to: onThisMac, left))
                    } else {
                        step.writesDecisions = photo.photo.sidecarModified != nil
                    }
                }
                holders += holder.map { [$0] } ?? []
                relinked.append(step)
            }
            return (holders.isEmpty ? [] : [FileStep(kind: .removeFromLibrary, removed: holders)]) + relinked
        }
        let count = steps.count { $0.kind == .relink }
        return FileBatch(kind: .relink, title: "Relink \(count) missing photo\(count == 1 ? "" : "s")", steps: steps)
    }

    /// Missing photos a removal takes out a step at a time.
    internal static let removalStep = 500

    private static func removed(_ photo: PhotoRecord, folder: String, _ reader: some IndexQueries) throws
        -> RemovedPhoto {
        try RemovedPhoto(
            photo: IndexedPhoto(photo), folder: folder, keywords: reader.keywords(forPhoto: photo.id),
            collections: reader.collectionPlaces(ofPhoto: photo.id),
        )
    }

    private static func item(_ role: FileItem.Role, _ path: String, to destination: String?, _ entry: FileEntry)
        -> FileItem {
        FileItem(
            role: role, source: path, destination: destination, fileID: entry.fileIdentifier,
            size: entry.isDirectory ? nil : entry.size, modified: entry.isDirectory ? nil : entry.modified,
            isDirectory: entry.isDirectory,
        )
    }
}
