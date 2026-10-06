import Foundation
import Synchronization

/// The file operations' journal, in `LibraryPaths.root/File Operations` on the Mac's own disk. Each
/// batch is a file of JSON lines, its summary and then a step a line, written to a hidden name,
/// synced (`F_FULLFSYNC`) and renamed into place before anything moves. Beside it, its log gets a
/// line as each step is done, each item moved to the Trash and each change of state, written
/// straight to the file, so a forced quit loses none of them; a power cut may lose the last few,
/// and the steps' files say where the batch had got to.
public struct FileJournal: Sendable {
    public let folder: URL
    /// Batches kept for Undo; older ones that are over are removed, but for those with photos still in
    /// the Trash, kept for Put Back.
    public static let kept = 50
    static let version = 1

    public init(paths: LibraryPaths) {
        folder = paths.root.appending(path: "File Operations", directoryHint: .isDirectory)
    }

    /// What became of a batch.
    public enum State: String, Sendable, Hashable, Codable {
        /// Written, but nothing logged yet.
        case planned
        /// Running, or stopped by a forced quit: the next launch finishes it or rolls it back.
        case running
        /// Every step done.
        case finished
        /// Cancelled: the steps before a safe one done, the rest left.
        case stopped
        /// Going back over what it did, after a step failed or when asked.
        case rollingBack
        /// Everything it did taken back.
        case rolledBack
        /// Its Undo finished.
        case undone

        /// Whether the next launch has to finish it or roll it back.
        public var isUnfinished: Bool {
            self == .planned || self == .running || self == .rollingBack
        }
    }

    /// A batch as the journal lists it.
    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: UUID
        public var kind: FileBatch.Kind
        public var title: String
        public var created: Date
        public var steps: Int
        public var photos: Int
        public var undoes: UUID?
        public var state: State
        /// Steps done, not counting those rolled back.
        public var done: Int
    }

    /// A batch's first line.
    struct Header: Codable {
        var version: Int
        var id: UUID
        var kind: FileBatch.Kind
        var title: String
        var created: Double
        var steps: Int
        var photos: Int
        var undoes: UUID?
    }

    /// A line of a batch's log.
    struct Record: Codable {
        var done: Int?
        var undone: Int?
        var item: Int?
        var trashed: String?
        var state: State?
    }

    /// What a batch's log says.
    struct Progress: Sendable, Hashable {
        var state = State.planned
        var done = Set<Int>()
        /// Where items went in the Trash, by step and item.
        var trashed: [Int: [Int: String]] = [:]
    }

    // MARK: - Writing

    /// Writes `batch` and syncs it, with an empty log.
    func write(_ batch: FileBatch) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = Self.fileName(of: batch)
        let header = Header(
            version: Self.version, id: batch.id, kind: batch.kind, title: batch.title,
            created: batch.created.timeIntervalSince1970, steps: batch.steps.count, photos: batch.photoCount,
            undoes: batch.undoes,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var data = try encoder.encode(header)
        data.append(0x0A)
        for step in batch.steps {
            try data.append(encoder.encode(step))
            data.append(0x0A)
        }
        let staging = folder.appending(path: ".\(name).batch.\(UUID().uuidString)")
        try Self.writeSynced(data, to: staging)
        let log = folder.appending(path: name + ".log")
        try Self.writeSynced(Data(), to: log)
        guard rename(staging.path, folder.appending(path: name + ".batch").path) == 0 else {
            let error = POSIXError.current
            unlink(staging.path)
            unlink(log.path)
            throw error
        }
        try Self.synchronizeFolder(folder)
    }

    /// Opens `batch`'s log to add to it.
    func log(_ id: UUID) throws -> Log {
        guard let name = try fileNames()[id] else { throw FileOperationError.noSuchBatch(id) }
        return try Log(url: folder.appending(path: name + ".log"))
    }

    /// A batch's log, open for adding lines.
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

        func done(_ step: Int) throws {
            try append(Record(done: step))
        }

        func undone(_ step: Int) throws {
            try append(Record(undone: step))
        }

        func trashed(_ step: Int, item: Int, at url: URL) throws {
            try append(Record(item: item, trashed: url.path, state: nil).with(done: step))
        }

        /// Records a change of state, and syncs the log.
        func state(_ state: State) throws {
            try append(Record(state: state))
            try lock.withLock { _ in
                guard fsync(descriptor) == 0 else { throw POSIXError.current }
            }
        }

        private func append(_ record: Record) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            var line = try encoder.encode(record)
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
    public func entries() throws -> [Entry] {
        try fileNames().values.sorted().compactMap { name in
            guard let header = try? Self.header(of: folder.appending(path: name + ".batch")) else { return nil }
            let progress = progress(name: name)
            return Entry(
                id: header.id, kind: header.kind, title: header.title,
                created: Date(timeIntervalSince1970: header.created), steps: header.steps, photos: header.photos,
                undoes: header.undoes, state: progress.state, done: progress.done.count,
            )
        }
    }

    /// The batch, and what its log says.
    func load(_ id: UUID) throws -> (batch: FileBatch, progress: Progress) {
        guard let name = try fileNames()[id] else { throw FileOperationError.noSuchBatch(id) }
        let data = try Data(contentsOf: folder.appending(path: name + ".batch"))
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).makeIterator()
        let decoder = JSONDecoder()
        guard let first = lines.next() else { throw FileOperationError.damagedJournal(id) }
        let header = try decoder.decode(Header.self, from: first)
        guard header.version <= Self.version else { throw FileOperationError.newerJournal(id) }
        var steps: [FileStep] = []
        steps.reserveCapacity(header.steps)
        while let line = lines.next() {
            try steps.append(decoder.decode(FileStep.self, from: line))
        }
        guard steps.count == header.steps else { throw FileOperationError.damagedJournal(id) }
        let batch = FileBatch(
            id: header.id, kind: header.kind, title: header.title,
            created: Date(timeIntervalSince1970: header.created), steps: steps, undoes: header.undoes,
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
            if let step = record.done {
                if let item = record.item, let trashed = record.trashed {
                    progress.trashed[step, default: [:]][item] = trashed
                } else {
                    progress.done.insert(step)
                }
                if progress.state == .planned {
                    progress.state = .running
                }
            }
            if let step = record.undone {
                progress.done.remove(step)
            }
            if let state = record.state {
                progress.state = state
            }
        }
        return progress
    }

    /// Batch files' names without their extensions, by batch.
    private func fileNames() throws -> [UUID: String] {
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

    /// Of `entries`, oldest first, the batches Undo reaches: the `kept` newest that are over.
    static func undoable(_ entries: [Entry]) -> ArraySlice<Entry> {
        entries.filter { !$0.state.isUnfinished }.suffix(kept)
    }

    /// Removes the batches that are over but for the `kept` newest, and what interrupted writes left.
    /// An older batch that moved photos to the Trash stays while any of them is still there, or its
    /// Trash can't be reached (`TrashSurvey`), for Put Back; one this build can't read stays too.
    func prune(fileSystem: any LibraryFileSystem) {
        guard let entries = try? entries(), let names = try? fileNames() else { return }
        let older = Array(entries.filter { !$0.state.isUnfinished }.dropLast(Self.kept))
        if !older.isEmpty, let survey = try? TrashSurvey(journal: self, entries: older, fileSystem: fileSystem) {
            for entry in older where !survey.holds(entry.id) {
                guard let name = names[entry.id] else { continue }
                unlink(folder.appending(path: name + ".batch").path)
                unlink(folder.appending(path: name + ".log").path)
            }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.hasPrefix(".") && name.contains(".batch.") {
            unlink(folder.appending(path: name).path)
        }
    }

    // MARK: - Files

    /// `2026-10-05 231000.123 <id>`: names sort as batches were made.
    static func fileName(of batch: FileBatch) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HHmmss.SSS"
        return formatter.string(from: batch.created) + " " + batch.id.uuidString
    }

    static func header(of url: URL) throws -> Header {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.firstIndex(of: 0x0A) == nil, let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
            data.append(chunk)
        }
        let line = data.prefix { $0 != 0x0A }
        return try JSONDecoder().decode(Header.self, from: line)
    }

    /// Writes `data` to a new file and puts it on the disk.
    static func writeSynced(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError.current }
        defer { close(descriptor) }
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
        if fcntl(descriptor, F_FULLFSYNC) != 0 {
            guard fsync(descriptor) == 0 else { throw POSIXError.current }
        }
    }

    /// Puts a folder's entries (a rename into it, say) on the disk.
    static func synchronizeFolder(_ folder: URL) throws {
        let descriptor = open(folder.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError.current }
        defer { close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) != 0 {
            guard fsync(descriptor) == 0 else { throw POSIXError.current }
        }
    }
}

private extension FileJournal.Record {
    init(done: Int) {
        self.init(done: done, undone: nil, item: nil, trashed: nil, state: nil)
    }

    init(undone: Int) {
        self.init(done: nil, undone: undone, item: nil, trashed: nil, state: nil)
    }

    init(state: FileJournal.State) {
        self.init(done: nil, undone: nil, item: nil, trashed: nil, state: state)
    }

    init(item: Int, trashed: String, state: FileJournal.State?) {
        self.init(done: nil, undone: nil, item: item, trashed: trashed, state: state)
    }

    func with(done step: Int) -> Self {
        var record = self
        record.done = step
        return record
    }
}
