import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// IDs never given twice when the index is lost (LIB-05): an index restored from an older snapshot, or made again
/// from nothing beside the one it replaces, gives none of the IDs given before, so what holds them outside the index
/// (the journals, Undo, the photos waiting for an XMP sync) reaches the photo it meant or none (`IndexIDMarks`).
struct IndexIDMarkTests {
    /// Gives the index a row in each table whose IDs are never given twice, named after `name`: a root with a folder
    /// of two photos, one with a camera, a lens, a keyword and a collection. Returns the IDs it gave, by table.
    static func fill(_ index: LibraryIndex, _ name: String) async throws -> [IndexIDs: Set<Int64>] {
        let before = try await IndexIDTests.ids(index)
        try await index.write { writer in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "TEST-VOLUME", name: "Test", kind: .ssd))
            let root = try writer.upsertRoot(RootRecord(volume: volume, path: "/Volumes/Test/\(name)"))
            let folder = try writer.upsertFolder(FolderRecord(root: root, path: "/Volumes/Test/\(name)/Shoot"))
            let (camera, lens) = try (writer.cameraID(for: "\(name) camera"), writer.lensID(for: "\(name) lens"))
            let photos = try writer.upsertPhotos(["A", "B"].map { stem in
                PhotoRecord(folder: folder, name: "\(stem).JPG", camera: camera, lens: lens, indexed: 1)
            })
            try writer.setKeywords(["\(name) keyword"], forPhoto: photos[0])
            try writer.setCollections(["\(name) collection"], forPhoto: photos[0])
        }
        let after = try await IndexIDTests.ids(index)
        return after.reduce(into: [:]) { given, entry in
            given[entry.key] = entry.value.subtracting(before[entry.key, default: []])
        }
    }

    /// Removes the index's files, as a lost index leaves its folder, but what's kept beside it.
    static func lose(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// Writes over the index's first pages, which then no longer opens.
    static func damage(_ url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        try file.write(contentsOf: Data((0 ..< 8192).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) }))
        try file.close()
    }

    static func expectNoneGivenAgain(
        _ again: [IndexIDs: Set<Int64>], after given: [IndexIDs: Set<Int64>],
        sourceLocation: SourceLocation = #_sourceLocation,
    ) {
        for table in IndexIDs.allCases {
            let (old, new) = (given[table, default: []], again[table, default: []])
            #expect(!old.isEmpty && !new.isEmpty, "\(table)", sourceLocation: sourceLocation)
            #expect(
                new.min() ?? 0 > old.max() ?? 0, "\(table): \(new.sorted()) after \(old.sorted())",
                sourceLocation: sourceLocation,
            )
        }
    }

    @Test func `an index made again from nothing beside the one it replaces gives none of its IDs`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let given = try await Self.fill(sandbox.index, "Before")
        await sandbox.index.close()
        Self.lose(sandbox.url)

        let index = try await LibraryIndex.open(at: sandbox.url, readers: 1)
        defer { index.closeAndWait() }
        #expect(try await index.read { try $0.photoCount() } == 0)
        try await Self.expectNoneGivenAgain(Self.fill(index, "After"), after: given)
    }

    @Test func `an index restored from an older snapshot gives none of the IDs given after it`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        _ = try await Self.fill(sandbox.index, "First")
        let snapshot = try await sandbox.index.snapshot(to: sandbox.snapshots)
        let given = try await Self.fill(sandbox.index, "Second")
        await sandbox.index.close()
        try Self.damage(sandbox.url)

        let (index, outcome) = try await LibraryIndex.openOrRestore(at: sandbox.url, snapshots: sandbox.snapshots)
        defer { index.closeAndWait() }
        #expect(outcome == .restored(from: snapshot))
        try await Self.expectNoneGivenAgain(Self.fill(index, "Third"), after: given)
    }

    /// An index in a folder of its own whose marks come down `settling` after the last write giving IDs; with a
    /// root at `IndexSandbox.rootPath`.
    static func open(
        settling: Duration = .seconds(3600), at existing: URL? = nil,
    ) async throws -> (index: LibraryIndex, root: Int64) {
        let url = existing ?? FileManager.default.temporaryDirectory
            .appending(path: "redlamp-index-marks-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "Index.sqlite")
        let index = try await LibraryIndex.offCaller {
            try LibraryIndex(url: url, readers: 1, migrations: LibraryIndex.migrations, idSettling: settling)
        }
        let root = try await index.write { writer in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "TEST-VOLUME", name: "Test", kind: .ssd))
            return try writer.upsertRoot(RootRecord(volume: volume, path: IndexSandbox.rootPath))
        }
        return (index, root)
    }

    /// Gives `count` photos in a folder of their own named after `name`; their IDs.
    static func give(_ count: Int, _ name: String, in index: LibraryIndex, root: Int64) async throws -> [Int64] {
        try await index.write { writer in
            let folder = try writer.upsertFolder(FolderRecord(root: root, path: IndexSandbox.rootPath + "/" + name))
            return try writer.upsertPhotos((0 ..< count).map { PhotoRecord(folder: folder, name: "\(name) \($0).JPG") })
        }
    }

    static func modified(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    @Test func `a transaction giving an ID past its mark sets the mark a block ahead, and one within the marks writes nothing`(
    ) async throws {
        let (index, root) = try await Self.open()
        defer {
            index.closeAndWait()
            try? FileManager.default.removeItem(at: index.url.deletingLastPathComponent())
        }
        let marks = index.marks
        #expect(marks.url.lastPathComponent == "Index.ids")
        let (ids, during) = try await index.write { writer -> ([Int64], Int64?) in
            let folder = try writer.upsertFolder(FolderRecord(root: root, path: IndexSandbox.rootPath + "/A"))
            let ids = try writer.upsertPhotos([PhotoRecord(folder: folder, name: "A.JPG")])
            return (ids, marks.read()[IndexIDs.photos.rawValue])
        }
        let (photos, roots) = (IndexIDs.photos.rawValue, IndexIDs.roots.rawValue)
        let block = try #require(marks.blocks[photos])
        #expect(block == 65536 && marks.blocks[roots] == 256)
        #expect(during == nil, "written as the transaction ends")
        let last = try #require(ids.last)
        #expect(marks.read()[photos] == last + block)
        #expect(marks.read()[roots] == root + 256)

        // A transaction that gives none, and one whose IDs are within the marks, leave the file as it is.
        let written = try Self.modified(marks.url)
        try await Task.sleep(for: .milliseconds(20))
        try await index.write { try $0.setSetting("1", for: "test.unrelated") }
        let more = try await Self.give(1000, "B", in: index, root: root)
        #expect(try Self.modified(marks.url) == written)
        #expect(marks.read()[photos] == last + block && more.max() ?? .max < last + block)
    }

    @Test func `the marks come down to the last IDs given once none are given for a while, and as the index closes`(
    ) async throws {
        var (index, root) = try await Self.open(settling: .milliseconds(50))
        let url = index.url
        defer {
            index.closeAndWait()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let photos = IndexIDs.photos.rawValue
        let first = try await Self.give(3, "A", in: index, root: root)
        #expect(index.marks.read()[photos] ?? 0 > first.max() ?? 0)
        let deadline = ContinuousClock.now + .seconds(30)
        while index.marks.read()[photos] != first.last, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(index.marks.read()[photos] == first.last, "brought down once the writer was quiet")
        #expect(index.marks.read()[IndexIDs.roots.rawValue] == root)

        let second = try await Self.give(3, "B", in: index, root: root)
        await index.close()
        #expect(index.marks.read()[photos] == second.last, "and as it closed")
        (index, root) = try await Self.open(at: url)
        let third = try await Self.give(1, "C", in: index, root: root)
        #expect(third == [(second.last ?? 0) + 1], "the next open skips none")
    }

    @Test func `an index whose session ended with its marks ahead gives none of its IDs, skipping at most a block`(
    ) async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        _ = try await Self.fill(sandbox.index, "First")
        let snapshot = try await sandbox.index.snapshot(to: sandbox.snapshots)
        let given = try await Self.fill(sandbox.index, "Second")
        // As a crash or a power cut leaves them: the marks a block ahead, the IDs given since not in the file.
        let ahead = try Data(contentsOf: sandbox.index.marks.url)
        await sandbox.index.close()
        try ahead.write(to: sandbox.index.marks.url)
        try Self.damage(sandbox.url)

        let (index, outcome) = try await LibraryIndex.openOrRestore(at: sandbox.url, snapshots: sandbox.snapshots)
        defer { index.closeAndWait() }
        #expect(outcome == .restored(from: snapshot))
        let again = try await Self.fill(index, "Third")
        Self.expectNoneGivenAgain(again, after: given)
        for table in IndexIDs.allCases {
            let skipped = (again[table]?.min() ?? 0) - (given[table]?.max() ?? 0) - 1
            #expect(skipped <= index.marks.blocks[table.rawValue] ?? 0, "\(table): \(skipped) skipped")
        }
    }

    @Test func `an Undo from before the index was made again leaves the photos given its photos' IDs alone`(
    ) async throws {
        let (sandbox, _) = try await IndexIDTests.library()
        defer { sandbox.remove() }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let trip = try await sandbox.ids(["Trip/IMG_0002.JPG", "Trip/Day 2/IMG_0003.JPG"])
        let rated = try await metadata.run(metadata.plan(.each(Dictionary(uniqueKeysWithValues: trip.map {
            ($0, [MetadataField.rating(5)])
        }))))

        // The index lost and made again from the photos, Later's rated 5 too: found after Home, they'd take Trip's
        // IDs from an index that started again from nothing.
        await sandbox.index.close()
        Self.lose(sandbox.index.url)
        let later = ["Later/IMG_0004.JPG", "Later/IMG_0005.JPG"]
        for path in later {
            try sandbox.photo(path, rating: 5)
        }
        let index = try await LibraryIndex.open(at: sandbox.index.url, readers: 1)
        defer { index.closeAndWait() }
        let indexer = LibraryIndexer(index: index, configuration: .testing())
        for root in ["Home", "Later"] {
            let run = await IndexerRun.collect(indexer.index([sandbox.url(root)]))
            #expect(run.failures.isEmpty, "\(run.failures)")
        }
        let paths = later.map { LibraryIndexer.path(sandbox.url($0)) }
        let added = try await index.read { reader in try paths.compactMap { try reader.photo(path: $0)?.id } }
        #expect(added.count == 2 && Set(added).isDisjoint(with: trip), "\(added) and \(trip)")

        try await LibraryMetadata(index: index, paths: sandbox.paths).undo(rated.batch)
        for path in later {
            #expect(sandbox.sidecar(path)?.metadata?.rating == 5, "\(path)'s sidecar")
        }
        let rows = try await index.read { reader in try added.map { try reader.photo(id: $0)?.rating } }
        #expect(rows == [5, 5], "their rows")
    }

    @Test func `a photo put back after the index was made again is in its collections by path, and read again for its camera`(
    ) async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let shoot = IndexSandbox.rootPath + "/Shoot"
        // In Selects, with a camera and a lens, then taken out of the index as a move to the Trash takes it.
        let removed = try await sandbox.index.write { writer -> RemovedPhoto in
            let folder = try writer.upsertFolder(FolderRecord(root: sandbox.root, path: shoot))
            let (camera, lens) = try (writer.cameraID(for: "Nikon Z 8"), writer.lensID(for: "50mm F1.8 S"))
            let photo = try writer.upsertPhotos([
                PhotoRecord(folder: folder, name: "DSC_0001.NEF", camera: camera, lens: lens, indexed: 1),
            ])[0]
            try writer.setCollections(["Selects"], forPhoto: photo)
            let row = try #require(try writer.photo(id: photo))
            let removed = try RemovedPhoto(
                photo: IndexedPhoto(row), folder: shoot, collections: writer.collectionPlaces(ofPhoto: photo),
            )
            try writer.deletePhotos([photo])
            return removed
        }
        await sandbox.index.close()
        IndexIDMarkTests.lose(sandbox.url)

        // Made again: other cameras, lenses and collections found first, which an index starting from nothing
        // would give the photo's IDs.
        let index = try await LibraryIndex.open(at: sandbox.url, readers: 1)
        defer { index.closeAndWait() }
        let restored = try await index.write { writer -> (PhotoRecord?, [String]) in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "TEST-VOLUME", name: "Test", kind: .ssd))
            let root = try writer.upsertRoot(RootRecord(volume: volume, path: IndexSandbox.rootPath))
            let folder = try writer.upsertFolder(FolderRecord(root: root, path: shoot))
            let (camera, lens) = try (writer.cameraID(for: "Canon EOS R5"), writer.lensID(for: "24mm F1.4"))
            let others = try writer.upsertPhotos(["IMG_0001.CR3", "IMG_0002.CR3"].map {
                PhotoRecord(folder: folder, name: $0, camera: camera, lens: lens, indexed: 1)
            })
            try writer.setCollections(["Portfolio"], forPhoto: others[0])
            try writer.setCollections(["Selects"], forPhoto: others[1])
            let id = try writer.restorePhoto(removed, inFolder: folder, name: removed.photo.name)
            return try (writer.photo(id: id), writer.collections(ofPhoto: id).map(\.text))
        }
        #expect(restored.1 == ["Selects"])
        let photo = try #require(restored.0)
        #expect(
            photo.camera == nil && photo.lens == nil,
            "\(String(describing: photo.camera)), \(String(describing: photo.lens))",
        )
        #expect(photo.indexed == 0, "read again")
    }

    @Test func `a sidecar move a quit cut short finishes for its root by path once the index was made again`(
    ) async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        // In the index made again, another root has the ID the journal holds, and the move's root another.
        let archive = "/Volumes/Test/Archive"
        let moved = try await sandbox.index.write { writer in
            try writer.upsertRoot(RootRecord(volume: sandbox.volume, path: archive))
        }
        let sidecars = LibrarySidecars(index: sandbox.index, paths: LibraryPaths(root: sandbox.directory))
        let plan = SidecarMovePlan(
            root: sandbox.root,
            rootPath: archive,
            destination: .onThisMac,
            items: [],
            conflicts: [],
        )
        try JSONEncoder().encode(plan).write(to: sidecars.moveJournal)

        _ = try await sidecars.resumeMove()
        let placements = try await sandbox.index.read { reader in
            try [sandbox.root, moved].map { try reader.root(id: $0)?.sidecars }
        }
        #expect(placements == [.besidePhotos, .onThisMac])
    }
}
