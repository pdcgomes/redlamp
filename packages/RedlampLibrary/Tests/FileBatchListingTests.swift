import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampLibrary

/// Change tracking listing a batch's folders in the middle of it (LIB-26): once the batch's files have moved and
/// before its index is written, the indexer lists the folder the photos left, the one they went to, or both. The
/// photos keep their rows (their IDs, edits, keywords and collections) through the move, its Undo and its Redo.
struct FileBatchListingTests {
    enum Listed: String, CaseIterable, Sendable {
        case source, destination, both
    }

    /// What the index has of a photo that a batch moves: its row's ID, edits, keywords and collections.
    struct Kept: Equatable {
        let id: Int64
        let edited: Bool
        let keywords: Set<String>
        let collections: Set<CollectionPath>
    }

    /// The photos in the root, A and C edited, with a keyword and in a collection, an empty folder beside them, and
    /// the indexer and the file operations through one file system, which pauses a batch after its last file.
    struct Library {
        let sandbox: HealthSandbox
        let files: PausingFileSystem
        let indexer: LibraryIndexer
        let operations: FileOperations

        var picked: URL {
            sandbox.url("Picked")
        }

        static func make() async throws -> Library {
            let sandbox = try await HealthSandbox.make(Dictionary(uniqueKeysWithValues: ["A", "B", "C", "D"]
                    .enumerated().map { ("\($1).JPG", HealthImages.data(.jpeg, seed: UInt64($0 + 1))) }))
            try FileManager.default.createDirectory(at: sandbox.url("Picked"), withIntermediateDirectories: true)
            var recipe = EditRecipe()
            recipe[.exposure] = 1
            for name in ["A.JPG", "C.JPG"] {
                try SidecarStore().save(
                    Sidecar(
                        recipe: recipe,
                        metadata: PhotoMetadata(keywords: ["Places/Lisbon"], collections: ["Trips/Lisbon"]),
                        modified: HealthSandbox.written,
                    ),
                    for: sandbox.url(name),
                )
            }
            let files = PausingFileSystem(sandbox.volume)
            let indexer = LibraryIndexer(index: sandbox.index, fileSystem: files, configuration: .testing())
            let indexed = await IndexerRun.collect(indexer.index([sandbox.root]))
            try #require(indexed.failures.isEmpty, "\(indexed.failures)")
            let operations = FileOperations(index: sandbox.index, paths: sandbox.paths, fileSystem: files)
            return Library(sandbox: sandbox, files: files, indexer: indexer, operations: operations)
        }

        /// The rows of `names` in `folder`, with what goes with them, by name.
        func kept(_ names: [String], in folder: URL) async throws -> [String: Kept] {
            let path = LibraryIndexer.path(folder)
            return try await sandbox.index.read { reader in
                guard let folder = try reader.folder(path: path) else { return [:] }
                var kept: [String: Kept] = [:]
                for name in names {
                    guard let row = try reader.photo(folder: folder.id, name: name) else { continue }
                    kept[name] = try Kept(
                        id: row.id, edited: row.edited, keywords: Set(reader.keywords(forPhoto: row.id)),
                        collections: Set(reader.collections(ofPhoto: row.id)),
                    )
                }
                return kept
            }
        }

        /// Runs `batch`, which moves photos from `source` to `destination`, and once its last file has moved, has
        /// the indexer list what `listed` names, as change tracking does for a folder's events; then lists both, as
        /// change tracking does for the batch's own.
        func run(_ batch: FileBatch, listing listed: Listed, from source: URL, to destination: URL) async throws {
            let last = try #require(batch.steps.last?.items.last?.source)
            let pause = files.pause(after: last)
            let running = Task { try await operations.run(batch) }
            let deadline = ContinuousClock.now + .seconds(30)
            while !pause.reached.fired, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(pause.reached.fired, "the batch's files moved")
            let folders = switch listed {
            case .source: [source]
            case .destination: [destination]
            case .both: [source, destination]
            }
            let listedAll = Signal()
            let listing = Task {
                let run = await IndexerRun.collect(indexer.update(folders.map { FolderChange($0) }))
                listedAll.fire()
                return run
            }
            // The listing runs to its end while the batch waits, unless it waits for the batch's folders itself.
            while !listedAll.fired, sandbox.index.folderHolds.waitingListings == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            pause.release()
            #expect(try await running.value.isFinished)
            let meanwhile = await listing.value
            #expect(meanwhile.failures.isEmpty, "\(meanwhile.failures)")
            let after = await IndexerRun.collect(indexer.update([source, destination].map { FolderChange($0) }))
            #expect(after.failures.isEmpty, "\(after.failures)")
        }
    }

    @Test(arguments: Listed.allCases)
    func `photos a batch moves keep their rows, edits, keywords and collections, whatever is listed meanwhile`(
        listed: Listed,
    ) async throws {
        let library = try await Library.make()
        defer { library.sandbox.remove() }
        let (root, picked) = (library.sandbox.root, library.picked)
        let moving = ["A.JPG", "C.JPG"]
        let before = try await library.kept(moving, in: root)
        try #require(before.count == 2, "\(before)")
        try #require(before.values.allSatisfy { $0.edited && !$0.keywords.isEmpty && !$0.collections.isEmpty })
        let ids = moving.compactMap { before[$0]?.id }

        let move = try await library.operations.planMove(photos: ids, to: picked)
        try await library.run(move, listing: listed, from: root, to: picked)
        var after = try await library.kept(moving, in: picked)
        #expect(after == before, "after the move: \(after), before \(before)")

        try await library.run(library.operations.planUndo(move.id), listing: listed, from: picked, to: root)
        after = try await library.kept(moving, in: root)
        #expect(after == before, "after its Undo: \(after)")

        // Redo is planned from the photos' IDs, as the app plans it from its step.
        let redo = try await library.operations.planMove(photos: ids, to: picked)
        try #require(redo.photoCount == ids.count, "Redo moves every photo the move did")
        try await library.run(redo, listing: listed, from: root, to: picked)
        after = try await library.kept(moving, in: picked)
        #expect(after == before, "after its Redo: \(after)")
    }

    @Test func `the indexer's writes that come after a batch leave its rows where the batch put them`() async throws {
        let library = try await Library.make()
        defer { library.sandbox.remove() }
        let index = library.sandbox.index
        let rootPath = LibraryIndexer.path(library.sandbox.root)
        let found = try await index.read { reader in
            try (reader.folder(path: rootPath), reader.photo(path: rootPath + "/A.JPG"))
        }
        let (rootFolder, row) = try (#require(found.0), #require(found.1))
        let before = try await library.kept(["A.JPG"], in: library.sandbox.root)
        let moved = try await library.operations.run(library.operations.planMove(photos: [row.id], to: library.picked))
        try #require(moved.isFinished)

        // What a run read of the photo where it was, and of its vanishing from there, written once the batch is done.
        var read = row
        read.rating = 5
        let late: [LibraryIndexer.Batcher.Item] = [
            .photo(LibraryIndexer.PendingPhoto(folder: rootPath, record: read, isNew: false)),
            .delete([(row.id, rootFolder.id)]),
        ]
        let writing = index.photoWrites
        let outcome = try await index.write { try LibraryIndexer.Batcher.apply(late, $0, writing: writing) }
        #expect(outcome.inserted.isEmpty && outcome.updated.isEmpty && outcome.removed.isEmpty, "\(outcome)")
        let rows = try await library.sandbox.rows()
        #expect(rows["A.JPG"] == nil, "no row where the photo was")
        #expect(try await library.kept(["A.JPG"], in: library.picked) == before)
        #expect(rows["Picked/A.JPG"]?.rating == row.rating, "the photo's row as the batch left it")
    }
}

/// Another file system that holds the thread moving one file, once it has moved, or reading one past its first byte,
/// until the pause is released: a batch stopped between its files and its index, or the indexer between a photo's row
/// and its end.
final class PausingFileSystem: LibraryFileSystem {
    /// A thread held until `release`: `hold` blocks the thread that calls it.
    final class Pause: Sendable {
        let path: String
        let reached = Signal()
        private let released = DispatchSemaphore(value: 0)

        init(_ path: String) {
            self.path = path
        }

        func release() {
            released.signal()
        }

        func hold() {
            reached.fire()
            released.wait()
        }
    }

    let base: any LibraryFileSystem
    private let pending = Mutex<Pause?>(nil)
    private let pendingRead = Mutex<Pause?>(nil)

    init(_ base: any LibraryFileSystem) {
        self.base = base
    }

    /// Holds the move of the file at `path`, once it's done, until the pause returned is released.
    func pause(after path: String) -> Pause {
        let pause = Pause(path)
        pending.withLock { $0 = pause }
        return pause
    }

    /// Holds the first read of the file at `path` that starts past its first byte, before it reads, until the pause
    /// returned is released.
    func pause(reading path: String) -> Pause {
        let pause = Pause(path)
        pendingRead.withLock { $0 = pause }
        return pause
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try base.moveItem(at: source, to: destination)
        let pause = pending.withLock { pending -> Pause? in
            guard let pause = pending, pause.path == LibraryIndexer.path(source) else { return nil }
            pending = nil
            return pause
        }
        pause?.hold()
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        try base.contentsOfDirectory(at: url)
    }

    func attributes(of url: URL) throws -> FileEntry {
        try base.attributes(of: url)
    }

    func read(_ url: URL, range: Range<Int>) throws -> Data {
        let pause = range.lowerBound == 0 ? nil : pendingRead.withLock { pending -> Pause? in
            guard let pause = pending, pause.path == LibraryIndexer.path(url) else { return nil }
            pending = nil
            return pause
        }
        pause?.hold()
        return try base.read(url, range: range)
    }

    func volume(of url: URL) throws -> VolumeInfo {
        try base.volume(of: url)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try base.copyItem(at: source, to: destination)
    }

    func createDirectory(at url: URL, withIntermediateDirectories intermediates: Bool) throws {
        try base.createDirectory(at: url, withIntermediateDirectories: intermediates)
    }

    func removeItem(at url: URL) throws {
        try base.removeItem(at: url)
    }

    func trashItem(at url: URL) throws -> URL {
        try base.trashItem(at: url)
    }

    func trashDirectory(for url: URL) throws -> URL {
        try base.trashDirectory(for: url)
    }
}
