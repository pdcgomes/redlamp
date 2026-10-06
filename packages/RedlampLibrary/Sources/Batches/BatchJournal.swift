import Foundation
import RedlampEngineAPI
import Synchronization

/// Where a batch of sidecar changes is, as its journal says (`KeywordJournal`, `MetadataJournal`).
public enum BatchState: String, Sendable, Hashable, Codable {
    /// Written, nothing changed yet.
    case planned
    /// The definitions and the index changed; the sidecars are being written, or a forced quit stopped
    /// them.
    case running
    case finished
    /// Going back over what it did, or stopped while it did.
    case rollingBack
    case rolledBack
    /// Its Undo finished.
    case undone

    /// Whether the next launch has to finish it or roll it back.
    public var isUnfinished: Bool {
        self == .planned || self == .running || self == .rollingBack
    }
}

/// A batch as its journal lists it.
public struct BatchEntry: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var created: Date
    public var photos: Int
    public var undoes: UUID?
    public var isUndo: Bool
    public var state: BatchState
    /// Sidecars written, or found unwritable.
    public var done: Int
}

/// A batch a journal keeps: what kind it is, what it does to its photos, its photos, and what each
/// photo's sidecar holds of what it changes (`Values`), as its log records them.
protocol JournalBatch: Sendable {
    associatedtype Kind: Codable & Sendable & Hashable
    associatedtype Edit: Codable & Sendable
    associatedtype Photo: Codable & Sendable
    associatedtype Values: Codable & Sendable & Hashable

    static var undoKind: Kind { get }
    var id: UUID { get }
    var kind: Kind { get }
    var title: String { get }
    var created: Date { get }
    var undoes: UUID? { get }
    var edit: Edit { get }
    /// What it changes in the library's definitions, as JSON.
    var definitionsJSON: JSONValue? { get }
    var photos: [Photo] { get }

    init(
        id: UUID, kind: Kind, title: String, created: Date, undoes: UUID?, edit: Edit, definitionsJSON: JSONValue?,
        photos: [Photo],
    )
}

/// A journal of batches in a folder on the Mac's own disk, as the file operations keep theirs (LIB-26):
/// each batch a file of JSON lines, its header and then a photo a line, written to a hidden name, synced
/// (`F_FULLFSYNC`) and renamed into place before anything changes. Its log gets a line as each photo's
/// sidecar is written, with what the sidecar held before and after, and one at each change of state,
/// written straight to the file: a forced quit loses none of them, and the next launch finishes the
/// batch or rolls it back. Undo reads the log.
struct BatchJournal<Batch: JournalBatch>: Sendable {
    let folder: URL
    let version: Int

    struct Header: Codable {
        var version: Int
        var id: UUID
        var kind: Batch.Kind
        var title: String
        var created: Double
        var photos: Int
        var undoes: UUID?
        var edit: Batch.Edit
        var definitions: JSONValue?
    }

    /// The fields of a header `entries` reads, whatever the batch.
    private struct Summary: Decodable {
        var id: UUID
        var kind: Batch.Kind
        var title: String
        var created: Double
        var photos: Int
        var undoes: UUID?
    }

    /// A line of a batch's log: a photo's sidecar written (`before` and `after`) or left as it was
    /// (`skipped`), or a change of state.
    struct Record: Codable {
        var photo: Int?
        var before: Batch.Values?
        var after: Batch.Values?
        var skipped: String?
        var state: BatchState?
    }

    /// What a batch's log says.
    struct Progress: Sendable {
        var state = BatchState.planned
        /// Each sidecar written, by the photo's place in the batch.
        var written: [Int: (before: Batch.Values, after: Batch.Values)] = [:]
        var skipped: [Int: String] = [:]

        var done: Int {
            written.count + skipped.count
        }
    }

    // MARK: - Writing

    /// Writes `batch` and syncs it, with an empty log.
    func write(_ batch: Batch) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = Self.fileName(created: batch.created, id: batch.id)
        let header = Header(
            version: version, id: batch.id, kind: batch.kind, title: batch.title,
            created: batch.created.timeIntervalSince1970, photos: batch.photos.count, undoes: batch.undoes,
            edit: batch.edit, definitions: batch.definitionsJSON,
        )
        let encoder = Self.encoder
        var data = try encoder.encode(header)
        data.append(0x0A)
        for photo in batch.photos {
            try data.append(encoder.encode(photo))
            data.append(0x0A)
        }
        let staging = folder.appending(path: ".\(name).batch.\(UUID().uuidString)")
        try FileJournal.writeSynced(data, to: staging)
        let log = folder.appending(path: name + ".log")
        try FileJournal.writeSynced(Data(), to: log)
        guard rename(staging.path, folder.appending(path: name + ".batch").path) == 0 else {
            let error = POSIXError.current
            unlink(staging.path)
            unlink(log.path)
            throw error
        }
        try FileJournal.synchronizeFolder(folder)
    }

    /// Opens `batch`'s log to add to it; nil when there's no such batch.
    func log(_ id: UUID) throws -> Log? {
        guard let name = fileNames()[id] else { return nil }
        return try Log(url: folder.appending(path: name + ".log"))
    }

    /// A batch's log, open for adding lines from any thread.
    final class Log: Sendable {
        private let descriptor: Int32
        private let lock = Mutex(())

        init(url: URL) throws {
            descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { throw POSIXError.current }
        }

        deinit {
            close(descriptor)
        }

        func written(_ photo: Int, before: Batch.Values, after: Batch.Values) throws {
            try append(Record(photo: photo, before: before, after: after))
        }

        func skipped(_ photo: Int, _ reason: String) throws {
            try append(Record(photo: photo, skipped: reason))
        }

        /// Records a change of state, and syncs the log.
        func state(_ state: BatchState) throws {
            try append(Record(state: state))
            try lock.withLock { _ in
                guard fsync(descriptor) == 0 else { throw POSIXError.current }
            }
        }

        private func append(_ record: Record) throws {
            var line = try BatchJournal.encoder.encode(record)
            line.append(0x0A)
            try lock.withLock { _ in
                try line.withUnsafeBytes { bytes in
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
        }
    }

    // MARK: - Reading

    /// Every batch, oldest first.
    func entries() -> [BatchEntry] {
        fileNames().values.sorted().compactMap { name in
            guard let header = try? Self.header(of: folder.appending(path: name + ".batch")) else { return nil }
            let (state, done) = summary(name: name)
            return BatchEntry(
                id: header.id, title: header.title, created: Date(timeIntervalSince1970: header.created),
                photos: header.photos, undoes: header.undoes, isUndo: header.kind == Batch.undoKind, state: state,
                done: done,
            )
        }
    }

    /// A batch's state and how many of its photos are done, from its log without reading every line's
    /// values: a change of state is the only line that starts with its key.
    private func summary(name: String) -> (state: BatchState, done: Int) {
        guard let data = try? Data(contentsOf: folder.appending(path: name + ".log")) else { return (.planned, 0) }
        let prefix = Data(#"{"state":"#.utf8)
        var state = BatchState.planned
        var done = 0
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if line.starts(with: prefix) {
                if let record = try? decoder.decode(Record.self, from: line), let changed = record.state {
                    state = changed
                }
            } else if line.last == UInt8(ascii: "}") {
                done += 1
            }
        }
        return (state, done)
    }

    enum Failure: Error {
        case noSuchBatch, damaged, newer
    }

    /// The batch, and what its log says.
    func load(_ id: UUID) throws(Failure) -> (batch: Batch, progress: Progress) {
        guard let name = fileNames()[id] else { throw .noSuchBatch }
        guard let data = try? Data(contentsOf: folder.appending(path: name + ".batch")) else { throw .damaged }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).makeIterator()
        let decoder = JSONDecoder()
        guard let first = lines.next(), let header = try? decoder.decode(Header.self, from: first) else {
            throw .damaged
        }
        guard header.version <= version else { throw .newer }
        var photos: [Batch.Photo] = []
        photos.reserveCapacity(header.photos)
        while let line = lines.next() {
            guard let photo = try? decoder.decode(Batch.Photo.self, from: line) else { throw .damaged }
            photos.append(photo)
        }
        guard photos.count == header.photos else { throw .damaged }
        let batch = Batch(
            id: header.id, kind: header.kind, title: header.title,
            created: Date(timeIntervalSince1970: header.created), undoes: header.undoes, edit: header.edit,
            definitionsJSON: header.definitions, photos: photos,
        )
        return (batch, progress(name: name))
    }

    /// The log's lines played back. A line a forced quit cut short is left out.
    private func progress(name: String) -> Progress {
        var progress = Progress()
        guard let data = try? Data(contentsOf: folder.appending(path: name + ".log")) else { return progress }
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(Record.self, from: line) else { continue }
            if let photo = record.photo {
                if let reason = record.skipped {
                    progress.skipped[photo] = reason
                } else if let before = record.before, let after = record.after {
                    progress.written[photo] = (before, after)
                }
            }
            if let state = record.state {
                progress.state = state
            }
        }
        return progress
    }

    /// Batch files' names without their extensions, by batch.
    private func fileNames() -> [UUID: String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [:] }
        var found: [UUID: String] = [:]
        for name in names where name.hasSuffix(".batch") && !name.hasPrefix(".") {
            let stem = String(name.dropLast(".batch".count))
            if let id = stem.split(separator: " ").last.flatMap({ UUID(uuidString: String($0)) }) {
                found[id] = stem
            }
        }
        return found
    }

    /// Removes all but the `kept` newest batches that are over, and what interrupted writes left.
    func prune(keeping kept: Int) {
        let names = fileNames()
        for entry in entries().filter({ !$0.state.isUnfinished }).dropLast(kept) {
            guard let name = names[entry.id] else { continue }
            unlink(folder.appending(path: name + ".batch").path)
            unlink(folder.appending(path: name + ".log").path)
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.hasPrefix(".") && name.contains(".batch.") {
            unlink(folder.appending(path: name).path)
        }
    }

    // MARK: - Files

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }

    /// `2026-10-06 021000.123 <id>`: names sort as batches were made.
    static func fileName(created: Date, id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HHmmss.SSS"
        return formatter.string(from: created) + " " + id.uuidString
    }

    private static func header(of url: URL) throws -> Summary {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.firstIndex(of: 0x0A) == nil, let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
        }
        return try JSONDecoder().decode(Summary.self, from: data.prefix { $0 != 0x0A })
    }
}
