import CryptoKit
import Foundation
import RedlampDocument
import Synchronization

/// Finds the library's exact duplicates (LIB-39). Candidates are grouped by content key and size
/// from the index in one pass. Confirming reads each candidate's whole file through its volume's
/// readers and hashes it with SHA-256, and the index records the hash with the file's size,
/// modification date and content key, so a file that hasn't changed is never read again. Only
/// photos whose full hashes agree are duplicates.
///
/// Nothing here moves or removes a file: what's removed is a `DuplicateRemovalPlan` the user
/// confirms, which file operations carry out (LIB-26).
public struct DuplicateFinder: Sendable {
    /// How far confirming has got.
    public struct Progress: Sendable, Hashable {
        /// Candidates to compare, and those done.
        public var candidates = 0
        public var done = 0
        /// Of those done, the ones whose recorded hash stood.
        public var reused = 0
        /// Bytes of the files to read, and those read.
        public var bytes: Int64 = 0
        public var bytesRead: Int64 = 0
    }

    /// What one operation reads of a file.
    static let chunkLength = 1 << 20
    /// Hashes written to the index together, at most.
    static let hashBatch = 64

    public let index: LibraryIndex
    /// The readers of the photos' volumes: the indexer's, so they agree on how wide each volume is
    /// and whether it's there.
    public let volumes: VolumeIORegistry
    public let sidecars: SidecarStore

    public init(index: LibraryIndex, volumes: VolumeIORegistry, sidecars: SidecarStore = SidecarStore()) {
        self.index = index
        self.volumes = volumes
        self.sidecars = sidecars
    }

    public init(
        index: LibraryIndex, fileSystem: any LibraryFileSystem = LocalFileSystem(),
        sidecars: SidecarStore = SidecarStore(),
    ) {
        self.init(index: index, volumes: VolumeIORegistry(fileSystem: fileSystem), sidecars: sidecars)
    }

    /// The photos whose content keys and sizes agree, from one pass over the index on one of its
    /// read connections. Offline photos are among them: confirming leaves them unconfirmed.
    public func candidates() async throws -> DuplicateCandidates {
        try await index.read { try $0.groupContentKeys().candidates() }
    }

    /// The readers of the volume the index names `key`, found from its root `root`; nil when the
    /// volume isn't there, doesn't answer, or isn't the one indexed.
    func io(forVolume key: String, root: String) async -> VolumeIO? {
        let url = URL(fileURLWithPath: root, isDirectory: true)
        guard let info = try? await volumes.volume(of: url), VolumeIORegistry.key(for: info, probe: url) == key
        else { return nil }
        let io = volumes.io(for: info, probe: url)
        return io.isReachable ? io : nil
    }

    /// Files read at once on `io`'s volume: one on an external disk, which may be a spinning one
    /// whose head would move between files read side by side; else as many as its readers' width.
    static func filesAtOnce(on io: VolumeIO) -> Int {
        io.volume.isLocal && !io.volume.isInternal ? 1 : max(io.width, 1)
    }

    /// The SHA-256 of the file's `size` bytes, read in order through `io`, the next part read while
    /// the last is hashed. `read` is called with the bytes of each part. Throws `FileChanged` when
    /// the file is longer or shorter than `size`.
    static func sha256(
        of url: URL, size: Int, on io: VolumeIO, read: @Sendable (Int) -> Void = { _ in },
    ) async throws -> Data {
        /// The last part asks for a byte more, so a file that has grown is found.
        func range(from offset: Int) -> Range<Int> {
            offset ..< (offset + chunkLength >= size ? size + 1 : offset + chunkLength)
        }
        var hash = SHA256()
        var offset = 0
        var part = try await io.read(url, range: range(from: 0))
        while true {
            let expected = min(chunkLength, size - offset)
            guard part.count == expected else { throw FileChanged() }
            let next = offset + expected
            guard next < size else {
                hash.update(data: part)
                read(part.count)
                return Data(hash.finalize())
            }
            async let ahead = io.read(url, range: range(from: next))
            hash.update(data: part)
            read(part.count)
            part = try await ahead
            offset = next
        }
    }

    /// A file that isn't the size the index has for it.
    struct FileChanged: Error {}
}
