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

    @Test func `the IDs a transaction gives are kept beside the index, and one that gives none leaves them`(
    ) async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let marks = sandbox.index.marks
        #expect(marks.url.lastPathComponent == "Index.ids")
        let (ids, during) = try await sandbox.index.write { writer -> ([Int64], Int64?) in
            let folder = try writer.upsertFolder(FolderRecord(root: sandbox.root, path: IndexSandbox.rootPath + "/A"))
            let ids = try writer.upsertPhotos([PhotoRecord(folder: folder, name: "A.JPG")])
            return (ids, marks.read()[IndexIDs.photos.rawValue])
        }
        #expect(during == nil, "written as the transaction ends")
        #expect(marks.read()[IndexIDs.photos.rawValue] == ids.last)
        #expect(marks.read()[IndexIDs.roots.rawValue] == sandbox.root)
        // A transaction that gives none leaves the file as it is.
        let written = try FileManager.default.attributesOfItem(atPath: marks.url.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(20))
        try await sandbox.index.write { try $0.setSetting("1", for: "test.unrelated") }
        #expect(try FileManager.default.attributesOfItem(atPath: marks.url.path)[.modificationDate] as? Date == written)
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
