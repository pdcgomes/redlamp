import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Photos whose files go outside Redlamp (DEC-59): kept as missing with everything decided about them, out of every
/// list but Library Health's Missing check, and found again where their files turn up. Not when Redlamp moved them, a
/// root of theirs is being removed, or their volume is away.
struct MissingPhotoTests {
    static let paths = ["Shoot/IMG_0001.ARW", "Shoot/IMG_0002.ARW", "Shoot/IMG_0003.ARW", "Other/IMG_0100.ARW"]

    /// Three photos in Shoot and one in Other, indexed: the first rated, the first two tagged, each with a sidecar.
    static func library() async throws -> (sandbox: KeywordSandbox, ids: [String: Int64]) {
        let sandbox = try await KeywordSandbox.make()
        try sandbox.photo(paths[0], keywords: ["Places/Lisbon"], rating: 4)
        try sandbox.photo(paths[1], keywords: ["Places/Lisbon"])
        try sandbox.photo(paths[2])
        try sandbox.photo(paths[3])
        try await sandbox.indexAll()
        var ids: [String: Int64] = [:]
        for path in paths {
            ids[path] = try await sandbox.id(path)
        }
        return (sandbox, ids)
    }

    static func row(_ id: Int64, _ sandbox: KeywordSandbox) async throws -> PhotoRecord? {
        try await sandbox.index.read { try $0.photo(id: id) }
    }

    static let portfolio = CollectionPath("Portfolio")!

    @Test func `a photo deleted outside Redlamp keeps its row as missing, with everything decided about it`(
    ) async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let first = try #require(ids[Self.paths[0]])
        try await LibraryMetadata(index: sandbox.index, paths: sandbox.paths).collections
            .apply(.add([first], to: Self.portfolio))
        let before = try #require(await Self.row(first, sandbox))
        let started = Date()
        try FileManager.default.removeItem(at: sandbox.url(Self.paths[0]))
        try await sandbox.indexAll()

        let (keywords, collections) = try await sandbox.index.read { reader in
            try (reader.keywords(forPhoto: first), reader.collections(ofPhoto: first).map(\.text))
        }
        let row = try #require(await Self.row(first, sandbox))
        #expect(row.state == [.missing])
        #expect(row.missingSince.map { $0 >= started.addingTimeInterval(-1) && $0 <= Date() } == true)
        var unmarked = row
        unmarked.state = []
        unmarked.missingSince = nil
        #expect(unmarked == before, "its row as it was")
        #expect(row.rating == 4 && row.edited && keywords == ["Places/Lisbon"] && collections == ["Portfolio"])
    }

    @Test func `missing photos are out of every list, search, count and facet, and only the Missing check lists them`(
    ) async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let photos = try Self.paths.map { try #require(ids[$0]) }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        try await metadata.collections.apply(.add([photos[0], photos[1]], to: Self.portfolio))
        try await metadata.collections.apply(.smart(#require(CollectionPath("Everything")), query: "rating>=0"))
        try FileManager.default.removeItem(at: sandbox.url(Self.paths[0]))
        try await sandbox.indexAll()
        let missing = try #require(await Self.row(photos[0], sandbox))

        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let shoot = sandbox.url("Shoot")
        #expect(try await Set(engine.list(.allPhotographs)) == Set(photos.dropFirst()))
        #expect(try await Set(engine.list(.folder(shoot, includingSubfolders: false))) == [photos[1], photos[2]])
        #expect(try await Set(engine.list(.folder(sandbox.root, includingSubfolders: true))).count == 3)
        #expect(try await Array(engine.list(.collection(Self.portfolio))) == [photos[1]])
        #expect(try await engine.list(.collection(#require(CollectionPath("Everything")))).count == 3)
        #expect(try await sandbox.search("kw:Lisbon") == ["IMG_0002.ARW"])
        #expect(try await sandbox.search("IMG_0001").isEmpty)
        #expect(try await sandbox.search("missing:yes").isEmpty, "only the Missing check lists them")
        #expect(try await engine.photos(named: "IMG_0001").count == 0)
        var total: Int?
        for try await counts in engine.columns([FacetColumnRequest(.folder, query: .all)], in: .allPhotographs) {
            total = counts.total
        }
        #expect(total == 3)
        var faceted = 0
        for try await counts in engine.facets([.folder], for: .all) {
            faceted = counts.values.reduce(0) { $0 + $1.count }
        }
        #expect(faceted == 3)
        let shootPath = LibraryIndexer.path(shoot)
        let (byFolder, keywords, collections, shootID) = try await sandbox.index.read { reader in
            try (
                reader.photoCountsByFolder(), reader.keywordCounts(), reader.collectionCounts(),
                reader.folder(path: shootPath)?.id,
            )
        }
        #expect(try byFolder[#require(shootID)] == 2)
        #expect(keywords[kw("Places/Lisbon")]?.photos == 1 && keywords[kw("Places")]?.count == 1)
        #expect(collections[Self.portfolio] == 1)

        let health = LibraryHealth(
            operations: FileOperations(index: sandbox.index, paths: sandbox.paths),
            engine: engine,
        )
        let found = try await health.findings(.missing)
        #expect(found.photos == [photos[0]] && found.proposed.isEmpty)
        #expect(found.findings.first?.reason == .missing(from: shootPath, since: missing.missingSince))
        #expect(try await Array(engine.list(.health(.missing))) == [photos[0]])
        #expect(try await health.offered().map(\.check).contains(.missing))
        // These files aren't images, so the damaged files check finds them, but the missing one no longer.
        #expect(try await Set(health.findings(.damaged).photos) == Set(photos.dropFirst()))
    }

    @Test func `a photo on a volume that stopped answering is offline, not missing, and missing once it answers`(
    ) async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 40, seed: 31, shapes: []))
        defer { sandbox.remove() }
        let volume = SwitchingFileSystem(SimulatedFileSystem(profile: .ssd, seed: 1))
        let volumes = VolumeIORegistry(fileSystem: volume, configuration: .init(
            timeout: .milliseconds(300), probeIntervals: .milliseconds(100) ... .milliseconds(400),
        ))
        let indexer = LibraryIndexer(index: sandbox.index, volumes: volumes, configuration: .testing())
        _ = await IndexerRun.collect(indexer.index([sandbox.root]))
        let gone = try #require(sandbox.photos(in: sandbox.fixture.folders[0].path).first)
        let path = sandbox.path(gone.path)
        let id = try #require(await sandbox.index.read { try $0.photo(path: path) }?.id)
        try FileManager.default.removeItem(at: sandbox.url(gone))

        let away = VolumeProfile.ssd.disconnecting(.init(.afterOperations(0), failure: .timeout(.seconds(30))))
        volume.switchTo(SimulatedFileSystem(profile: away, seed: 2))
        let offline = await IndexerRun.collect(indexer.index([sandbox.root]))
        #expect(offline.summary?.offlineVolumes.count == 1 && offline.summary?.photosMissing == 0)
        let (state, missing) = try await sandbox.index.read { reader in
            try (reader.photo(id: id)?.state, reader.photoCount(withState: .missing))
        }
        #expect(state == [.offline] && missing == 0)

        volume.switchTo(SimulatedFileSystem(profile: .ssd, seed: 3))
        try await #require(volumes.all.first).waitUntilReachable()
        let back = await IndexerRun.collect(indexer.index([sandbox.root]))
        #expect(back.summary?.photosMissing == 1)
        let (found, offlineCount) = try await sandbox.index.read { reader in
            try (reader.photo(id: id)?.state, reader.photoCount(withState: .offline))
        }
        #expect(found == [.missing] && offlineCount == 0)
    }

    @Test func `a photo Redlamp moved to the Trash is in Recently Trashed, and one the Finder moved there is missing`(
    ) async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let (first, second) = try (#require(ids[Self.paths[0]]), #require(ids[Self.paths[1]]))
        let simulated = SimulatedFileSystem(profile: .ssd)
        simulated.useTrash(sandbox.library.url.appending(path: "Trash", directoryHint: .isDirectory))
        let operations = FileOperations(index: sandbox.index, paths: sandbox.paths, fileSystem: simulated)
        #expect(try await operations.run(operations.planTrash(photos: [first])).isFinished)
        // The Finder's Trash is a folder outside the library's, as this one is.
        let finderTrash = sandbox.library.url.appending(path: "Finder Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: finderTrash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: sandbox.url(Self.paths[1]),
            to: finderTrash.appending(path: "IMG_0002.ARW"),
        )
        try await sandbox.indexAll()

        #expect(try await Self.row(first, sandbox) == nil, "out of the index, as its batch took it")
        #expect(try await operations.trashed().map(\.id.photo) == [first])
        #expect(try await Self.row(second, sandbox)?.state == [.missing])
        #expect(try await sandbox.index.read { try $0.missingPhotoIDs() } == [second])
    }

    @Test func `photos a file batch has unfinished, or of a root being removed, aren't marked missing`() async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let (first, second) = try (#require(ids[Self.paths[0]]), #require(ids[Self.paths[1]]))
        let folder = try #require(await Self.row(first, sandbox)).folder
        let writing = sandbox.index.photoWrites
        let held = try await sandbox.index.write { writer in
            try LibraryIndexer.Batcher.apply([.missing([(first, folder)])], writer, writing: writing, holding: [first])
        }
        #expect(held.missing.isEmpty)

        // A move a forced quit cut short: its photo is held until recovery writes its row.
        let operations = FileOperations(index: sandbox.index, paths: sandbox.paths)
        operations.interruption.withLock { $0 = .afterStep(0) }
        await #expect(throws: FileOperations.ForcedQuit.self) {
            try await operations.run(operations.planMove(photos: [second], to: sandbox.url("Other")))
        }
        let unfinished = await LibraryIndexer.Batcher.held(before: [.missing([(second, folder)])], in: sandbox.index)
        #expect(unfinished == [second])
        #expect(try await FileOperations(index: sandbox.index, paths: sandbox.paths).recover().count == 1)

        let rootPath = LibraryIndexer.path(sandbox.root)
        _ = try await sandbox.index.write { try $0.markRemoved(rootPath, keeping: []) }
        let removing = try await sandbox.index.write { writer in
            try LibraryIndexer.Batcher.apply([.missing([(first, folder)])], writer, writing: writing)
        }
        #expect(removing.missing.isEmpty)
        #expect(try await Self.row(first, sandbox)?.state == [])
    }

    @Test func `a photo found again at its path, or moved back by the Finder, keeps its row`() async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let first = try #require(ids[Self.paths[0]])
        let before = try #require(await Self.row(first, sandbox))
        let outside = try TemporaryFolder()
        let away = outside.url.appending(path: "IMG_0001.ARW")
        try FileManager.default.moveItem(at: sandbox.url(Self.paths[0]), to: away)
        try await sandbox.indexAll()
        #expect(try await Self.row(first, sandbox)?.state == [.missing])

        try FileManager.default.moveItem(at: away, to: sandbox.url(Self.paths[0]))
        try await sandbox.indexAll()
        #expect(try await Self.row(first, sandbox) == before, "found at its path, its row as it was")

        // Out again, then into Other with its sidecar: found by its file identifier.
        try FileManager.default.moveItem(at: sandbox.url(Self.paths[0]), to: away)
        try await sandbox.indexAll()
        try FileManager.default.moveItem(at: away, to: sandbox.url("Other/IMG_0001.ARW"))
        try FileManager.default.moveItem(
            at: sandbox.url(Self.paths[0] + ".redlamp"), to: sandbox.url("Other/IMG_0001.ARW.redlamp"),
        )
        try await sandbox.indexAll()
        let moved = try #require(await Self.row(first, sandbox))
        let otherPath = LibraryIndexer.path(sandbox.url("Other"))
        let other = try await sandbox.index.read { try $0.folder(path: otherPath)?.id }
        #expect(moved.folder == other && moved.state.isEmpty && moved.missingSince == nil && moved.rating == 4)
        #expect(try await sandbox.index.read { try $0.missingPhotoIDs() }.isEmpty)
    }

    @Test func `a folder deleted outside Redlamp keeps its photos as missing, found again when it comes back`(
    ) async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let shoot = try Self.paths.prefix(3).map { try #require(ids[$0]) }
        let outside = try TemporaryFolder()
        try FileManager.default.moveItem(at: sandbox.url("Shoot"), to: outside.url.appending(path: "Shoot"))
        try await sandbox.indexAll()
        #expect(try await sandbox.index.read { try $0.missingPhotoIDs() } == Set(shoot))
        let shootPath = LibraryIndexer.path(sandbox.url("Shoot"))
        #expect(try await sandbox.index.read { try $0.folder(path: shootPath) } != nil, "kept for where they were")

        try FileManager.default.moveItem(at: outside.url.appending(path: "Shoot"), to: sandbox.url("Shoot"))
        try await sandbox.indexAll()
        #expect(try await sandbox.index.read { try $0.missingPhotoIDs() }.isEmpty)
        #expect(try await sandbox.ids(Array(Self.paths.prefix(3))) == shoot)
    }
}
