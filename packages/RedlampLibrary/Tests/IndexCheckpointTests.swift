import Foundation
import Testing
@testable import RedlampLibrary

/// The write-ahead log's checkpoints (LIB-05): on a connection of their own, so no write waits for one and the drive
/// flushes in each, and the log still starts again from its beginning, between a sweep's writes or, for a writer that
/// never pauses, once it's long.
struct IndexCheckpointTests {
    /// An index whose log is checkpointed and waited for at `limits`.
    static func open(_ limits: IndexCheckpoints.Limits) async throws -> (index: LibraryIndex, folder: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-checkpoints-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "Index.sqlite")
        let index = try await LibraryIndex.offCaller {
            try LibraryIndex(url: url, readers: 1, migrations: LibraryIndex.migrations, logLimits: limits)
        }
        return (index, folder)
    }

    /// Writes `rows` settings of 900 bytes a transaction, `transactions` times; returns the log's pages after each.
    static func write(transactions: Int, rows: Int = 200, to index: LibraryIndex, settling: Bool = false) async throws
        -> [Int] {
        let filler = String(repeating: "x", count: 900)
        var pages: [Int] = []
        for transaction in 0 ..< transactions {
            try await index.write { writer in
                for row in 0 ..< rows {
                    try writer.setSetting(filler, for: "test.\(transaction).\(row)")
                }
            }
            pages.append(index.logPages)
            if settling {
                await index.settle()
            }
        }
        return pages
    }

    @Test func `the writer's commits leave checkpoints to a connection of their own`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let automatic = try sandbox.index.onWriterAndWait { database in
            try database.prepare("PRAGMA wal_autocheckpoint").first { $0.int(at: 0) }
        }
        // SQLite's own were every 1,000 pages, in the commit that took the log past them.
        #expect(automatic == 0)
    }

    @Test func `a writer that settles between its writes keeps the log short`() async throws {
        let (index, folder) = try await Self.open(.init(threshold: 100_000, settling: 200, limit: 100_000))
        defer {
            index.closeAndWait()
            try? FileManager.default.removeItem(at: folder)
        }
        let pages = try await Self.write(transactions: 30, to: index, settling: true)
        // Each settle past 200 pages let the log be copied whole, and the next write started it again.
        #expect(Self.restarts(pages) > 0, "\(pages)")
        #expect(pages.max() ?? .max < 200 + 2 * Self.longestWrite(pages), "\(pages)")
    }

    /// How often the log started again.
    static func restarts(_ pages: [Int]) -> Int {
        zip(pages, pages.dropFirst()).count { $1 < $0 }
    }

    /// The most pages one write added to the log.
    static func longestWrite(_ pages: [Int]) -> Int {
        zip(pages, pages.dropFirst()).map { $1 - $0 }.max() ?? 0
    }

    @Test func `a writer that never pauses has its log copied and started again once it's long`() async throws {
        let (index, folder) = try await Self.open(.init(threshold: 100_000, settling: 100_000, limit: 300))
        defer {
            index.closeAndWait()
            try? FileManager.default.removeItem(at: folder)
        }
        let pages = try await Self.write(transactions: 30, to: index)
        #expect(Self.restarts(pages) > 0, "\(pages)")
        #expect(pages.max() ?? .max < 300 + 2 * Self.longestWrite(pages), "\(pages)")
    }

    @Test func `the log is checkpointed as each 1,000 pages come, without a write waiting`() async throws {
        let (index, folder) = try await Self.open(.init(threshold: 100, settling: 100_000, limit: 100_000))
        defer {
            index.closeAndWait()
            try? FileManager.default.removeItem(at: folder)
        }
        let written = try await Self.write(transactions: 10, to: index)
        // Once a checkpoint has copied the log whole, the next write starts it again.
        var restarted = false
        for _ in 0 ..< 200 where !restarted {
            try await Task.sleep(for: .milliseconds(10))
            restarted = try await Self.write(transactions: 1, to: index)[0] <= Self.longestWrite([0] + written)
        }
        #expect(restarted)
    }
}
