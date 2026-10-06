import Foundation
import RedlampDocument

/// A photo to move to the Trash as a plan made elsewhere names it (exact duplicates' removal, say):
/// its row in the index, and its files. The sidecars and other apps' sidecars named after them go
/// with them.
public struct PhotoFiles: Sendable, Hashable {
    public var id: Int64
    /// The photo's files; none for the file the index has for it.
    public var files: [URL]

    public init(id: Int64, files: [URL] = []) {
        self.id = id
        self.files = files
    }
}

public extension FileOperations {
    /// The batch that moves photos `ids` to the Trash, each with its `.redlamp` sidecars and the other
    /// apps' sidecars named after it, and takes them out of the index. Undo puts them back while
    /// they're still in the Trash, rows, keywords and collections as they were. Photos the index no
    /// longer has are left out, in `notInIndex`.
    func planTrash(photos ids: [Int64]) async throws -> FileBatch {
        try await planTrash(ids.map { PhotoFiles(id: $0) })
    }

    /// The batch that moves each photo's files to the Trash, as `planTrash(photos:)` does.
    func planTrash(_ photos: [PhotoFiles]) async throws -> FileBatch {
        let (found, notInIndex) = try await index.read { reader in
            var found: [(PhotoFiles, RemovedPhoto)] = []
            var notInIndex: [Int64] = []
            for request in photos {
                guard let photo = try reader.photo(id: request.id),
                      let folder = try reader.folder(id: photo.folder)?.path
                else {
                    notInIndex.append(request.id)
                    continue
                }
                try found.append((request, RemovedPhoto(
                    photo: IndexedPhoto(photo), folder: folder, keywords: reader.keywords(forPhoto: photo.id),
                    collections: reader.collectionPlaces(ofPhoto: photo.id),
                )))
            }
            return (found, notInIndex)
        }
        let locator = try await locator()
        let fileSystem = fileSystem
        let steps = try await LibraryIndex.offCaller {
            let planner = FilePlanner(fileSystem: fileSystem, locator: locator)
            var trashedNames: [String: Set<String>] = [:]
            for (request, removed) in found {
                for file in Self.files(of: request, removed) {
                    let (folder, name) = FilePlanner.split(file)
                    trashedNames[folder, default: []].insert(NamingJob.fold(name))
                }
            }
            var taken = Set<String>()
            return found.map { request, removed in
                var items: [FileItem] = []
                for file in Self.files(of: request, removed) where taken.insert(file).inserted {
                    let entry = planner.entry(file)
                    let isPhoto = entry.map(FolderWalk.isPhoto) ?? true
                    items.append(Self.item(isPhoto ? .photo : .otherApp, file, entry))
                    guard isPhoto else { continue }
                    for companion in Self.companions(of: file, planner: planner, trashed: trashedNames)
                        where taken.insert(companion.source).inserted {
                        items.append(companion)
                    }
                }
                return FileStep(kind: .trash, items: items, removed: [removed])
            }
        }
        let count = found.count
        var batch = FileBatch(
            kind: .trash, title: "Move \(count) photo\(count == 1 ? "" : "s") to the Trash", steps: steps,
        )
        batch.notInIndex = notInIndex
        return batch
    }

    /// The batch that moves the folder at `url`, with everything in it, to the Trash, and takes its
    /// folders and photos out of the index. Undo puts it back while it's still in the Trash.
    func planTrash(folder url: URL) async throws -> FileBatch {
        let path = try await indexedPath(LibraryIndexer.path(url))
        let (isRoot, folders, photos) = try await index.read { reader -> (Bool, [RemovedFolder], [RemovedPhoto]) in
            let isRoot = try reader.roots().contains { $0.path == path }
            guard let folder = try reader.folder(path: path) else { return (isRoot, [], []) }
            let folders = try reader.folders(inSubtreeOf: folder.id)
            let paths = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.path) })
            let photos = try reader.photos(inSubtreeOf: folder.id).map { photo in
                try RemovedPhoto(
                    photo: IndexedPhoto(photo), folder: paths[photo.folder] ?? path,
                    keywords: reader.keywords(forPhoto: photo.id),
                    collections: reader.collectionPlaces(ofPhoto: photo.id),
                )
            }
            return (isRoot, folders.map(RemovedFolder.init), photos)
        }
        guard !isRoot else { throw FileOperationError.isRoot(path) }
        let locator = try await locator()
        let fileSystem = fileSystem
        let items = try await LibraryIndex.offCaller {
            var items = [Self.item(.folder, path, try? fileSystem.attributes(of: url))]
            if let mac = Self.folderOnThisMac(path, locator: locator),
               let sidecars = try? fileSystem.attributes(of: URL(fileURLWithPath: mac)), sidecars.isDirectory {
                items.append(Self.item(.sidecarOnThisMac, mac, sidecars))
            }
            return items
        }
        return FileBatch(
            kind: .trash, title: "Move folder \(url.lastPathComponent) to the Trash",
            steps: [FileStep(kind: .trash, items: items, removed: photos, removedFolders: folders)],
        )
    }

    /// The files a request names, or the photo's own as the index has it.
    private static func files(of request: PhotoFiles, _ removed: RemovedPhoto) -> [String] {
        request.files.isEmpty ? [removed.folder + "/" + removed.photo.name] : request.files.map(LibraryIndexer.path)
    }

    private static func item(_ role: FileItem.Role, _ path: String, _ entry: FileEntry?) -> FileItem {
        FileItem(
            role: role, source: path, destination: nil, fileID: entry?.fileIdentifier,
            size: entry?.isDirectory == false ? entry?.size : nil,
            modified: entry?.isDirectory == false ? entry?.modified : nil, isDirectory: entry?.isDirectory ?? false,
        )
    }

    /// A photo's sidecars, beside it and on this Mac, and other apps' named after it; those named
    /// after its name without the extension when every photo of that name goes to the Trash too.
    private static func companions(of photo: String, planner: FilePlanner, trashed: [String: Set<String>])
        -> [FileItem] {
        let (folder, name) = FilePlanner.split(photo)
        let listing = planner.listing(folder)
        var items: [FileItem] = []
        if let sidecar = listing.entries[NamingJob.fold(name + ".redlamp")] {
            items.append(item(.sidecar, folder + "/" + sidecar.name, sidecar))
        }
        if let mac = planner.locator.onThisMac(URL(fileURLWithPath: photo)), let sidecar = planner.entry(mac.path) {
            items.append(item(.sidecarOnThisMac, mac.path, sidecar))
        }
        for ext in FilePlanner.otherAppExtensions {
            if let other = listing.entries[NamingJob.fold(name + "." + ext)] {
                items.append(item(.otherApp, folder + "/" + other.name, other))
            }
        }
        let stem = NamingJob.split(name).base
        let gone = trashed[folder] ?? []
        if (listing.photosByStem[NamingJob.fold(stem)] ?? []).allSatisfy({ gone.contains(NamingJob.fold($0)) }) {
            for ext in FilePlanner.otherAppExtensions {
                if let other = listing.entries[NamingJob.fold(stem + "." + ext)] {
                    items.append(item(.otherApp, folder + "/" + other.name, other))
                }
            }
        }
        return items
    }
}
