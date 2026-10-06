import Foundation
import RedlampDocument
import Synchronization
import Testing
@testable import RedlampLibrary

/// Cards in a folder of their own, each mounted as a volume of its own on a simulated card reader,
/// with a library (index, store, indexer) and a destination and a backup to import into. On the raws'
/// volume, a card's raws are clones of the CC0 raws.
final class ImportSandbox: @unchecked Sendable {
    let folder: TemporaryFolder
    let reads: ByteCountingFileSystem
    let fileSystem: SimulatedFileSystem
    let paths: LibraryPaths
    let index: LibraryIndex
    let store: PhotoStore
    let library: ImportLibrary

    var destination: URL {
        folder.url.appending(path: "Pictures", directoryHint: .isDirectory)
    }

    var backup: URL {
        folder.url.appending(path: "Backup", directoryHint: .isDirectory)
    }

    private init(folder: TemporaryFolder, profile: VolumeProfile) async throws {
        self.folder = folder
        reads = ByteCountingFileSystem()
        fileSystem = SimulatedFileSystem(base: reads, profile: profile)
        paths = LibraryPaths(root: folder.url.appending(path: "Library", directoryHint: .isDirectory))
        index = try await LibraryIndex.open(at: paths.index, readers: 2)
        store = PhotoStore(root: paths.store)
        library = ImportLibrary(
            paths: paths, index: index, store: store,
            indexer: LibraryIndexer(
                index: index, configuration: .testing(), thumbnails: StoreThumbnailMaker(store: store).thumbnails,
            ),
        )
    }

    static func make(onRawVolume: Bool = false, profile: VolumeProfile = .ssd) async throws -> ImportSandbox {
        let folder = try onRawVolume ? TemporaryFolder(on: FixtureTests.rawFolder) : TemporaryFolder()
        return try await ImportSandbox(folder: folder, profile: profile)
    }

    /// A card named `name` holding `shots` below `DCIM`, on a volume of its own.
    func card(_ name: String, _ shots: [SimulatedCard.Shot]) throws -> ImportSource {
        let root = folder.url.appending(path: "Cards/" + name, directoryHint: .isDirectory)
        try SimulatedCard.write(shots, to: root)
        fileSystem.mount(root, uuid: "CARD-" + name, name: name)
        return try ImportSource.at(root, fileSystem: fileSystem, medium: .card(at: root))
    }

    func session(_ sources: [ImportSource], previews: Bool = true) -> ImportSession {
        ImportSession(sources: sources, library: library, fileSystem: fileSystem, makesPreviews: previews)
    }

    func settings(
        folders: String = "{date:yyyy}/{date:yyyy-MM-dd}", names: String = "{name}", backup: Bool = true,
        rawOnly: Bool = false, metadata: ImportMetadata = ImportMetadata(),
    ) throws -> ImportSettings {
        try ImportSettings(
            destination: destination, backup: backup ? self.backup : nil, folders: NamingTemplate(parsing: folders),
            names: NamingTemplate(parsing: names), rawOnly: rawOnly, metadata: metadata,
        )
    }

    /// Every file below `root` but hidden ones, by its path below it, with its bytes; a package's files
    /// as `IMG.JPG.redlamp/edit.json`.
    static func files(in root: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        for path in FileManager.default.subpaths(atPath: root.path) ?? [] {
            guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            var isDirectory: ObjCBool = false
            let url = root.appending(path: path)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
            else { continue }
            found[path] = try? Data(contentsOf: url)
        }
        return found
    }

    /// What's hidden below `root`: what an interrupted copy would leave.
    static func leftovers(in root: URL) -> [String] {
        (FileManager.default.subpaths(atPath: root.path) ?? []).filter { path in
            path.split(separator: "/").contains { $0.hasPrefix(".") }
        }
    }

    /// Each photo's path in the index, by its path below `root`.
    func rows(below root: URL) async throws -> [String: PhotoRecord] {
        let prefix = LibraryIndexer.path(root) + "/"
        return try await index.read { reader in
            var rows: [String: PhotoRecord] = [:]
            let statement = try reader.database.prepare("""
            SELECT f.path, p.id FROM photos p JOIN folders f ON f.id = p.folder
            """)
            var ids: [(String, Int64)] = []
            try statement.forEachRow { row in ids.append((row.string(at: 0) ?? "", row.int64(at: 1))) }
            for (folder, id) in ids {
                guard let photo = try reader.photo(id: id) else { continue }
                let path = folder + "/" + photo.name
                if path.hasPrefix(prefix) {
                    rows[String(path.dropFirst(prefix.count))] = photo
                }
            }
            return rows
        }
    }

    func remove() {
        store.close()
        index.closeAndWait()
    }
}

/// 5 October 2026 at 09:00 by the camera's clock, and `seconds` after.
func cameraTime(_ seconds: Double = 0) -> Date {
    Date(timeIntervalSince1970: 1_791_190_800 + seconds)
}

/// The Mac's file system, counting the bytes read from each file.
final class ByteCountingFileSystem: LibraryFileSystem {
    let base = LocalFileSystem()
    private let counts = Mutex<[String: Int]>([:])

    func bytesRead(_ url: URL) -> Int {
        counts.withLock { $0[url.path, default: 0] }
    }

    func reset() {
        counts.withLock { $0 = [:] }
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        try base.contentsOfDirectory(at: url)
    }

    func attributes(of url: URL) throws -> FileEntry {
        try base.attributes(of: url)
    }

    func read(_ url: URL, range: Range<Int>) throws -> Data {
        let data = try base.read(url, range: range)
        counts.withLock { $0[url.path, default: 0] += data.count }
        return data
    }

    func volume(of url: URL) throws -> VolumeInfo {
        try base.volume(of: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try base.moveItem(at: source, to: destination)
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
}

/// The Mac's file system, with reads of the files `corrupts` picks coming back with their first byte
/// changed: a copy that reads back different from what was written.
final class CorruptingFileSystem: LibraryFileSystem {
    let base = LocalFileSystem()
    let corrupts: @Sendable (URL) -> Bool

    init(corrupting corrupts: @escaping @Sendable (URL) -> Bool) {
        self.corrupts = corrupts
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        try base.contentsOfDirectory(at: url)
    }

    func attributes(of url: URL) throws -> FileEntry {
        try base.attributes(of: url)
    }

    func read(_ url: URL, range: Range<Int>) throws -> Data {
        var data = try base.read(url, range: range)
        if range.lowerBound == 0, !data.isEmpty, corrupts(url) {
            data[data.startIndex] ^= 0xFF
        }
        return data
    }

    func volume(of url: URL) throws -> VolumeInfo {
        try base.volume(of: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try base.moveItem(at: source, to: destination)
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
}

/// Whether APFS says the file may share its blocks with another: a clone, or a file cloned from.
func mayShareBlocks(_ url: URL) -> Bool? {
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    list.forkattr = attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
    var buffer = [UInt8](repeating: 0, count: 64)
    guard getattrlist(url.path, &list, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED)) == 0 else { return nil }
    let flags = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
    return flags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
}

extension ImportSession {
    /// Browses to the end, collecting what was reported.
    func browsed() async -> [ImportEvent] {
        var events: [ImportEvent] = []
        for await event in browse() {
            events.append(event)
        }
        return events
    }

    func id(named name: String) -> String? {
        photos.first { $0.primary.name == name }?.id
    }
}
