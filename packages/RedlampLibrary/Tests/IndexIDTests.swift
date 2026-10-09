import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// IDs never given twice (LIB-05): a photo, folder or root the index gains after others have left it gets an ID
/// none of theirs had, so what holds their IDs (Undo, the journals, lists and selections) never reaches it.
struct IndexIDTests {
    /// Home indexed, then Trip, whose photos, folders and root get the largest IDs: those SQLite would give again.
    static func library() async throws -> (sandbox: KeywordSandbox, indexer: LibraryIndexer) {
        let sandbox = try await KeywordSandbox.make()
        try sandbox.photo("Home/IMG_0001.JPG")
        for path in ["Trip/IMG_0002.JPG", "Trip/Day 2/IMG_0003.JPG"] {
            try sandbox.photo(path, rating: 2)
        }
        let indexer = LibraryIndexer(index: sandbox.index, configuration: .testing())
        for root in ["Home", "Trip"] {
            let run = await IndexerRun.collect(indexer.index([sandbox.url(root)]))
            #expect(run.failures.isEmpty, "\(run.failures)")
        }
        return (sandbox, indexer)
    }

    /// The IDs of every photo, folder and root the index has.
    static func ids(_ index: LibraryIndex) async throws -> [IndexIDs: Set<Int64>] {
        try await index.read { reader in
            try IndexIDs.allCases.reduce(into: [:]) { ids, table in
                ids[table] = try Set(reader.database.prepare("SELECT id FROM \(table.rawValue)")
                    .map { $0.int64(at: 0) })
            }
        }
    }

    static func folder(_ path: String, in sandbox: KeywordSandbox) async throws -> FolderRecord {
        let path = LibraryIndexer.path(sandbox.url(path))
        return try #require(try await sandbox.index.read { try $0.folder(path: path) })
    }

    static func root(_ path: String, in sandbox: KeywordSandbox) async throws -> RootRecord {
        let path = LibraryIndexer.path(sandbox.url(path))
        return try #require(try await sandbox.index.read { try $0.root(path: path) })
    }

    /// Takes Trip out of the library, with its rows.
    static func removeTrip(_ sandbox: KeywordSandbox, _ indexer: LibraryIndexer) async throws {
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let roots = LibraryRoots(index: sandbox.index, indexer: indexer, live: LibraryLive(engine: engine))
        try #require(try await roots.remove(sandbox.url("Trip"), keeping: [sandbox.url("Home")]) != nil)
        await roots.swept()
    }

    @Test func `a photo, folder or root added after a folder left the library gets an ID none of its had`(
    ) async throws {
        let (sandbox, indexer) = try await Self.library()
        defer { sandbox.remove() }
        let before = try await Self.ids(sandbox.index)
        try await Self.removeTrip(sandbox, indexer)
        let kept = try await Self.ids(sandbox.index)
        #expect(kept[.photos]?.count == 1 && kept[.roots]?.count == 1)

        for path in ["Later/IMG_0004.JPG", "Later/More/IMG_0005.JPG", "Later/More/IMG_0006.JPG"] {
            try sandbox.photo(path)
        }
        let run = await IndexerRun.collect(indexer.index([sandbox.url("Later")]))
        #expect(run.failures.isEmpty, "\(run.failures)")
        let after = try await Self.ids(sandbox.index)
        for table in [IndexIDs.photos, .folders, .roots] {
            let added = after[table, default: []].subtracting(kept[table, default: []])
            let removed = before[table, default: []].subtracting(kept[table, default: []])
            #expect(!added.isEmpty && !removed.isEmpty, "\(table)")
            #expect(added.min() ?? 0 > removed.max() ?? 0, "\(table): \(added.sorted()) after \(removed.sorted())")
        }
    }

    @Test func `a photo added after the photo with the largest ID left the index gets a larger one`() async throws {
        let (sandbox, _) = try await Self.library()
        defer { sandbox.remove() }
        let last = try await sandbox.id("Trip/Day 2/IMG_0003.JPG")
        #expect(try await Self.ids(sandbox.index)[.photos]?.max() == last)
        try await sandbox.index.write { try $0.deletePhotos([last]) }
        let folder = try await Self.folder("Trip/Day 2", in: sandbox)
        let added = try await sandbox.index.write { writer in
            try writer.upsertPhotos([PhotoRecord(folder: folder.id, name: "IMG_0007.JPG", kind: .jpeg, size: 1)])
        }
        #expect(added.first ?? 0 > last)
    }

    @Test func `an Undo from before a folder left the library leaves the photos added since alone`() async throws {
        let (sandbox, indexer) = try await Self.library()
        defer { sandbox.remove() }
        // Trip's photos rated 5 as culling rates them, in one batch with Undo.
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let trip = try await sandbox.ids(["Trip/IMG_0002.JPG", "Trip/Day 2/IMG_0003.JPG"])
        let rated = try await metadata.run(metadata.plan(.each(Dictionary(uniqueKeysWithValues: trip.map {
            ($0, [MetadataField.rating(5)])
        }))))
        #expect(sandbox.sidecar("Trip/IMG_0002.JPG")?.metadata?.rating == 5)

        // Trip leaves the library, and photos rated 5 too are added after it: SQLite would give them Trip's IDs.
        try await Self.removeTrip(sandbox, indexer)
        let later = ["Later/IMG_0004.JPG", "Later/IMG_0005.JPG"]
        for path in later {
            try sandbox.photo(path, rating: 5)
        }
        let run = await IndexerRun.collect(indexer.index([sandbox.url("Later")]))
        #expect(run.failures.isEmpty, "\(run.failures)")
        let added = try await sandbox.ids(later)
        #expect(Set(added).isDisjoint(with: trip))

        try await metadata.undo(rated.batch)
        for path in later {
            #expect(sandbox.sidecar(path)?.metadata?.rating == 5, "\(path)'s sidecar")
        }
        let rows = try await sandbox.index.read { reader in try added.map { try reader.photo(id: $0)?.rating } }
        #expect(rows == [5, 5], "their rows")
        #expect(sandbox.sidecar("Trip/IMG_0002.JPG")?.metadata?.rating == 5, "out of the library, Trip is left as is")
    }

    @Test func `a root added after one left the library keeps none of what the settings held for the other`(
    ) async throws {
        let (sandbox, indexer) = try await Self.library()
        defer { sandbox.remove() }
        let sidecars = LibrarySidecars(index: sandbox.index, paths: sandbox.paths)
        try await sidecars.choosePlacements()
        let trip = try await Self.root("Trip", in: sandbox)
        let keys = [LibrarySidecars.probedKey(trip.id), LibrarySidecars.pathKey(trip.id)]
        #expect(try await sandbox.index.read { reader in try keys.map(reader.setting) }.contains { $0 != nil })

        try await Self.removeTrip(sandbox, indexer)
        #expect(try await sandbox.index.read { reader in try keys.map(reader.setting) } == [nil, nil])
        try sandbox.photo("Later/IMG_0004.JPG")
        _ = await IndexerRun.collect(indexer.index([sandbox.url("Later")]))
        let later = try await Self.root("Later", in: sandbox)
        #expect(later.id > trip.id)
        // Probed afresh as it's indexed, rather than taken for probed where Trip was; the probe runs beside the
        // indexer's run, which doesn't wait for it.
        var held: String?
        let deadline = ContinuousClock.now + .seconds(30)
        while held == nil, ContinuousClock.now < deadline {
            held = try await sandbox.index.read { try $0.setting(LibrarySidecars.pathKey(later.id)) }
            if held == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        #expect(held?.hasSuffix("/Later") == true, "\(held ?? "none")")
    }

    @Test func `an index that has kept no last ID starts past every photo ID it holds anywhere`() async throws {
        let (sandbox, _) = try await Self.library()
        defer { sandbox.remove() }
        let last = try await sandbox.id("Trip/Day 2/IMG_0003.JPG")
        // As an earlier build leaves it: a hash kept for a photo gone, an XMP merge record of another, no last ID.
        try await sandbox.index.write { writer in
            try writer.database.execute("""
            INSERT INTO photo_hashes (photo, size, modified, content_key, sha256) VALUES (\(last +
                5), 1, 0, x'00', x'00');
            """)
            try writer.setSetting("{}", for: XMPMergeRecord.key(last + 9))
            for table in IndexIDs.allCases {
                try writer.setSetting(nil, for: table.key)
            }
        }
        let folder = try await Self.folder("Home", in: sandbox)
        let added = try await sandbox.index.write { writer in
            try writer.upsertPhotos([PhotoRecord(folder: folder.id, name: "IMG_0008.JPG", kind: .jpeg, size: 1)])
        }
        #expect(added == [last + 10])
        #expect(try await sandbox.index.read { try $0.setting(IndexIDs.photos.key) } == String(last + 10))
    }

    @Test func `a collection or keyword made after the rows with the largest IDs left the index gets a larger ID`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0001.JPG")
        try await sandbox.indexAll()
        let photo = try await sandbox.id("IMG_0001.JPG")
        // Put on the photo and taken off again, their rows removed as batches remove rows nothing holds.
        let (collection, keyword) = try await sandbox.index.write { writer in
            try writer.setCollections(["Clients/Acme"], forPhoto: photo)
            try writer.setKeywords(["Places/Lisbon"], forPhoto: photo)
            let made = try (writer.collectionID(for: kw("Clients/Acme")), writer.keywordID(forPath: "Places/Lisbon"))
            try writer.setCollections([], forPhoto: photo)
            try writer.removeUnusedCollections(within: [kw("Clients/Acme")])
            try writer.setKeywords([], forPhoto: photo)
            try writer.removeUnusedKeywords(within: [kw("Places/Lisbon")])
            return made
        }
        let (newCollection, newKeyword) = try await sandbox.index.write { writer in
            try (writer.collectionID(for: kw("Portfolio")), writer.keywordID(forPath: "Birds"))
        }
        #expect(newCollection > collection)
        #expect(newKeyword > keyword)
    }

    @Test func `a photo put back after its collection left the index isn't put in one made since`() async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        for path in ["IMG_0001.JPG", "IMG_0002.JPG"] {
            try sandbox.photo(path)
        }
        try await sandbox.indexAll()
        let (trashed, other) = try await (sandbox.id("IMG_0001.JPG"), sandbox.id("IMG_0002.JPG"))
        let folder = LibraryIndexer.path(sandbox.root)
        // In Selects alone, then taken out of the index as a move to the Trash takes it, its row as the journal
        // keeps it; Selects goes with its last photo.
        let removed = try await sandbox.index.write { writer -> RemovedPhoto in
            try writer.setCollections(["Selects"], forPhoto: trashed)
            let row = try #require(try writer.photo(id: trashed))
            let removed = try RemovedPhoto(
                photo: IndexedPhoto(row), folder: folder, collections: writer.collectionPlaces(ofPhoto: trashed),
            )
            try writer.deletePhotos([trashed])
            try writer.removeUnusedCollections(within: [kw("Selects")])
            return removed
        }
        // A collection made meanwhile, which SQLite would give Selects' ID.
        try await sandbox.index.write { writer in try writer.setCollections(["Portfolio"], forPhoto: other) }
        let collections = try await sandbox.index.write { writer in
            let folderID = try #require(try writer.folder(path: folder)).id
            let id = try writer.restorePhoto(removed, inFolder: folderID, name: removed.photo.name)
            return try writer.collections(ofPhoto: id)
        }
        #expect(collections.isEmpty, "\(collections.map(\.text))")
    }

    @Test func `a photo put back under an ID the index hasn't given keeps any new photo from it`() async throws {
        let (sandbox, _) = try await Self.library()
        defer { sandbox.remove() }
        // Put back from a journal older than the index, as after it was made again from nothing.
        let home = LibraryIndexer.path(sandbox.url("Home"))
        let row = try #require(try await sandbox.index.read { try $0.photo(path: home + "/IMG_0001.JPG") })
        let folder = try #require(try await sandbox.index.read { try $0.folder(path: home) }).id
        var photo = IndexedPhoto(row)
        photo.id = 1000
        photo.name = "IMG_0009.JPG"
        let (restored, added) = try await sandbox.index.write { [photo] writer in
            let restored = try writer.restorePhoto(
                RemovedPhoto(photo: photo, folder: home), inFolder: folder, name: photo.name,
            )
            try writer.deletePhotos([restored])
            let added = try writer.upsertPhotos([PhotoRecord(folder: folder, name: "IMG_0010.JPG", kind: .jpeg)])
            return (restored, added)
        }
        #expect(restored == 1000)
        #expect(added == [1001])
    }
}
