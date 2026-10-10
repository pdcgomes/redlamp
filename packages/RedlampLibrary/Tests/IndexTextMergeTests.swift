import Foundation
import Synchronization
import Testing
@testable import RedlampLibrary

/// The text index's merges (LIB-05): no commit merges it, FTS5's automerge being off for every writer; the merges
/// follow the writes, a step at a time, until nothing is left to merge; and a writer writing text without pausing
/// waits for them while a level is crowded with segments (`IndexTextMerges`), what each transaction left taken in the
/// order the transactions ran.
struct IndexTextMergeTests {
    /// `count` transactions of `photos` photos each in a folder of their own, named after `name`; their IDs.
    static func write(
        _ count: Int, of photos: Int, _ name: String, to sandbox: IndexSandbox,
        after: (TextIndexStructure) -> Void = { _ in },
    ) async throws -> [Int64] {
        let folder = try #require(try await sandbox.addFolders([name])[name])
        var ids: [Int64] = []
        for transaction in 0 ..< count {
            try await ids += sandbox.upsert((0 ..< photos).map {
                PhotoRecord(
                    folder: folder,
                    name: "\(name) \(transaction * photos + $0).JPG",
                    caption: "harbour at dusk",
                )
            })
            try after(#require(try await sandbox.index.textStructure()))
        }
        return ids
    }

    @Test func `no commit merges the text index, a keyword batch's deletions or not`() async throws {
        let sandbox = try await IndexSandbox.make(textMerges: IndexTextMerges.Limits(following: false))
        defer { sandbox.remove() }
        let ids = try await Self.write(6, of: 20, "Shoot", to: sandbox)
        // FTS5's automerge would have merged four segments in the commit of the fourth.
        #expect(try await sandbox.index.textStructure()?.levels.map(\.segments) == [6])

        // A keyword on every photo: each one's text deleted and written again, in one transaction.
        let gained = try await sandbox.index.write { try $0.addKeyword("Places/Lisbon", toPhotos: ids) }
        #expect(gained == ids.count)
        #expect(try await sandbox.index.textStructure()?.levels.map(\.segments) == [7])
        let (found, automerge) = try await sandbox.index.read { reader in
            try (
                reader.photoIDs(matching: "lisbon"),
                reader.database.prepare("SELECT v FROM photo_text_config WHERE k = 'automerge'")
                    .first { $0.int(at: 0) },
            )
        }
        #expect(found.sorted() == ids)
        #expect(automerge == 0)
    }

    @Test func `the merges follow the writes a step at a time, until nothing is left to merge`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let ids = try await Self.write(24, of: 20, "Shoot", to: sandbox)
        await sandbox.index.mergeText()
        let structure = try #require(try await sandbox.index.textStructure())
        // FTS5's usermerge: a level of four segments is merged into the next.
        #expect(structure.levels.allSatisfy { $0.segments < 4 && $0.merging == 0 }, "\(structure.levels)")
        #expect(structure.segments < 6, "\(structure.levels)")
        let merged = try await sandbox.index.write { try $0.mergeText(pages: 16) }
        #expect(!merged, "nothing left to merge")
        #expect(try await sandbox.index.read { try $0.photoIDs(matching: "harbour") }.sorted() == ids)
    }

    @Test func `a writer writing text without pausing waits for the merges while a level is crowded`() async throws {
        /// Writes of 400 photos each, merged a page a step: a step or two after each write would fall ever further
        /// behind, and each write returns once no level holds `crowded` segments.
        func run(crowded: Int) async throws -> [Int] {
            let limits = IndexTextMerges.Limits(step: .zero, pages: 1, crowded: crowded)
            let sandbox = try await IndexSandbox.make(textMerges: limits)
            defer { sandbox.remove() }
            var firstLevel: [Int] = []
            let ids = try await Self.write(40, of: 400, "Shoot", to: sandbox) {
                firstLevel.append($0.levels[0].segments)
            }
            await sandbox.index.mergeText()
            #expect(try await sandbox.index.read { try $0.photoIDs(matching: "harbour") }.count == ids.count)
            return firstLevel
        }
        let waiting = try await run(crowded: 6)
        #expect(waiting.max() ?? .max < 6, "\(waiting)")
        // Without the waits the first level fills towards the 16 at which FTS5 merges it whole in a commit.
        let unbounded = try await run(crowded: .max)
        #expect(unbounded.max() ?? 0 >= 8, "\(unbounded)")
    }

    /// Whether a write waiting for the merges has returned.
    private final class Returned: Sendable {
        let value = Mutex(false)
    }

    @Test func `what a step left is taken only if no later transaction's has been, so a write waits on its own segment`(
    ) async throws {
        let merges = IndexTextMerges(limits: IndexTextMerges.Limits(crowded: 6))
        func first(_ segments: Int, merging: Int = 0) -> TextIndexStructure {
            TextIndexStructure(levels: [.init(segments: segments, merging: merging)])
        }
        #expect(merges.begin(), "the merges start")
        // A step runs on the writer's queue, then a write whose segment crowds the first level, and the write's caller
        // comes back before the step's: what the step left is older than the write's.
        let (step, write) = (merges.numbered(), merges.numbered())
        let wrote = merges.wrote(first(6, merging: 4), number: write)
        #expect(!wrote.start && wrote.wait)
        let returned = Returned()
        let waiting = Task {
            await merges.caughtUp()
            returned.value.withLock { $0 = true }
        }
        #expect(merges.stepped(16, leaving: first(5, merging: 4), number: step), "the merge under way goes on")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!returned.value.withLock { $0 }, "the write still waits for its own segment to be merged")
        let merged = TextIndexStructure(levels: [.init(segments: 2, merging: 0), .init(segments: 1, merging: 0)])
        #expect(merges.stepped(16, leaving: merged, number: merges.numbered()))
        await waiting.value
        #expect(returned.value.withLock { $0 }, "the next step's leaves no level crowded")

        // The merges' last step found nothing to merge, before a write whose caller came back first: they go on.
        let (last, next) = (merges.numbered(), merges.numbered())
        #expect(!merges.wrote(first(3), number: next).start, "the merges are running")
        #expect(merges.stepped(0, leaving: first(2), number: last), "the write's text may be left to merge")
        #expect(!merges.stepped(0, leaving: first(3), number: merges.numbered()), "nothing left to merge")
        await merges.finished()
    }

    @Test func `the structure is read as FTS5 writes it, levels and segments being merged`() async throws {
        let sandbox = try await IndexSandbox.make(textMerges: IndexTextMerges.Limits(following: false))
        defer { sandbox.remove() }
        _ = try await Self.write(5, of: 200, "Shoot", to: sandbox)
        #expect(try await sandbox.index.textStructure() == TextIndexStructure(levels: [.init(segments: 5, merging: 0)]))
        // One step of a merge of the five, left under way.
        _ = try await sandbox.index.write { try $0.mergeText(pages: 1) }
        let structure = try #require(try await sandbox.index.textStructure())
        #expect(structure.levels.first == .init(segments: 5, merging: 5), "\(structure.levels)")
        #expect(structure.levels.count == 2 && structure.levels[1].segments == 1, "\(structure.levels)")
        #expect(TextIndexStructure(Data([0, 0, 0, 1, 0xFF, 0, 0, 1, 0x05])) == nil, "a record cut short")
    }
}
