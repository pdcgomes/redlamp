import Foundation
import Synchronization

/// The imports' journal, in `LibraryPaths.root/Imports` on the Mac's own disk, kept as the file
/// operations' is (`FileJournal`): each import a file of JSON lines, its header (its settings and
/// sources) and then a photo a line, written to a hidden name, synced and renamed into place before
/// anything is copied. Beside it, its log gets a line as each file is verified at each destination,
/// as each photo is placed, done or failed, and at each change of state, written straight to the file,
/// so a forced quit loses none; `Importer.recover` finishes the import from there.
public struct ImportJournal: Sendable {
    public let folder: URL
    /// Imports kept; older ones that are over are removed.
    public static let kept = 50
    static let version = 1

    public init(paths: LibraryPaths) {
        folder = paths.root.appending(path: "Imports", directoryHint: .isDirectory)
    }

    public enum State: String, Sendable, Hashable, Codable {
        /// Written, nothing copied yet.
        case planned
        /// Copying, or stopped by a forced quit: the next launch finishes it.
        case running
        /// Every photo done, or failed.
        case finished
        /// Cancelled: the photos done so far are in place, the others weren't copied.
        case stopped

        public var isUnfinished: Bool {
            self == .planned || self == .running
        }
    }

    /// An import as the journal lists it.
    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: UUID
        public var title: String
        public var created: Date
        public var photos: Int
        public var state: State
        public var done: Int
        public var failed: Int
    }

    struct Header: Codable {
        var version: Int
        var id: UUID
        var title: String
        var created: Double
        var settings: ImportSettings
        var sources: [ImportPlan.Source]
        var photos: Int
        var folders: [String]
        var counters: NamingCounters
    }

    /// A line of an import's log.
    struct Record: Codable {
        var verified: Int?
        var copy: Int?
        var target: Int?
        var sha256: String?
        var placed: Int?
        var done: Int?
        var failed: Int?
        var message: String?
        var state: State?
    }

    /// What an import's log says.
    struct Progress: Sendable, Hashable {
        var state = State.planned
        /// Each copy's SHA-256 once verified at a target, by photo, copy and target.
        var verified: [Int: [Int: [Int: String]]] = [:]
        var placed = Set<Int>()
        var done = Set<Int>()
        var failed: [Int: String] = [:]
    }

    /// "Import 120 photos from EOS_DIGITAL".
    static func title(of plan: ImportPlan) -> String {
        let count = plan.items.count
        let names = plan.sources.map(\.name).joined(separator: ", ")
        return "Import \(count) photo\(count == 1 ? "" : "s")" + (names.isEmpty ? "" : " from \(names)")
    }

    // MARK: - Writing

    func write(_ plan: ImportPlan) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = Self.fileName(created: plan.created, id: plan.id)
        let header = Header(
            version: Self.version, id: plan.id, title: Self.title(of: plan),
            created: plan.created.timeIntervalSince1970, settings: plan.settings, sources: plan.sources,
            photos: plan.items.count, folders: plan.folders, counters: plan.counters,
        )
        let encoder = Self.encoder
        var data = try encoder.encode(header)
        data.append(0x0A)
        for item in plan.items {
            try data.append(encoder.encode(item))
            data.append(0x0A)
        }
        let staging = folder.appending(path: ".\(name).import.\(UUID().uuidString)")
        try FileJournal.writeSynced(data, to: staging)
        let log = folder.appending(path: name + ".log")
        try FileJournal.writeSynced(Data(), to: log)
        guard rename(staging.path, folder.appending(path: name + ".import").path) == 0 else {
            let error = POSIXError.current
            unlink(staging.path)
            unlink(log.path)
            throw error
        }
        try FileJournal.synchronizeFolder(folder)
    }

    func log(_ id: UUID) throws -> Log {
        guard let name = try fileNames()[id] else { throw ImportError.noSuchImport(id) }
        return try Log(url: folder.appending(path: name + ".log"))
    }

    /// An import's log, open for adding lines.
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

        func verified(_ item: Int, copy: Int, target: Int, sha256: Data) throws {
            try append(Record(verified: item, copy: copy, target: target, sha256: ImportJournal.hex(sha256)))
        }

        func placed(_ item: Int) throws {
            try append(Record(placed: item))
        }

        func done(_ item: Int) throws {
            try append(Record(done: item))
        }

        func failed(_ item: Int, message: String) throws {
            try append(Record(failed: item, message: message))
        }

        /// Records a change of state, and syncs the log.
        func state(_ state: State) throws {
            try append(Record(state: state))
            try lock.withLock { _ in
                guard fsync(descriptor) == 0 else { throw POSIXError.current }
            }
        }

        private func append(_ record: Record) throws {
            var line = try ImportJournal.encoder.encode(record)
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

    /// Every import, oldest first.
    public func entries() throws -> [Entry] {
        try fileNames().values.sorted().compactMap { name in
            guard let header = try? Self.header(of: folder.appending(path: name + ".import")) else { return nil }
            let progress = progress(name: name)
            return Entry(
                id: header.id, title: header.title, created: Date(timeIntervalSince1970: header.created),
                photos: header.photos, state: progress.state, done: progress.done.count, failed: progress.failed.count,
            )
        }
    }

    /// The import's plan, as far as the journal keeps it, and what its log says.
    func load(_ id: UUID) throws -> (plan: ImportPlan, progress: Progress) {
        guard let name = try fileNames()[id] else { throw ImportError.noSuchImport(id) }
        let data = try Data(contentsOf: folder.appending(path: name + ".import"))
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).makeIterator()
        let decoder = JSONDecoder()
        guard let first = lines.next() else { throw ImportError.damagedJournal(id) }
        let header = try decoder.decode(Header.self, from: first)
        guard header.version <= Self.version else { throw ImportError.newerJournal(id) }
        var items: [ImportPlan.Item] = []
        while let line = lines.next() {
            try items.append(decoder.decode(ImportPlan.Item.self, from: line))
        }
        guard items.count == header.photos else { throw ImportError.damagedJournal(id) }
        let plan = ImportPlan(
            id: header.id, created: Date(timeIntervalSince1970: header.created), settings: header.settings,
            sources: header.sources, items: items, folders: header.folders, counters: header.counters,
        )
        return (plan, progress(name: name))
    }

    /// The log's lines played back; a line a forced quit cut short is left out.
    private func progress(name: String) -> Progress {
        var progress = Progress()
        guard let data = try? Data(contentsOf: folder.appending(path: name + ".log")) else { return progress }
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(Record.self, from: line) else { continue }
            if let item = record.verified, let copy = record.copy, let target = record.target, let sha = record.sha256 {
                progress.verified[item, default: [:]][copy, default: [:]][target] = sha
            }
            if let item = record.placed {
                progress.placed.insert(item)
            }
            if let item = record.done {
                progress.done.insert(item)
                progress.failed.removeValue(forKey: item)
            }
            if let item = record.failed {
                progress.failed[item] = record.message ?? ""
            }
            if let state = record.state {
                progress.state = state
            } else if progress.state == .planned {
                progress.state = .running
            }
        }
        return progress
    }

    private func fileNames() throws -> [UUID: String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [:] }
        var found: [UUID: String] = [:]
        for name in names where name.hasSuffix(".import") && !name.hasPrefix(".") {
            let stem = String(name.dropLast(".import".count))
            if let id = stem.split(separator: " ").last.flatMap({ UUID(uuidString: String($0)) }) {
                found[id] = stem
            }
        }
        return found
    }

    /// Removes all but the `kept` newest imports that are over, and what interrupted writes left.
    func prune() {
        guard let entries = try? entries(), let names = try? fileNames() else { return }
        for entry in entries.filter({ !$0.state.isUnfinished }).dropLast(Self.kept) {
            guard let name = names[entry.id] else { continue }
            unlink(folder.appending(path: name + ".import").path)
            unlink(folder.appending(path: name + ".log").path)
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.hasPrefix(".") && name.contains(".import.") {
            unlink(folder.appending(path: name).path)
        }
    }

    // MARK: - Files

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }

    static func fileName(created: Date, id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HHmmss.SSS"
        return formatter.string(from: created) + " " + id.uuidString
    }

    static func header(of url: URL) throws -> Header {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.firstIndex(of: 0x0A) == nil, let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
        }
        return try JSONDecoder().decode(Header.self, from: data.prefix { $0 != 0x0A })
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

public enum ImportError: Error, Sendable, Hashable, CustomStringConvertible {
    case noSuchImport(UUID)
    /// The import's file in the journal can't be read.
    case damagedJournal(UUID)
    /// The import was written by a newer Redlamp.
    case newerJournal(UUID)
    /// An import a forced quit interrupted waits to be finished (`Importer.recover`).
    case unfinished(UUID)

    public var description: String {
        switch self {
        case let .noSuchImport(id): "there's no import \(id.uuidString) in the journal"
        case let .damagedJournal(id): "import \(id.uuidString) can't be read from the journal"
        case let .newerJournal(id): "import \(id.uuidString) was written by a newer Redlamp"
        case let .unfinished(id): "import \(id.uuidString) was interrupted and has to be finished first"
        }
    }
}
