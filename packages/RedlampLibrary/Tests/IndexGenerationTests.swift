import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// The index's generation, and the journal of what this process's transactions changed (LIB-44).
struct IndexGenerationTests {
    @Test func `every transaction that changes the index bumps its generation with a token of its own`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        func generation() async throws -> IndexGeneration {
            try await sandbox.index.read { try $0.generation() }
        }
        let before = try await generation()
        #expect(before.counter > 0 && before.schema == LibraryIndex.migrations.count, "the sandbox's volume and root")
        _ = try await sandbox.index.write { try $0.setting("test.key") }
        #expect(try await generation() == before, "a transaction that changes nothing")
        try await sandbox.index.write { try $0.setSetting("1", for: "test.key") }
        let after = try await generation()
        #expect(after.counter == before.counter + 1 && after.token != before.token && after.schema == before.schema)
        await #expect(throws: (any Error).self) {
            try await sandbox.index.write { writer in
                try writer.setSetting("2", for: "test.key")
                throw CancellationError()
            }
        }
        #expect(try await generation() == after, "a transaction rolled back")
        try await sandbox.index.write { try $0.setSetting("3", for: "test.key") }
        #expect(try await generation().counter == after.counter + 1)
    }

    @Test func `the journal names the photos and small tables each transaction changed, and nothing across another process's write`(
    ) async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let journal = library.index.journal
        func generation() async throws -> IndexGeneration {
            try await library.index.read { try $0.generation() }
        }
        let ids = library.ids
        let start = try await generation()
        try await library.index.write { try $0.setOrganising([.rating(3)], forPhotos: [ids[0], ids[1]]) }
        let rated = try await generation()
        #expect(journal.changes(after: start, through: rated) == IndexJournal.Changes(photos: [ids[0], ids[1]]))
        try await library.index.write { _ = try $0.addKeyword("Places/Spain", toPhotos: [ids[2]]) }
        let tagged = try await generation()
        #expect(journal.changes(after: rated, through: tagged) == IndexJournal.Changes(photos: [ids[2]], names: true))
        let algarve = try #require(library.folders["2019/Algarve"])
        try await library.index.write { writer in
            try writer.moveFolder(algarve, to: IndexSandbox.rootPath + "/2019/Faro", parent: library.folders["2019"])
        }
        let moved = try await generation()
        #expect(journal.changes(after: start, through: moved) == IndexJournal.Changes(
            photos: [ids[0], ids[1], ids[2]], names: true,
        ))
        #expect(journal.changes(after: moved, through: moved) == IndexJournal.Changes())
        #expect(journal.changes(after: moved, through: start) == nil, "backwards")

        let other = try await LibraryIndex.open(at: library.index.url, readers: 1)
        try await other.write { try $0.setOrganising([.flag(.reject)], forPhotos: [ids[3]]) }
        await other.close()
        try await library.index.write { try $0.setOrganising([.marked(true)], forPhotos: [ids[4]]) }
        let after = try await generation()
        #expect(after.counter == moved.counter + 2)
        #expect(journal.changes(after: moved, through: after) == nil, "another process wrote between")
        var restored = after
        restored.token = moved.token
        #expect(journal.changes(after: start, through: restored) == nil, "another history")
    }
}
