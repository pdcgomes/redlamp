import Foundation
import Synchronization

/// The simulated volume's writes: each made on `base` and charged the volume's time, unless a
/// failure was injected for it. Folders can be put on volumes of their own (`mount`), so that moving
/// between them has to copy, and the Trash kept in a folder (`useTrash`), so tests leave the Mac's
/// own alone.
public extension SimulatedFileSystem {
    /// A write made to fail, as a full disk, a failing cable or a share that refuses it would.
    struct Failure: Sendable, Hashable {
        public enum Operation: String, Sendable, Hashable, CaseIterable {
            case move, copy, clone, createDirectory, remove, trash
        }

        public enum Effect: Sendable, Hashable {
            /// The operation throws the error without doing anything.
            case error(POSIXErrorCode)
            /// The copy is made, but a byte of each file in it differs from the source's.
            case corruptCopy
        }

        public var operation: Operation
        /// The name of the file or folder it fails for, as its source's last path component; nil for
        /// any.
        public var name: String?
        public var effect: Effect
        /// How many operations it fails before it's spent; nil for every one.
        public var count: Int?

        public init(_ operation: Operation, name: String? = nil, effect: Effect = .error(.EIO), count: Int? = 1) {
            self.operation = operation
            self.name = name
            self.effect = effect
            self.count = count
        }
    }

    /// Makes the next writes `failure` matches fail.
    func inject(_ failure: Failure) {
        writing.withLock { $0.failures.append(failure) }
    }

    /// Puts `folder` and everything below it on a volume of its own, `uuid`.
    func mount(_ folder: URL, uuid: String, name: String? = nil) {
        let path = LibraryIndexer.path(folder)
        writing.withLock { state in
            state.mounts.removeAll { $0.path == path }
            state.mounts.append(Mount(path: path, uuid: uuid, name: name))
            state.mounts.sort { $0.path.count > $1.path.count }
        }
    }

    /// Keeps what's moved to the Trash in `folder`, rather than the Mac's own Trash.
    func useTrash(_ folder: URL) {
        writing.withLock { $0.trash = folder }
    }

    /// The writes made so far, in order: `move <source> <destination>`, `copy …`, `mkdir <folder>`,
    /// `remove <path>` and `trash <path> <where it went>`.
    var writes: [String] {
        writing.withLock { $0.log }
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try write(.move, source) {
            guard mount(of: source)?.uuid == mount(of: destination.deletingLastPathComponent())?.uuid else {
                throw POSIXError(.EXDEV)
            }
            try base.moveItem(at: source, to: destination)
            return "move \(source.path) \(destination.path)"
        }
    }

    func copyItem(at source: URL, to destination: URL) throws {
        let size = (try? base.attributes(of: source).size).map(Int.init) ?? 0
        try write(.copy, source, bytes: size) { corrupt in
            try base.copyItem(at: source, to: destination)
            if corrupt {
                Self.corrupt(destination)
            }
            return "copy \(source.path) \(destination.path)"
        }
    }

    /// A copy made to fail or come out corrupt (`Failure`) does here as in `copyItem`.
    func copyFile(at source: URL, to destination: URL) throws -> FileDigest {
        let size = (try? base.attributes(of: source).size).map(Int.init) ?? 0
        var digest: FileDigest?
        try write(.copy, source, bytes: size) { corrupt in
            digest = try base.copyFile(at: source, to: destination)
            if corrupt {
                Self.corrupt(destination)
            }
            return "copy \(source.path) \(destination.path)"
        }
        guard let digest else { throw POSIXError(.EIO) }
        return digest
    }

    /// Network volumes can't clone, and a clone can't cross a mounted volume's edge.
    func cloneItem(at source: URL, to destination: URL) throws {
        guard profile.isLocal != false else { throw POSIXError(.ENOTSUP) }
        guard mount(of: source)?.uuid == mount(of: destination.deletingLastPathComponent())?.uuid else {
            throw POSIXError(.EXDEV)
        }
        try write(.clone, source) {
            try base.cloneItem(at: source, to: destination)
            return "clone \(source.path) \(destination.path)"
        }
    }

    func createDirectory(at url: URL, withIntermediateDirectories intermediates: Bool) throws {
        try write(.createDirectory, url) {
            try base.createDirectory(at: url, withIntermediateDirectories: intermediates)
            return "mkdir \(url.path)"
        }
    }

    func removeItem(at url: URL) throws {
        try write(.remove, url) {
            try base.removeItem(at: url)
            return "remove \(url.path)"
        }
    }

    func trashItem(at url: URL) throws -> URL {
        var trashed = url
        try write(.trash, url) {
            guard let trash = writing.withLock({ $0.trash }) else {
                trashed = try base.trashItem(at: url)
                return "trash \(url.path) \(trashed.path)"
            }
            try base.createDirectory(at: trash, withIntermediateDirectories: true)
            let name = url.lastPathComponent
            let (stem, ext) = NamingJob.split(name)
            var number = 1
            while true {
                let candidate = number == 1 ? name : "\(stem) \(number)" + (ext.isEmpty ? "" : "." + ext)
                trashed = trash.appending(path: candidate)
                do {
                    try base.moveItem(at: url, to: trashed)
                    break
                } catch let error as POSIXError where error.code == .EEXIST {
                    number += 1
                }
            }
            return "trash \(url.path) \(trashed.path)"
        }
        return trashed
    }

    func trashDirectory(for url: URL) throws -> URL {
        guard let trash = writing.withLock({ $0.trash }) else { return try base.trashDirectory(for: url) }
        return trash
    }

    /// The mounted volume `url` is on, if it's on one.
    internal func mount(of url: URL) -> Mount? {
        let path = LibraryIndexer.path(url)
        return writing.withLock { state in
            state.mounts.first { path == $0.path || path.hasPrefix($0.path + "/") }
        }
    }

    /// Runs a write unless a failure matches it, charging the volume's time either way.
    private func write(
        _ operation: Failure.Operation, _ url: URL, bytes: Int = entryBytes,
        _ body: (_ corrupt: Bool) throws -> String,
    ) throws {
        let effect = writing.withLock { state -> Failure.Effect? in
            guard let index = state.failures.firstIndex(where: { failure in
                failure.operation == operation && (failure.name.map { $0 == url.lastPathComponent } ?? true)
            }) else { return nil }
            let effect = state.failures[index].effect
            if let count = state.failures[index].count {
                if count <= 1 {
                    state.failures.remove(at: index)
                } else {
                    state.failures[index].count = count - 1
                }
            }
            return effect
        }
        try simulate(url, bytes: { _ in bytes }) { () throws in
            if case let .error(code) = effect {
                throw POSIXError(code)
            }
            let entry = try body(effect == .corruptCopy)
            writing.withLock { $0.log.append(entry) }
        }
    }

    private func write(_ operation: Failure.Operation, _ url: URL, bytes: Int = entryBytes, _ body: () throws -> String)
        throws {
        try write(operation, url, bytes: bytes) { _ in try body() }
    }

    /// Changes the first byte of each file in `copy`.
    private static func corrupt(_ copy: URL) {
        var files = [copy.path]
        files += (FileManager.default.subpaths(atPath: copy.path) ?? []).map { copy.path + "/" + $0 }
        for file in files {
            guard let handle = FileHandle(forUpdatingAtPath: file),
                  let first = try? handle.read(upToCount: 1), let byte = first.first
            else { continue }
            try? handle.seek(toOffset: 0)
            try? handle.write(contentsOf: Data([byte ^ 0xFF]))
            try? handle.close()
        }
    }
}

extension SimulatedFileSystem {
    /// A folder on a volume of its own.
    struct Mount: Sendable, Hashable {
        var path: String
        var uuid: String
        var name: String?
    }

    struct WriteState: Sendable {
        var failures: [Failure] = []
        var mounts: [Mount] = []
        var trash: URL?
        var log: [String] = []
    }
}
