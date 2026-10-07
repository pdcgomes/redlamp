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

    @Test func `a store caught up through the journal answers as one built again, whatever the updates named`(
    ) async throws {
        let library = try await SnapshotLibrary.make(photos: 1500)
        defer { library.remove() }
        let engine = library.engine()
        try await engine.load()
        let ids = library.ids
        let index = library.index
        let rated = Array(ids[10 ..< 40])
        try await index.write { try $0.setOrganising([.rating(4), .label(.blue)], forPhotos: rated) }
        try await index.write { _ = try $0.addKeyword("Events/Festival", toPhotos: Array(ids[100 ..< 130])) }
        try await index.write { _ = try $0.removeKeyword("sunset", fromPhotos: Array(ids[0 ..< 300])) }
        try await index.write { try $0.deletePhotos(Array(ids[500 ..< 520])) }
        let folder = try #require(try await index.read { reader in
            try reader.photo(id: ids[0]).flatMap { photo in try reader.folder(id: photo.folder) }
        })
        let added = try await index.write { writer in
            try writer.upsertPhotos((0 ..< 25).map { number in
                PhotoRecord(
                    folder: folder.id, name: "NEW_\(number).HEIC", captured: Date(timeIntervalSince1970: 1_600_000_000),
                    rating: number % 5, creator: "Nova Pessoa",
                )
            })
        }
        try await index.write { try $0.moveFolder(folder.id, to: folder.path + " Moved", parent: folder.parent) }
        try await index.write { try $0.setOrganising([.flag(.pick)], forPhotos: Array(ids[600 ..< 640])) }
        try await engine.update(photos: rated + Array(ids[500 ..< 520]))
        try await engine.saveSnapshot()
        #expect(try await engine.reflects == (index.read { try $0.generation() }))

        try FileManager.default.removeItem(at: ColumnSnapshot.url(forIndex: index.url))
        let rebuilt = library.engine()
        try await rebuilt.load()
        #expect(!rebuilt.isMapped)
        let queries = SnapshotLibrary.queries + [
            "kw:Festival", "kw:sunset", "creator:Nova", "label:blue", "rating:4", "in:Moved", "flag:pick", "type:heic",
        ]
        for text in queries {
            let query = try LibraryQuery(parsing: text)
            for sort in [QuerySort(), QuerySort(.name), QuerySort(.rating, ascending: false)] {
                let expected = try await rebuilt.results(query, sort: sort).last
                let found = try await engine.results(query, sort: sort).last
                #expect(found?.ids == expected?.ids && found?.count == expected?.count, "\(text), \(sort)")
            }
            for facet in [Facet.camera, .folder, .rating, .label, .creator, .day] {
                let expected = try await SnapshotLibrary.facet(facet, of: query, in: rebuilt)
                #expect(try await SnapshotLibrary.facet(facet, of: query, in: engine) == expected, "\(text), \(facet)")
            }
        }
        #expect(try await rebuilt.ids("kw:Festival").count == 30 && added.count == 25)
    }
}
