import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampLibrary

/// Photo files in a folder of their own and an index of them, for the duplicates' tests.
struct DuplicateSandbox {
    let folder: TemporaryFolder
    let index: LibraryIndex
    let indexFolder: URL

    var root: URL {
        folder.url
    }

    static func make() async throws -> DuplicateSandbox {
        let indexFolder = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-duplicates-\(UUID().uuidString)", directoryHint: .isDirectory)
        let index = try await LibraryIndex.open(at: indexFolder.appending(path: "Index.sqlite"), readers: 2)
        return try DuplicateSandbox(folder: TemporaryFolder(), index: index, indexFolder: indexFolder)
    }

    func remove() {
        index.closeAndWait()
        try? FileManager.default.removeItem(at: indexFolder)
    }

    func url(_ path: String) -> URL {
        root.appending(path: path)
    }

    /// Writes `data` at `path` below the root, modified `modified` seconds after 2020 began.
    @discardableResult
    func write(_ path: String, _ data: Data, modified: TimeInterval = 0) throws -> URL {
        let file = url(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        try setModified(path, modified)
        return file
    }

    func setModified(_ path: String, _ modified: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_577_836_800 + modified)], ofItemAtPath: url(path).path,
        )
    }

    /// A `.redlamp` sidecar for the photo at `path`, holding `metadata`, and an edit when `edited`.
    func sidecar(_ path: String, _ metadata: PhotoMetadata, edited: Bool = false) throws {
        var recipe = EditRecipe()
        if edited {
            recipe[.exposure] = 0.35
        }
        try SidecarStore().save(Sidecar(recipe: recipe, metadata: metadata), for: url(path))
    }

    /// Indexes the root, as the library does.
    func indexAll() async throws {
        let indexer = LibraryIndexer(index: index, configuration: .testing())
        let run = await IndexerRun.collect(indexer.index([root]))
        try #require(run.failures.isEmpty, "\(run.failures)")
    }

    func finder(_ fileSystem: any LibraryFileSystem = LocalFileSystem()) -> DuplicateFinder {
        DuplicateFinder(index: index, fileSystem: fileSystem)
    }

    /// The ID of the photo at `path` below the root.
    func id(_ path: String) async throws -> Int64 {
        let full = LibraryIndexer.path(root) + "/" + path
        return try #require(try await index.read { try $0.photo(path: full)?.id }, "\(path)")
    }
}

/// `count` bytes from `seed`, the same each time.
func duplicateBytes(_ count: Int, seed: UInt64) -> Data {
    var random = SeededRandom(seed: seed)
    return Data((0 ..< count).map { _ in UInt8(truncatingIfNeeded: random.next()) })
}

/// Reads of the file at a path ending in `held` wait, once it's reached, until it's released.
final class HoldingFileSystem: LibraryFileSystem {
    let base: any LibraryFileSystem
    let held: String
    private let released = DispatchSemaphore(value: 0)
    private let state = Mutex(false)

    init(_ base: any LibraryFileSystem = LocalFileSystem(), holding held: String) {
        self.base = base
        self.held = held
    }

    var reached: Bool {
        state.withLock { $0 }
    }

    func release() {
        released.signal()
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        try base.contentsOfDirectory(at: url)
    }

    func attributes(of url: URL) throws -> FileEntry {
        try base.attributes(of: url)
    }

    func read(_ url: URL, range: Range<Int>) throws -> Data {
        if url.path.hasSuffix(held), state.withLock({ reached in
            defer { reached = true }
            return !reached
        }) {
            released.wait()
        }
        return try base.read(url, range: range)
    }

    func volume(of url: URL) throws -> VolumeInfo {
        try base.volume(of: url)
    }
}
