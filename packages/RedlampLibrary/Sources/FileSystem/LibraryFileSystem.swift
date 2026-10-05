import Foundation

/// A file or folder found in a listing, with what the library needs before reading it.
public struct FileEntry: Sendable, Hashable {
    public let name: String
    public let isDirectory: Bool
    /// A folder Finder shows as one file: an app, a `.photoslibrary`, a sidecar once Redlamp's
    /// type is registered. Sidecars are told by their extension, which doesn't need that.
    public let isPackage: Bool
    public let size: Int64
    public let modified: Date
    /// The file's identifier on its volume (its inode), kept across renames and moves within
    /// the volume; nil where the volume has none.
    public let fileIdentifier: UInt64?

    public init(
        name: String, isDirectory: Bool = false, isPackage: Bool = false, size: Int64 = 0,
        modified: Date = .distantPast, fileIdentifier: UInt64? = nil,
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.size = size
        self.modified = modified
        self.fileIdentifier = fileIdentifier
    }
}

/// The volume a file is on.
public struct VolumeInfo: Sendable, Hashable {
    /// The volume's persistent UUID; nil for a volume without one (some network shares).
    public let uuid: String?
    public let name: String?
    /// On a device attached to this Mac. Network volumes are never local.
    public let isLocal: Bool
    /// On the Mac's internal bus rather than an external drive.
    public let isInternal: Bool

    public init(uuid: String?, name: String?, isLocal: Bool, isInternal: Bool) {
        self.uuid = uuid
        self.name = name
        self.isLocal = isLocal
        self.isInternal = isInternal
    }
}

public enum LibraryFileSystemError: Error, Equatable, Sendable {
    /// The volume is gone: unplugged, unmounted, or its network down.
    case unreachable(URL)
    /// The volume stopped answering, and the operation gave up after its timeout.
    case timedOut(URL)
}

/// Every file operation the library makes on the photos' volumes: listing a folder, a file's
/// attributes, reading part of a file, and which volume a file is on. The indexer, change
/// detection and file operations go through it, so the harness can put any of them on a
/// simulated spinning disk or network volume (`SimulatedFileSystem`).
///
/// Every call blocks until the volume answers, as the file system does: call it from the
/// scheduler's lanes, never from the main thread or Swift's cooperative pool.
public protocol LibraryFileSystem: Sendable {
    /// The folder's entries in no particular order, hidden ones left out.
    func contentsOfDirectory(at url: URL) throws -> [FileEntry]
    func attributes(of url: URL) throws -> FileEntry
    /// The bytes of `range`, fewer when the file ends inside it.
    func read(_ url: URL, range: Range<Int>) throws -> Data
    func volume(of url: URL) throws -> VolumeInfo
}
