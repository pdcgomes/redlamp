import Dispatch
import Foundation
import RedlampDocument
import Synchronization

/// Where the library's roots keep their photos' `.redlamp` sidecars (LIB-11, DEC-36): beside the
/// photos, as each root does unless it says otherwise, or in Redlamp on this Mac
/// (`LibraryPaths.sidecars`), as its `sidecars` column says. A root Redlamp can't write beside is set
/// to this Mac on its own, once, when it's first probed (`choosePlacements`); the user sets the rest
/// (`setPlacement`), and a move takes a root's sidecars from one place to the other
/// (`planMove`). Sidecars are read from both places wherever they were written.
///
/// The library keeps each root's path in its volume, from when it was last probed or set, so the
/// locator finds sidecars on this Mac while the volume is away or mounted somewhere else.
public struct LibrarySidecars: Sendable {
    public let index: LibraryIndex
    public let paths: LibraryPaths

    public init(index: LibraryIndex, paths: LibraryPaths) {
        self.index = index
        self.paths = paths
    }

    /// The library whose index is `index`, at `LibraryPaths.index` in its folder.
    public init(index: LibraryIndex) {
        self.init(index: index, paths: LibraryPaths(root: index.url.deletingLastPathComponent()))
    }

    // MARK: - Placements

    /// The locator the library's sidecars are written and read through: every root that keeps them
    /// on this Mac, and every other root that has some there.
    public func locator() async throws -> SidecarLocator {
        let folder = paths.sidecars
        let roots = try await index.read { reader in try Self.locatorRoots(reader) }
        return try await LibraryIndex.offCaller {
            SidecarLocator(folder: folder, roots: roots.filter { root in
                root.onThisMac || FileManager.default.fileExists(atPath: Self.folder(of: root, in: folder).path)
            })
        }
    }

    /// Sets where `root` keeps its sidecars from now on, without moving those it has, which are
    /// still read where they are. It's never chosen again on its own.
    public func setPlacement(_ placement: RootRecord.Sidecars, forRoot root: Int64) async throws {
        guard let record = try await index.read({ try $0.root(id: root) }) else {
            throw LibrarySidecarsError.noSuchRoot(root)
        }
        let inVolume = try await LibraryIndex.offCaller {
            Self.pathInVolume(of: URL(fileURLWithPath: record.path, isDirectory: true))
        }
        try await index.write { writer in
            try writer.setSidecars(placement, forRoot: root)
            try writer.setSetting("1", for: Self.probedKey(root))
            if let inVolume {
                try writer.setSetting(inVolume, for: Self.pathKey(root))
            }
        }
    }

    /// Probes each root that hasn't been (`canWrite(in:)`), and keeps the sidecars of those Redlamp
    /// can't write in on this Mac: on a read-only volume, in a folder it may not write to, on a share
    /// that refuses writes. A root that isn't there, or doesn't answer within `timeout`, is probed
    /// again next time. Returns the roots set to this Mac.
    @discardableResult
    public func choosePlacements(timeout: Duration = .seconds(10)) async throws -> [Int64] {
        let roots = try await index.read { reader in
            try reader.roots().filter { try reader.setting(Self.probedKey($0.id)) == nil }
        }
        let probes = await withTaskGroup(of: (Int64, (writable: Bool, inVolume: String?))?.self) { group in
            for root in roots {
                let folder = URL(fileURLWithPath: root.path, isDirectory: true)
                group.addTask {
                    let probe = await Self.answer(within: timeout) {
                        Self.canWrite(in: folder).map { (writable: $0, inVolume: Self.pathInVolume(of: folder)) }
                    }
                    return (probe ?? nil).map { (root.id, $0) }
                }
            }
            return await group.reduce(into: [(Int64, (writable: Bool, inVolume: String?))]()) { probes, probe in
                if let probe {
                    probes.append(probe)
                }
            }
        }
        return try await index.write { writer -> [Int64] in
            var chosen: [Int64] = []
            for (root, probe) in probes.sorted(by: { $0.0 < $1.0 }) {
                guard try writer.setting(Self.probedKey(root)) == nil else { continue }
                if !probe.writable {
                    try writer.setSidecars(.onThisMac, forRoot: root)
                    chosen.append(root)
                }
                try writer.setSetting("1", for: Self.probedKey(root))
                if let inVolume = probe.inVolume {
                    try writer.setSetting(inVolume, for: Self.pathKey(root))
                }
            }
            return chosen
        }
    }

    // MARK: - Census

    /// How many sidecars `root` has in each place, and how many other apps' `.xmp` beside its
    /// photos.
    public func census(ofRoot root: Int64) async throws -> SidecarCensus {
        let (record, locatorRoot) = try await knownRoot(root)
        let beside = try await Self.besideSidecars(below: URL(fileURLWithPath: record.path, isDirectory: true))
        let mac = try await Self.macSidecars(of: locatorRoot, in: paths.sidecars)
        return SidecarCensus(
            root: record.path, placement: record.sidecars, beside: beside.sidecars.count, onThisMac: mac.count,
            both: beside.sidecars.intersection(mac).count, otherApps: beside.otherApps,
        )
    }

    /// The root's record and how the locator knows it.
    func knownRoot(_ id: Int64) async throws -> (RootRecord, SidecarLocator.Root) {
        let found = try await index.read { reader -> (RootRecord, SidecarLocator.Root)? in
            guard let record = try reader.root(id: id),
                  let root = try Self.locatorRoots(reader).first(where: { $0.path == record.path })
            else { return nil }
            return (record, root)
        }
        guard let found else { throw LibrarySidecarsError.noSuchRoot(id) }
        return found
    }

    // MARK: - Settings

    static func probedKey(_ root: Int64) -> String {
        "library.sidecars.probed.\(root)"
    }

    static func pathKey(_ root: Int64) -> String {
        "library.sidecars.path.\(root)"
    }

    /// Every root, as the locator knows it.
    static func locatorRoots(_ reader: some IndexQueries) throws -> [SidecarLocator.Root] {
        let volumes = try Dictionary(reader.volumes().map { ($0.id, $0.uuid) }) { first, _ in first }
        return try reader.roots().compactMap { root in
            guard let volume = volumes[root.volume] else { return nil }
            return try SidecarLocator.Root(
                path: root.path, volume: volume,
                pathInVolume: reader.setting(pathKey(root.id)) ?? guessedPathInVolume(root.path),
                onThisMac: root.sidecars == .onThisMac,
            )
        }
    }

    /// The folder on this Mac that holds `root`'s sidecars.
    static func folder(of root: SidecarLocator.Root, in sidecars: URL) -> URL {
        let volume = sidecars.appending(
            path: root.volume.replacingOccurrences(of: "/", with: ":"),
            directoryHint: .isDirectory,
        )
        return root.pathInVolume.isEmpty ? volume : volume.appending(
            path: root.pathInVolume,
            directoryHint: .isDirectory,
        )
    }

    // MARK: - The file system

    /// The folder's path from its volume's root, without a slash at either end; nil when its volume
    /// can't be asked.
    static func pathInVolume(of folder: URL) -> String? {
        guard let volume = try? folder.resourceValues(forKeys: [.volumeURLKey]).volume else { return nil }
        let mount = LibraryIndexer.path(volume.resolvingSymlinksInPath())
        let path = LibraryIndexer.path(folder.resolvingSymlinksInPath())
        if mount == "/" {
            return String(path.dropFirst())
        }
        if path == mount {
            return ""
        }
        guard path.hasPrefix(mount + "/") else { return nil }
        return String(path.dropFirst(mount.count + 1))
    }

    /// A root's path in its volume as macOS mounts volumes, for a root never probed: below
    /// `/Volumes/<name>` for an external volume, from `/` for the startup disk.
    static func guessedPathInVolume(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.first == "Volumes", parts.count >= 2 {
            return parts.dropFirst(2).joined(separator: "/")
        }
        return parts.joined(separator: "/")
    }

    /// Whether Redlamp can write in `folder`; nil when the folder isn't there. A local volume says
    /// so without anything being written; on a network volume, whose share may refuse writes its
    /// permissions allow, a hidden file is made there and removed. That file is named as an
    /// interrupted save's leftover, so a share that lets it be made but not removed has it removed
    /// with them.
    static func canWrite(in folder: URL) -> Bool? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .volumeIsReadOnlyKey, .volumeIsLocalKey]
        guard let values = try? URL(fileURLWithPath: folder.path).resourceValues(forKeys: keys),
              values.isDirectory == true
        else { return nil }
        if values.volumeIsReadOnly == true || access(folder.path, W_OK) != 0 {
            return false
        }
        if values.volumeIsLocal == true {
            return true
        }
        let probe = folder.appending(path: ".redlamp-probe.redlamp.\(UUID().uuidString)").path
        let descriptor = open(probe, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return errno == ENOENT ? nil : false }
        var byte: UInt8 = 0
        let wrote = write(descriptor, &byte, 1) == 1
        let closed = close(descriptor) == 0
        let removed = unlink(probe) == 0
        return wrote && closed && removed
    }

    /// `body`'s answer on a thread of its own, or nil once `timeout` has passed without one.
    static func answer<T: Sendable>(within timeout: Duration, _ body: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resumed = Mutex(false)
            let resume: @Sendable (T?) -> Void = { value in
                guard resumed.withLock({ done in
                    defer { done = true }
                    return !done
                }) else { return }
                continuation.resume(returning: value)
            }
            DispatchQueue.global(qos: .utility).async {
                resume(body())
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.seconds) {
                resume(nil)
            }
        }
    }

    /// The photos below `root` with a `.redlamp` sidecar beside them, by their paths below it, and
    /// how many other apps' `.xmp` there are.
    static func besideSidecars(below root: URL) async throws -> (sidecars: Set<String>, otherApps: Int) {
        let found = Mutex((sidecars: Set<String>(), otherApps: 0))
        try await FolderWalk.walk(root, fileSystem: LocalFileSystem(), width: 4) { folder, entries in
            var sidecars: [String] = []
            var otherApps = 0
            for entry in entries {
                let name = entry.name.lowercased()
                if name.hasSuffix(".redlamp") {
                    let photo = String(entry.name.dropLast(".redlamp".count))
                    sidecars.append(folder.isEmpty ? photo : folder + "/" + photo)
                } else if !entry.isDirectory, name.hasSuffix(".xmp") {
                    otherApps += 1
                }
            }
            found.withLock { found in
                found.sidecars.formUnion(sidecars)
                found.otherApps += otherApps
            }
        }
        return found.withLock { $0 }
    }

    /// The photos of `root` with a sidecar on this Mac, by their paths below it.
    static func macSidecars(of root: SidecarLocator.Root, in sidecars: URL) async throws -> Set<String> {
        let folder = folder(of: root, in: sidecars)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let found = Mutex(Set<String>())
        try await FolderWalk.walk(folder, fileSystem: LocalFileSystem(), width: 4) { path, entries in
            let photos = entries.filter { $0.name.lowercased().hasSuffix(".redlamp") }.map { entry in
                let photo = String(entry.name.dropLast(".redlamp".count))
                return path.isEmpty ? photo : path + "/" + photo
            }
            found.withLock { $0.formUnion(photos) }
        }
        return found.withLock { $0 }
    }
}

/// How many sidecars a root has in each place (`LibrarySidecars.census`).
public struct SidecarCensus: Sendable, Hashable {
    public var root: String
    /// Where its sidecars are written.
    public var placement: RootRecord.Sidecars
    /// Photos with a sidecar beside them.
    public var beside: Int
    /// Photos with a sidecar on this Mac.
    public var onThisMac: Int
    /// Photos with one in each place: read from the one saved last, and in the way of a move.
    public var both: Int
    /// Other apps' `.xmp` beside its photos, which stay there.
    public var otherApps: Int

    public init(
        root: String, placement: RootRecord.Sidecars, beside: Int, onThisMac: Int, both: Int, otherApps: Int,
    ) {
        self.root = root
        self.placement = placement
        self.beside = beside
        self.onThisMac = onThisMac
        self.both = both
        self.otherApps = otherApps
    }
}

public enum LibrarySidecarsError: Error, Sendable, Hashable {
    case noSuchRoot(Int64)
    /// Photos whose sidecar is already where the move would put it: nothing was moved.
    case conflicts([SidecarMovePlan.Conflict])
}

public extension LibraryIndex.Writer {
    /// Sets where `root` keeps its sidecars.
    func setSidecars(_ sidecars: RootRecord.Sidecars, forRoot root: Int64) throws {
        let statement = try database.cached("UPDATE roots SET sidecars = ? WHERE id = ?")
        try statement.bind(sidecars.rawValue, at: 1)
        try statement.bind(root, at: 2)
        try statement.run()
    }
}

public extension IndexQueries {
    func root(id: Int64) throws -> RootRecord? {
        let statement = try database.cached("SELECT \(IndexColumns.root) FROM roots WHERE id = ?")
        try statement.bind(id, at: 1)
        return try statement.first(RootRecord.init)
    }

    /// How many photos are in `root`'s folders.
    func photoCount(inRoot root: Int64) throws -> Int {
        let statement = try database.cached("""
        SELECT count(*) FROM photos WHERE folder IN (SELECT id FROM folders WHERE root = ?)
        """)
        try statement.bind(root, at: 1)
        return try statement.first { $0.int(at: 0) } ?? 0
    }
}
