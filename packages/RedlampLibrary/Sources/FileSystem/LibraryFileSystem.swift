import CryptoKit
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
/// attributes, reading part of a file, which volume a file is on, and the file operations' writes
/// (LIB-26). The indexer, change detection and file operations go through it, so the harness can
/// put any of them on a simulated spinning disk or network volume (`SimulatedFileSystem`).
///
/// Every call blocks until the volume answers, as the file system does: call it from the
/// scheduler's lanes, never from the main thread or Swift's cooperative pool. What the writes make
/// is named in Unicode's composed form (NFC), as the index then has it.
public protocol LibraryFileSystem: Sendable {
    /// The folder's entries in no particular order, hidden ones left out.
    func contentsOfDirectory(at url: URL) throws -> [FileEntry]
    func attributes(of url: URL) throws -> FileEntry
    /// The bytes of `range`, fewer when the file ends inside it.
    func read(_ url: URL, range: Range<Int>) throws -> Data
    func volume(of url: URL) throws -> VolumeInfo

    /// Renames or moves a file or folder on its volume, never replacing anything: `EEXIST` when
    /// something is at `destination` (unless it's the file itself, its name changed only in case or
    /// form), and `EXDEV` when `destination` is on another volume, which only `copyItem` crosses.
    func moveItem(at source: URL, to destination: URL) throws
    /// Copies a file, or a folder and everything in it, to `destination`, where nothing may be, with
    /// its dates; it's on the disk when this returns.
    func copyItem(at source: URL, to destination: URL) throws
    /// Copies a file to `destination`, where nothing may be, with its dates, as `copyItem` does, reading it
    /// once: each part is hashed as it's written. Returns what it read, to check the copy against.
    func copyFile(at source: URL, to destination: URL) throws -> FileDigest
    /// Clones a file, or a folder and everything in it, to `destination`, where nothing may be: a copy on
    /// its volume that shares the original's blocks until either is written (APFS), with its dates,
    /// made without reading a byte. `EXDEV` when `destination` is on another volume and `ENOTSUP` when
    /// the volume can't clone, which only `copyItem` and `copyFile` cross.
    func cloneItem(at source: URL, to destination: URL) throws
    /// Makes a folder, `EEXIST` when something is there; with `intermediates`, the folders above it
    /// too, and a folder already there is no error.
    func createDirectory(at url: URL, withIntermediateDirectories intermediates: Bool) throws
    /// Removes a file, or a folder and everything in it.
    func removeItem(at url: URL) throws
    /// Moves a file or folder to its volume's Trash, and returns where it went.
    func trashItem(at url: URL) throws -> URL
    /// The folder `trashItem` moves `url` to.
    func trashDirectory(for url: URL) throws -> URL
}

/// A file system that only reads: its writes throw `EROFS`.
public extension LibraryFileSystem {
    func moveItem(at _: URL, to _: URL) throws {
        throw POSIXError(.EROFS)
    }

    func copyItem(at _: URL, to _: URL) throws {
        throw POSIXError(.EROFS)
    }

    /// `copyItem`, then the original read.
    func copyFile(at source: URL, to destination: URL) throws -> FileDigest {
        try copyItem(at: source, to: destination)
        return try FileDigest(of: source, in: self)
    }

    /// No clones: what's copied is copied byte for byte.
    func cloneItem(at _: URL, to _: URL) throws {
        throw POSIXError(.ENOTSUP)
    }

    func createDirectory(at _: URL, withIntermediateDirectories _: Bool) throws {
        throw POSIXError(.EROFS)
    }

    func removeItem(at _: URL) throws {
        throw POSIXError(.EROFS)
    }

    func trashItem(at _: URL) throws -> URL {
        throw POSIXError(.EROFS)
    }

    func trashDirectory(for _: URL) throws -> URL {
        throw POSIXError(.EROFS)
    }

    /// Whether something is at `url`: a file, a folder or a link.
    func exists(_ url: URL) -> Bool {
        (try? attributes(of: url)) != nil
    }
}

/// A file's bytes as one read gave them: their SHA-256 and how many there were.
public struct FileDigest: Sendable, Hashable {
    public var sha256: Data
    public var size: Int64

    public init(sha256: Data, size: Int64) {
        self.sha256 = sha256
        self.size = size
    }

    /// The file at `url`, read through `fileSystem` a part at a time.
    public init(of url: URL, in fileSystem: any LibraryFileSystem) throws {
        var hash = SHA256()
        var size = 0
        while true {
            let data = try fileSystem.read(url, range: size ..< size + Self.part)
            hash.update(data: data)
            size += data.count
            if data.count < Self.part {
                break
            }
        }
        self.init(sha256: Data(hash.finalize()), size: Int64(size))
    }

    /// How much is read at a time.
    static let part = 4 << 20
}
