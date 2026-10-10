import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampLibrary

/// A library in a folder of its own for the file operations: a root, `Photos`, of small photo files
/// with `.redlamp` sidecars and other apps' `.xmp`, an index with a row for each photo, and the
/// library's own folder (`LibraryPaths`) with the journal and the sidecars kept on this Mac.
final class FileSandbox: @unchecked Sendable {
    struct Photo {
        enum XMP {
            /// `IMG_0001.xmp`, as Lightroom writes it.
            case stem
            /// `IMG_0001.ARW.xmp`, as darktable writes it.
            case name
        }

        var path: String
        var captured: Date?
        var sidecar: Bool
        var xmp: XMP?

        init(_ path: String, captured: Date? = nil, sidecar: Bool = false, xmp: XMP? = nil) {
            self.path = path
            self.captured = captured
            self.sidecar = sidecar
            self.xmp = xmp
        }
    }

    let folder: TemporaryFolder
    let root: URL
    let paths: LibraryPaths
    let index: LibraryIndex
    let rootID: Int64
    let fileSystem: any LibraryFileSystem

    var rootPath: String {
        LibraryIndexer.path(root)
    }

    private init(
        folder: TemporaryFolder, root: URL, paths: LibraryPaths, index: LibraryIndex, rootID: Int64,
        fileSystem: any LibraryFileSystem,
    ) {
        self.folder = folder
        self.root = root
        self.paths = paths
        self.index = index
        self.rootID = rootID
        self.fileSystem = fileSystem
    }

    /// 1 March 2024 at noon, UTC, and `seconds` after.
    static func date(_ seconds: Double = 0) -> Date {
        Date(timeIntervalSince1970: 1_709_294_400 + seconds)
    }

    static func make(
        _ photos: [Photo], onThisMac: Bool = false, folders: [String] = [], fileSystem: (any LibraryFileSystem)? = nil,
    ) async throws -> FileSandbox {
        let folder = try TemporaryFolder()
        let root = folder.url.appending(path: "Photos", directoryHint: .isDirectory)
        let paths = LibraryPaths(root: folder.url.appending(path: "Library", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for relative in folders {
            try FileManager.default.createDirectory(
                at: root.appending(path: relative),
                withIntermediateDirectories: true,
            )
        }
        for photo in photos {
            let url = root.appending(path: photo.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try Self.contents(of: photo.path).write(to: url)
            switch photo.xmp {
            case .stem: try Data("xmp of \(photo.path)".utf8)
                .write(to: url.deletingPathExtension().appendingPathExtension("xmp"))
            case .name: try Data("xmp of \(photo.path)".utf8).write(to: url.appendingPathExtension("xmp"))
            case nil: break
            }
        }
        let index = try await LibraryIndex.open(at: paths.index, readers: 2)
        let rootPath = LibraryIndexer.path(root)
        let entries = try photos.map { try (LocalFileSystem().attributes(of: root.appending(path: $0.path)), $0) }
        let rootID = try await index.write { writer in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "TEST-VOLUME", name: "Test", kind: .ssd))
            let rootID = try writer.upsertRoot(RootRecord(
                volume: volume, path: rootPath, sidecars: onThisMac ? .onThisMac : .besidePhotos,
            ))
            try writer.setSetting("Photos", for: LibrarySidecars.pathKey(rootID))
            _ = try writer.folderID(forPath: rootPath)
            for relative in folders {
                _ = try writer.folderID(forPath: rootPath + "/" + relative)
            }
            var records: [PhotoRecord] = []
            for (entry, photo) in entries {
                let (folder, name) = FilePlanner.split(rootPath + "/" + photo.path)
                guard let folderID = try writer.folderID(forPath: folder) else { continue }
                records.append(PhotoRecord(
                    folder: folderID, name: name, size: entry.size, modified: entry.modified,
                    fileID: entry.fileIdentifier,
                    contentKey: ContentKey(fileSize: Int(entry.size), head: Self.contents(of: photo.path)).data,
                    captured: photo.captured, indexed: 1,
                ))
            }
            try writer.upsertPhotos(records)
            return rootID
        }
        let sandbox = FileSandbox(
            folder: folder, root: root, paths: paths, index: index, rootID: rootID,
            fileSystem: fileSystem ?? LocalFileSystem(),
        )
        let store = try await sandbox.store()
        for photo in photos where photo.sidecar {
            try store.save(
                Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 3, label: .green), modified: date()),
                for: root.appending(path: photo.path),
            )
        }
        return sandbox
    }

    /// What a photo file holds: its name, so each is told from the others.
    static func contents(of path: String) -> Data {
        Data(("photo \(path) " + String(repeating: "·", count: path.count % 7)).utf8)
    }

    func operations(live: LibraryLive? = nil) -> FileOperations {
        FileOperations(index: index, paths: paths, fileSystem: fileSystem, live: live)
    }

    /// Its file operations, with `trashEvents` the Trash folders' events.
    func operations(trashEvents: (any VolumeEventSource)?) -> FileOperations {
        FileOperations(index: index, paths: paths, fileSystem: fileSystem, live: nil, trashEvents: trashEvents)
    }

    /// What's in the folder `trash`, but hidden files, by path below it, with each file's bytes.
    static func contents(of trash: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        for path in FileManager.default.subpaths(atPath: trash.path) ?? [] {
            guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            var isDirectory: ObjCBool = false
            let url = trash.appending(path: path)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
            else { continue }
            found[path] = try? Data(contentsOf: url)
        }
        return found
    }

    /// The sidecar store the library reads and writes through.
    func store() async throws -> SidecarStore {
        try await SidecarStore(locator: operations().locator())
    }

    func url(_ relative: String) -> URL {
        root.appending(path: relative)
    }

    /// Every file below the root and in the sidecars on this Mac, but hidden ones, by its path below
    /// the root (`mac/…` on this Mac), with its bytes; a sidecar package's files as `IMG.ARW.redlamp/edit.json`.
    func files() -> [String: Data] {
        var found: [String: Data] = [:]
        for (base, prefix) in [(root, ""), (paths.sidecars, "mac/")] {
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

    /// The photos' files below the root (no sidecars), with their bytes.
    func photoFiles() -> [String: Data] {
        files().filter { !$0.key.hasPrefix("mac/") && !$0.key.contains(".redlamp") && !$0.key.hasSuffix(".xmp") }
    }

    /// What's hidden below the root and in the sidecars on this Mac: what an interrupted copy or save
    /// would leave.
    func leftovers() -> [String] {
        [root, paths.sidecars].flatMap { base in
            (FileManager.default.subpaths(atPath: base.path) ?? []).filter { path in
                path.split(separator: "/").contains { $0.hasPrefix(".") }
            }
        }
    }

    /// Each photo's ID by its path below the root, as the index has it.
    func rows() async throws -> [String: Int64] {
        let rootPath = rootPath
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

    /// The sidecar of the photo at `relative`, as the library reads it.
    func sidecar(_ relative: String) async throws -> Sidecar? {
        try await store().load(for: url(relative))
    }

    func remove() {
        index.closeAndWait()
    }
}

extension FileOutcome {
    /// Whether every step was done.
    var isFinished: Bool {
        state == .finished && done == steps
    }
}

/// The Mac's file system, or `base`, counting what's read through it and calling `beforeWrite` before
/// each write.
final class WatchedFileSystem: LibraryFileSystem {
    let base: any LibraryFileSystem
    private let state = Mutex((reads: 0, writes: 0))
    private let beforeWrite: @Sendable (String) -> Void

    init(
        _ base: any LibraryFileSystem = LocalFileSystem(),
        beforeWrite: @escaping @Sendable (String) -> Void = { _ in },
    ) {
        self.base = base
        self.beforeWrite = beforeWrite
    }

    var reads: Int {
        state.withLock { $0.reads }
    }

    var writes: Int {
        state.withLock { $0.writes }
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        try base.contentsOfDirectory(at: url)
    }

    func attributes(of url: URL) throws -> FileEntry {
        try base.attributes(of: url)
    }

    func read(_ url: URL, range: Range<Int>) throws -> Data {
        state.withLock { $0.reads += 1 }
        return try base.read(url, range: range)
    }

    func volume(of url: URL) throws -> VolumeInfo {
        try base.volume(of: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        wrote("move \(source.path)")
        try base.moveItem(at: source, to: destination)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        wrote("copy \(source.path)")
        try base.copyItem(at: source, to: destination)
    }

    func copyFile(at source: URL, to destination: URL) throws -> FileDigest {
        wrote("copy \(source.path)")
        return try base.copyFile(at: source, to: destination)
    }

    func cloneItem(at source: URL, to destination: URL) throws {
        wrote("clone \(source.path)")
        try base.cloneItem(at: source, to: destination)
    }

    func createDirectory(at url: URL, withIntermediateDirectories intermediates: Bool) throws {
        wrote("mkdir \(url.path)")
        try base.createDirectory(at: url, withIntermediateDirectories: intermediates)
    }

    func removeItem(at url: URL) throws {
        wrote("remove \(url.path)")
        try base.removeItem(at: url)
    }

    func trashItem(at url: URL) throws -> URL {
        wrote("trash \(url.path)")
        return try base.trashItem(at: url)
    }

    func trashDirectory(for url: URL) throws -> URL {
        try base.trashDirectory(for: url)
    }

    private func wrote(_ operation: String) {
        beforeWrite(operation)
        state.withLock { $0.writes += 1 }
    }
}

/// Something that happens once, which tasks can wait for.
final class Signal: Sendable {
    private let state = Mutex<(fired: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    var fired: Bool {
        state.withLock { $0.fired }
    }

    func fire() {
        let waiting = state.withLock { state in
            defer { state = (true, []) }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let fired = state.withLock { state in
                if !state.fired {
                    state.waiting.append(continuation)
                }
                return state.fired
            }
            if fired {
                continuation.resume()
            }
        }
    }
}

/// A write a test holds: the first whose operation (`WatchedFileSystem`'s) has `prefix`, from its
/// file system's thread, until it's released.
final class HeldWrite: Sendable {
    let prefix: String
    let reached = Signal()
    private let held = Mutex(false)
    private let released = DispatchSemaphore(value: 0)

    init(_ prefix: String) {
        self.prefix = prefix
    }

    /// For `WatchedFileSystem(beforeWrite:)`.
    func before(_ operation: String) {
        guard operation.hasPrefix(prefix), held.withLock({ held in
            defer { held = true }
            return !held
        }) else { return }
        reached.fire()
        released.wait()
    }

    func release() {
        released.signal()
    }
}
