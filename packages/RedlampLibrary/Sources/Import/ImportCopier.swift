import CryptoKit
import Foundation
import Synchronization

/// Why a copy isn't verified.
public struct ImportCopyError: Error, Sendable, Hashable, CustomStringConvertible {
    public var path: String
    public var message: String

    public var description: String {
        "\(path): \(message)"
    }

    /// What went wrong, as a sentence the report shows.
    static func message(_ error: any Error) -> String {
        (error as? ImportCopyError)?.message ?? FileRunner.message(error)
    }
}

/// Copies a photo's files from its source to the destination and the backup at once (LIB-27). Each
/// file is read once, through its volume's readers, in chunks hashed with SHA-256 as they're written
/// under a hidden name beside each target; then put on the disk, read back through the targets' file
/// system and checked against the source's size and hash; and only then renamed into place, never over
/// anything. Every copy is a file of its own, block for block, never a clone sharing the source's
/// blocks. A `.redlamp` package is copied a file at a time, the same way.
struct ImportCopier: Sendable {
    /// The targets' file system: what's read back, renamed and removed.
    let fileSystem: any LibraryFileSystem
    /// One for each target root, in the targets' order.
    let flushes: [ImportFlush]

    static let chunk = 4 << 20

    init(fileSystem: any LibraryFileSystem, roots: [URL]) {
        self.fileSystem = fileSystem
        flushes = roots.map(ImportFlush.init)
    }

    /// A copy written under its hidden names at every target, not yet checked.
    struct Staged: Sendable {
        var copy: ImportPlan.Copy
        var targets: [URL]
        var stagings: [URL]
        /// Each file's SHA-256 as read from the source, by its path inside the copy ("" for a file).
        var digests: [String: Data]

        /// What the journal records: a file's SHA-256, or for a package one over its files' paths and hashes.
        var fingerprint: Data {
            ImportCopier.fingerprint(digests)
        }
    }

    /// Where a copy is written before it's checked.
    static func staging(for target: URL) -> URL {
        target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).redlamp-import")
    }

    // MARK: - Writing

    /// Reads `copy` from its source once and writes it under its hidden name beside each of `targets`,
    /// making their folders.
    func write(_ copy: ImportPlan.Copy, to targets: [URL], io: VolumeIO) async throws -> Staged {
        let stagings = targets.map(Self.staging(for:))
        let fileSystem = fileSystem
        try await LibraryIndex.offCaller {
            for (target, staging) in zip(targets, stagings) {
                try fileSystem.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                )
                if fileSystem.exists(staging) {
                    try fileSystem.removeItem(at: staging)
                }
            }
        }
        let source = URL(fileURLWithPath: copy.source, isDirectory: copy.isDirectory)
        do {
            guard copy.isDirectory else {
                let digest = try await stream(
                    source, size: Int(copy.size), modified: copy.modified, to: stagings, io: io,
                    expecting: copy.role == .photo ? copy.contentKey : nil,
                )
                return Staged(copy: copy, targets: targets, stagings: stagings, digests: ["": digest])
            }
            var digests: [String: Data] = [:]
            try await LibraryIndex.offCaller {
                for staging in stagings {
                    try fileSystem.createDirectory(at: staging, withIntermediateDirectories: false)
                }
            }
            var waiting = [""]
            while let relative = waiting.popLast() {
                let folder = relative.isEmpty ? source : source.appending(path: relative, directoryHint: .isDirectory)
                for entry in try await io.contentsOfDirectory(at: folder, priority: .normal) {
                    let path = relative.isEmpty ? entry.name : relative + "/" + entry.name
                    if entry.isDirectory {
                        try await LibraryIndex.offCaller {
                            for staging in stagings {
                                try fileSystem.createDirectory(
                                    at: staging.appending(path: path, directoryHint: .isDirectory),
                                    withIntermediateDirectories: false,
                                )
                            }
                        }
                        waiting.append(path)
                    } else {
                        digests[path] = try await stream(
                            folder.appending(path: entry.name), size: Int(entry.size), modified: entry.modified,
                            to: stagings.map { $0.appending(path: path) }, io: io,
                        )
                    }
                }
            }
            return Staged(copy: copy, targets: targets, stagings: stagings, digests: digests)
        } catch {
            discard(stagings)
            throw error
        }
    }

    /// Streams the file at `source`, `size` bytes, into new files at `targets`, each given `modified`
    /// and its bytes passed to the drive; returns the SHA-256 of what was read. With `expecting`, the
    /// file's first bytes must give that content key: it's the file that was browsed.
    private func stream(
        _ source: URL, size: Int, modified: Date, to targets: [URL], io: VolumeIO, expecting key: ContentKey? = nil,
    ) async throws -> Data {
        let writers = try await LibraryIndex.offCaller { try targets.map(StagedFile.init(creating:)) }
        let hasher = Hasher()
        do {
            var offset = 0
            while offset < size {
                let data = try await io.read(
                    source,
                    range: offset ..< min(offset + Self.chunk, size),
                    priority: .normal,
                )
                guard !data.isEmpty else {
                    throw ImportCopyError(path: source.path, message: "it's shorter than when it was listed")
                }
                if offset == 0, let key, ContentKey(fileSize: size, head: data.prefix(ContentKey.headLength)) != key {
                    throw ImportCopyError(path: source.path, message: "it changed since it was read")
                }
                try await LibraryIndex.offCaller {
                    hasher.update(data)
                    for writer in writers {
                        try writer.write(data)
                    }
                }
                offset += data.count
            }
            try await LibraryIndex.offCaller {
                for writer in writers {
                    try writer.finish(modified: modified)
                }
            }
        } catch {
            for writer in writers {
                writer.abandon()
            }
            throw error
        }
        return hasher.digest()
    }

    /// Puts what's been written so far at every target on its drive: one flush a target volume, shared
    /// with the copies waiting for it.
    func flush() async throws {
        for flush in flushes {
            try await flush.flush()
        }
    }

    // MARK: - Checking and placing

    /// Reads `staged` back at each target and checks every file's size and SHA-256 against the source's.
    func verify(_ staged: Staged) async throws {
        let fileSystem = fileSystem
        try await LibraryIndex.offCaller {
            for staging in staged.stagings {
                for (path, digest) in staged.digests {
                    let file = path.isEmpty ? staging : staging.appending(path: path)
                    let size = path.isEmpty ? Int(staged.copy.size) : nil
                    guard try Self.digest(of: file, size: size, fileSystem: fileSystem) == digest else {
                        throw ImportCopyError(
                            path: staged.copy.source,
                            message: "the copy at \(staging.deletingLastPathComponent().path) isn't the same as the original",
                        )
                    }
                }
            }
        }
    }

    /// Renames each staged copy to its target, never over anything; when one can't be, removes those it
    /// placed and throws.
    func place(_ staged: [Staged]) async throws {
        let fileSystem = fileSystem
        try await LibraryIndex.offCaller {
            var placed: [URL] = []
            do {
                for copy in staged {
                    for (staging, target) in zip(copy.stagings, copy.targets) {
                        try fileSystem.moveItem(at: staging, to: target)
                        placed.append(target)
                    }
                }
            } catch {
                for target in placed {
                    try? fileSystem.removeItem(at: target)
                }
                throw error
            }
        }
    }

    /// Removes what was written under hidden names.
    func discard(_ stagings: [URL]) {
        for staging in stagings {
            try? fileSystem.removeItem(at: staging)
        }
    }

    // MARK: - Hashes

    /// The SHA-256 of the file at `url` as `fileSystem` reads it; with `size`, throws unless it's that long.
    static func digest(of url: URL, size: Int?, fileSystem: any LibraryFileSystem) throws -> Data {
        var hash = SHA256()
        var offset = 0
        while true {
            let data = try fileSystem.read(url, range: offset ..< offset + chunk)
            hash.update(data: data)
            offset += data.count
            if data.count < chunk {
                break
            }
        }
        if let size, offset != size {
            throw ImportCopyError(path: url.path, message: "the copy is \(offset) bytes, not \(size)")
        }
        return Data(hash.finalize())
    }

    /// What a copy at `url` gives as its fingerprint, as `Staged.fingerprint` does.
    static func fingerprint(of url: URL, isDirectory: Bool, fileSystem: any LibraryFileSystem) throws -> Data {
        guard isDirectory else { return try digest(of: url, size: nil, fileSystem: fileSystem) }
        var digests: [String: Data] = [:]
        var waiting = [""]
        while let relative = waiting.popLast() {
            let folder = relative.isEmpty ? url : url.appending(path: relative, directoryHint: .isDirectory)
            for entry in try fileSystem.contentsOfDirectory(at: folder) {
                let path = relative.isEmpty ? entry.name : relative + "/" + entry.name
                if entry.isDirectory {
                    waiting.append(path)
                } else {
                    digests[path] = try digest(
                        of: folder.appending(path: entry.name),
                        size: nil,
                        fileSystem: fileSystem,
                    )
                }
            }
        }
        return fingerprint(digests)
    }

    static func fingerprint(_ digests: [String: Data]) -> Data {
        if digests.count == 1, let file = digests[""] {
            return file
        }
        var hash = SHA256()
        for (path, digest) in digests.sorted(by: { $0.key < $1.key }) {
            hash.update(data: Data((path + "\t" + ImportJournal.hex(digest) + "\n").utf8))
        }
        return Data(hash.finalize())
    }
}

/// A SHA-256 fed a chunk at a time, from one task.
private final class Hasher: @unchecked Sendable {
    private var hash = SHA256()

    func update(_ data: Data) {
        hash.update(data: data)
    }

    func digest() -> Data {
        Data(hash.finalize())
    }
}

/// A new file written a chunk at a time, by one task.
private final class StagedFile: @unchecked Sendable {
    let url: URL
    private var descriptor: Int32

    init(creating url: URL) throws {
        self.url = url
        descriptor = open(LocalFileSystem.composed(url), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError.current }
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress! + written, bytes.count - written)
                if count < 0 {
                    guard errno == EINTR else { throw POSIXError.current }
                    continue
                }
                written += count
            }
        }
    }

    /// Gives the file its source's modification date and passes its bytes to the drive (`fsync`), whose
    /// own cache `ImportFlush` empties.
    func finish(modified: Date) throws {
        defer {
            close(descriptor)
            descriptor = -1
        }
        let seconds = modified.timeIntervalSince1970.rounded(.down)
        let nanoseconds = Int((modified.timeIntervalSince1970 - seconds) * 1e9)
        var times = [
            timespec(tv_sec: Int(seconds), tv_nsec: nanoseconds), timespec(tv_sec: Int(seconds), tv_nsec: nanoseconds),
        ]
        guard futimens(descriptor, &times) == 0, fsync(descriptor) == 0 else { throw POSIXError.current }
    }

    func abandon() {
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        unlink(LocalFileSystem.composed(url))
    }
}

/// Empties one volume's drive cache (`F_FULLFSYNC`) for every copy waiting, one flush at a time: copies
/// that arrive while one runs wait for the next, since their bytes may have reached the drive after
/// it began. A flush costs about 8 ms on an SSD, against a millisecond for each file's `fsync`.
final class ImportFlush: Sendable {
    let root: URL
    private let state = Mutex((running: false, waiting: [CheckedContinuation<Void, any Error>]()))

    init(_ root: URL) {
        self.root = root
    }

    func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let start = state.withLock { state -> Bool in
                state.waiting.append(continuation)
                defer { state.running = true }
                return !state.running
            }
            if start {
                DispatchQueue.global(qos: .userInitiated).async { self.run() }
            }
        }
    }

    private func run() {
        while true {
            let waiting = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
                defer { state.waiting = [] }
                state.running = !state.waiting.isEmpty
                return state.waiting
            }
            guard !waiting.isEmpty else { return }
            let result = Result { try Self.synchronize(root) }
            for continuation in waiting {
                continuation.resume(with: result)
            }
        }
    }

    /// `F_FULLFSYNC` on the volume, through its folder; volumes that can't (network shares, some
    /// FAT drives) have had each file's `fsync`.
    static func synchronize(_ folder: URL) throws {
        let descriptor = open(folder.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError.current }
        defer { close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) != 0, ![ENOTSUP, ENOTTY, EINVAL].contains(errno) {
            throw POSIXError.current
        }
    }
}
