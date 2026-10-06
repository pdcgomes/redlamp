import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampLibrary

/// Photo files in a folder of their own and an index of them, for the duplicates' tests. The
/// library's own folder (`LibraryPaths`) is the index's, and the simulated volume `fileSystem`
/// keeps what it moves to the Trash in `trash`, a folder of the sandbox's, never the Mac's Trash.
struct DuplicateSandbox {
    let folder: TemporaryFolder
    let index: LibraryIndex
    let indexFolder: URL
    let fileSystem: SimulatedFileSystem

    var root: URL {
        folder.url
    }

    var trash: URL {
        indexFolder.appending(path: "Trash", directoryHint: .isDirectory)
    }

    static func make() async throws -> DuplicateSandbox {
        let indexFolder = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-duplicates-\(UUID().uuidString)", directoryHint: .isDirectory)
        let index = try await LibraryIndex.open(at: indexFolder.appending(path: "Index.sqlite"), readers: 2)
        let fileSystem = SimulatedFileSystem(profile: .ssd)
        fileSystem.useTrash(indexFolder.appending(path: "Trash", directoryHint: .isDirectory))
        return try DuplicateSandbox(
            folder: TemporaryFolder(), index: index, indexFolder: indexFolder, fileSystem: fileSystem,
        )
    }

    func remove() {
        index.closeAndWait()
        try? FileManager.default.removeItem(at: indexFolder)
    }

    func url(_ path: String) -> URL {
        root.appending(path: path)
    }

    /// The path of `path` below the root, as the index and the file operations have it.
    func path(_ path: String) -> String {
        LibraryIndexer.path(url(path))
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

    /// A `.redlamp` sidecar for the photo at `path`, holding `metadata`, and an edit when `edited`,
    /// where `store` keeps it.
    func sidecar(
        _ path: String, _ metadata: PhotoMetadata, edited: Bool = false, store: SidecarStore = SidecarStore(),
    ) throws {
        var recipe = EditRecipe()
        if edited {
            recipe[.exposure] = 0.35
        }
        try store.save(Sidecar(recipe: recipe, metadata: metadata), for: url(path))
    }

    /// The store the library keeps its sidecars in, beside the photos or on this Mac as each root says.
    func sidecars() async throws -> SidecarStore {
        try await SidecarStore(locator: LibrarySidecars(index: index).locator())
    }

    /// The library's file operations, on `fileSystem`.
    func operations() -> FileOperations {
        FileOperations(index: index, fileSystem: fileSystem)
    }

    /// Every file below the root and in the sidecars on this Mac, but hidden ones, by its path below
    /// the root (`mac/…` on this Mac), with its bytes; a sidecar package's files as
    /// `X.JPG.redlamp/edit.json`.
    func files() -> [String: Data] {
        var found: [String: Data] = [:]
        for (base, prefix) in [(root, ""), (LibraryPaths(root: indexFolder).sidecars, "mac/")] {
            for path in FileManager.default.subpaths(atPath: base.path) ?? [] {
                guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
                var isDirectory: ObjCBool = false
                let url = base.appending(path: path)
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue
                else { continue }
                found[prefix + path] = try? Data(contentsOf: url)
            }
        }
        return found
    }

    /// What the simulated volume's Trash holds, by name.
    func trashed() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [])
    }

    /// Each photo's ID by its path below the root, as the index has it.
    func rows() async throws -> [String: Int64] {
        let rootPath = LibraryIndexer.path(root)
        return try await index.read { reader in
            var rows: [String: Int64] = [:]
            let statement = try reader.database.prepare("""
            SELECT p.id, f.path, p.name FROM photos p JOIN folders f ON f.id = p.folder
            """)
            try statement.forEachRow { row in
                let path = (row.string(at: 1) ?? "") + "/" + (row.string(at: 2) ?? "")
                rows[String(path.dropFirst(rootPath.count + 1))] = row.int64(at: 0)
            }
            return rows
        }
    }

    /// Indexes the root, as the library does.
    func indexAll() async throws {
        let indexer = LibraryIndexer(index: index, configuration: .testing())
        let run = await IndexerRun.collect(indexer.index([root]))
        try #require(run.failures.isEmpty, "\(run.failures)")
    }

    func finder(
        _ fileSystem: any LibraryFileSystem = LocalFileSystem(), sidecars: SidecarStore = SidecarStore(),
    ) -> DuplicateFinder {
        DuplicateFinder(index: index, fileSystem: fileSystem, sidecars: sidecars)
    }

    /// The ID of the photo at `path` below the root.
    func id(_ path: String) async throws -> Int64 {
        let full = LibraryIndexer.path(root) + "/" + path
        return try #require(try await index.read { try $0.photo(path: full)?.id }, "\(path)")
    }
}

/// Another app's `.xmp`, with no rating, so it doesn't change which copy is proposed to keep.
let otherAppXMP = Data(FixtureWriter.xmp(.init(rating: 0, label: .red, keywords: ["copy"])).utf8)

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
