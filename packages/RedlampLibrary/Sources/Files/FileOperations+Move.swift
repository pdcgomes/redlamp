import Foundation
import RedlampDocument

public extension FileOperations {
    /// The batch that moves photos `ids`, each with its pair and its files, into `folder`, keeping
    /// their names: a rename on the same volume, and across volumes a copy, checked, then the
    /// original removed. `folder` must be in the library.
    func planMove(photos ids: [Int64], to folder: URL) async throws -> FileBatch {
        let destination = try await indexedPath(LibraryIndexer.path(folder))
        guard try await index.read({ try $0.root(containing: destination) }) != nil else {
            throw FileOperationError.notInLibrary(destination)
        }
        let ids = try await withPairs(ids)
        let photos = try await index.read { try $0.photosWithPaths(ids) }
        let moves = photos.compactMap { photo, folder -> PhotoMove? in
            guard folder != destination else { return nil }
            return PhotoMove(
                id: photo.id, from: folder + "/" + photo.name,
                to: destination + "/" + photo.name.precomposedStringWithCanonicalMapping,
            )
        }
        let count = Set(moves.map(\.id)).count
        return try await FileBatch(
            kind: .move, title: "Move \(count) photo\(count == 1 ? "" : "s") to \(folder.lastPathComponent)",
            steps: moveSteps(moves),
        )
    }

    /// The batch that moves the folder at `source`, with everything in it, to `destination`, its new
    /// path: in another folder, under another name, or both. On one volume that's a rename, and the
    /// folders' rows keep their IDs; across volumes each file is copied, checked and only then removed,
    /// a step a file, and the folders are made and removed around them.
    func planMove(folder source: URL, to destination: URL) async throws -> FileBatch {
        let from = try await indexedPath(LibraryIndexer.path(source))
        let to = try await indexedPath(LibraryIndexer.path(destination))
        guard NamingJob.fold(to) != NamingJob.fold(from),
              !NamingJob.fold(to).hasPrefix(NamingJob.fold(from) + "/") else {
            throw FileOperationError.insideItself(from)
        }
        let (folder, isRoot, inLibrary) = try await index.read { reader in
            try (
                reader.folder(path: from), reader.roots().contains { $0.path == from },
                reader.root(containing: FilePlanner.split(to).folder) != nil,
            )
        }
        guard !isRoot else { throw FileOperationError.isRoot(from) }
        guard inLibrary else { throw FileOperationError.notInLibrary(to) }
        let locator = try await locator()
        let fileSystem = fileSystem
        let index = index
        let parentName = destination.deletingLastPathComponent().lastPathComponent
        let title = "Move folder \(source.lastPathComponent) to \(parentName)"
        let planner = FilePlanner(fileSystem: fileSystem, locator: locator)
        let sameVolume = try await LibraryIndex.offCaller {
            planner.volume(of: from) == planner.volume(of: FilePlanner.split(to).folder)
        }
        guard sameVolume else {
            let tree = try await LibraryIndex.offCaller { try Self.tree(below: from, fileSystem: fileSystem) }
            let ids = try await index.read { reader in
                try tree.files.reduce(into: [String: Int64]()) { ids, path in
                    if let photo = try reader.photo(path: path) {
                        ids[path] = photo.id
                    }
                }
            }
            let steps = try await LibraryIndex.offCaller {
                Self.acrossVolumes(tree, from: from, to: to, ids: ids, planner: planner)
            }
            return FileBatch(kind: .move, title: title, steps: steps)
        }
        let step = try await LibraryIndex.offCaller { () -> FileStep in
            guard let entry = planner.entry(from), entry.isDirectory else {
                throw FileOperationError.conflicts([FileConflict(path: from, reason: .gone)])
            }
            var items = [FileItem(
                role: .folder, source: from, destination: to, fileID: entry.fileIdentifier, isDirectory: true,
            )]
            let mac = Self.folderOnThisMac(from, locator: locator)
            let target = Self.folderOnThisMac(to, locator: locator)
            if let mac, let target, let sidecars = try? fileSystem.attributes(of: URL(fileURLWithPath: mac)),
               sidecars.isDirectory {
                items.append(FileItem(
                    role: .sidecarOnThisMac, source: mac, destination: target, fileID: sidecars.fileIdentifier,
                    isDirectory: true,
                ))
            }
            return FileStep(
                kind: .move, items: items, folders: folder.map { [FolderMove(id: $0.id, from: from, to: to)] } ?? [],
            )
        }
        return FileBatch(kind: .move, title: title, steps: [step])
    }

    /// The batch that makes a new, empty folder at `url`, in a folder of the library.
    func planNewFolder(_ url: URL) async throws -> FileBatch {
        let path = try await indexedPath(LibraryIndexer.path(url))
        guard try await index.read({ try $0.root(containing: FilePlanner.split(path).folder) }) != nil else {
            throw FileOperationError.notInLibrary(path)
        }
        return FileBatch(
            kind: .newFolder, title: "New folder \(url.lastPathComponent)",
            steps: [FileStep(kind: .createFolder, folder: path)],
        )
    }

    /// `path` as the index has it: the folder's own path, or its folder's and its name in Unicode's
    /// composed form, when the index has either. A file URL's path is decomposed, a listing's isn't.
    internal func indexedPath(_ path: String) async throws -> String {
        try await index.read { reader in
            if let folder = try reader.folder(anyFormOf: path) {
                return folder.path
            }
            let (parent, name) = FilePlanner.split(path)
            guard let folder = try reader.folder(anyFormOf: parent) else { return path }
            return folder.path + "/" + name.precomposedStringWithCanonicalMapping
        }
    }

    /// Where a folder's sidecars are on this Mac, if its root has a place for them there.
    internal static func folderOnThisMac(_ folder: String, locator: SidecarLocator) -> String? {
        locator.onThisMac(URL(fileURLWithPath: folder + "/_"))?.deletingLastPathComponent().path
    }

    /// A folder's folders, parents first, and its files, as its volume lists them.
    internal static func tree(below folder: String, fileSystem: any LibraryFileSystem) throws
        -> (folders: [String], files: [String], entries: [String: FileEntry]) {
        var folders: [String] = []
        var files: [String] = []
        var entries: [String: FileEntry] = [:]
        var waiting = [folder]
        while !waiting.isEmpty {
            let current = waiting.removeFirst()
            folders.append(current)
            for entry in try fileSystem.contentsOfDirectory(at: URL(fileURLWithPath: current, isDirectory: true))
                .sorted(by: { $0.name < $1.name }) {
                let path = current + "/" + entry.name
                entries[path] = entry
                if FolderWalk.isFolder(entry) {
                    waiting.append(path)
                } else {
                    files.append(path)
                }
            }
        }
        return (folders, files, entries)
    }

    /// A folder moved to another volume: its folders made there, parents first; its photos moved with
    /// their files, and its other files, each copied, checked and then removed; then its folders
    /// removed, children first.
    internal static func acrossVolumes(
        _ tree: (folders: [String], files: [String], entries: [String: FileEntry]), from: String, to: String,
        ids: [String: Int64], planner: FilePlanner,
    ) -> [FileStep] {
        func moved(_ path: String) -> String {
            to + path.dropFirst(from.count)
        }
        var steps = tree.folders.map { FileStep(kind: .createFolder, folder: moved($0)) }
        let photos = tree.files.filter { path in tree.entries[path].map(FolderWalk.isPhoto) ?? false }
        let moveSteps = planner.moveSteps(photos.map { PhotoMove(id: ids[$0] ?? 0, from: $0, to: moved($0)) })
        steps += moveSteps.map { step in
            var step = step
            step.photos.removeAll { $0.id == 0 }
            return step
        }
        let taken = Set(moveSteps.flatMap { $0.items.map(\.source) })
        for path in tree.files where !taken.contains(path) {
            guard let entry = tree.entries[path] else { continue }
            steps.append(FileStep(kind: .move, items: [FileItem(
                role: .file, source: path, destination: moved(path), copies: true, fileID: entry.fileIdentifier,
                size: entry.isDirectory ? nil : entry.size, modified: entry.isDirectory ? nil : entry.modified,
                isDirectory: entry.isDirectory,
            )]))
        }
        steps += tree.folders.reversed().map { FileStep(kind: .removeFolder, folder: $0) }
        return steps
    }
}
