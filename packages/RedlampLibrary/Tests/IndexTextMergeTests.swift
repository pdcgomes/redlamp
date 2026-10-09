import Foundation
import Testing
@testable import RedlampLibrary

/// The text index's merges (LIB-05): no commit merges it, FTS5's automerge being off for every writer; the merges
/// follow the writes, a step at a time, until nothing is left to merge; and a writer writing text without pausing
/// waits for them while a level is crowded with segments (`IndexTextMerges`).
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
