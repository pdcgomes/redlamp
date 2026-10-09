import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampLibrary

/// The library's own changes against what change tracking read before them (LIB-07): a batch changes a photo's
/// keywords, collections, or rating and label while the indexer holds an older read of it, and the read is written
/// once the batch has given the index the photo's fields and its sidecar, before it records the sidecar's date. The
/// batch's change stands, and what other apps wrote meanwhile, in the photo's `.xmp` and in its `.redlamp`, which the
/// batch kept, reaches the index too.
struct IndexerStaleReadTests {
    enum Change: String, CaseIterable, Sendable {
        case keyword, collection, ratingAndLabel

        static let lisbon = KeywordPath("Places/Lisbon")!
        static let selects = CollectionPath("Selects")!

        /// Makes the change to `photo` through the library, calling `progress` as each sidecar is written.
        func run(on photo: Int64, in sandbox: HealthSandbox, progress: @escaping @Sendable (Int, Int) -> Void)
            async throws {
            let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
            switch self {
            case .keyword:
                let keywords = LibraryKeywords(index: sandbox.index, paths: sandbox.paths)
                try await keywords.run(keywords.plan(.add([Self.lisbon], to: [photo])), progress: progress)
            case .collection:
                try await metadata.run(metadata.collections.plan(.add([photo], to: Self.selects)), progress: progress)
            case .ratingAndLabel:
                try await metadata.run(metadata.plan(.set([.rating(4), .label(.red)], on: [photo])), progress: progress)
            }
        }

        func applied(to shown: Shown) -> Shown {
            var shown = shown
            switch self {
            case .keyword: shown.keywords.insert(Self.lisbon)
            case .collection: shown.collections.insert(Self.selects)
            case .ratingAndLabel: (shown.rating, shown.label) = (4, .red)
            }
            return shown
        }
    }

    /// What the index shows of a photo.
    struct Shown: Equatable {
        var rating = 0
        var label: ColorLabel?
        var title: String?
        var caption: String?
        var keywords: Set<KeywordPath> = []
        var collections: Set<CollectionPath> = []

        static func of(_ photo: Int64, in index: LibraryIndex) async throws -> Shown? {
            try await index.read { reader in
                guard let row = try reader.photo(id: photo) else { return nil }
                return try Shown(
                    rating: row.rating, label: row.label, title: row.title, caption: row.caption,
                    keywords: Set(reader.keywordPaths(ofPhotos: [photo])[photo] ?? []),
                    collections: Set(reader.collections(ofPhoto: photo)),
                )
            }
        }
    }

    static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test(arguments: Change.allCases)
    func `a batch's change stands over what the indexer read before it, and another app's change comes in`(
        change: Change,
    ) async throws {
        let sandbox = try await HealthSandbox.make(["A.JPG": HealthImages.longJPEG])
        defer { sandbox.remove() }
        try sandbox.sidecar("A.JPG", PhotoMetadata(rating: 1))
        try #require(await sandbox.index().failures.isEmpty)
        let photo = try #require(try await sandbox.rows()["A.JPG"]?.id)
        let before = try #require(try await Shown.of(photo, in: sandbox.index))
        // Another Mac gives the photo a caption in its `.redlamp`, and another app a title in its `.xmp`: what change
        // tracking lists next.
        try SidecarStore().save(
            Sidecar(
                recipe: EditRecipe(),
                metadata: PhotoMetadata(rating: 1, caption: "Seen from Graça"),
                modified: Date(),
            ),
            for: sandbox.url("A.JPG"),
        )
        try Data(XMPIndexTests.packet("", XMPIndexTests.alt("dc:title", "Tram 28")).utf8)
            .write(to: sandbox.url("A.xmp"))

        // The run's read of the photo waits to be written while the run reads the photo's end.
        let files = PausingFileSystem(LocalFileSystem())
        let indexer = LibraryIndexer(
            index: sandbox.index, fileSystem: files,
            configuration: LibraryIndexer.Configuration(batchSize: 1000, batchInterval: .seconds(60)),
        )
        let read = files.pause(reading: LibraryIndexer.path(sandbox.url("A.JPG")))
        let indexed = Signal()
        let indexing = Task {
            let run = await IndexerRun.collect(indexer.update([FolderChange(sandbox.root)]))
            indexed.fire()
            return run
        }
        try await Self.until { read.reached.fired }
        try #require(read.reached.fired, "the run read the photo")

        // The batch gives the index the photo's fields, writes its sidecar, and is held there.
        let written = PausingFileSystem.Pause("the photo's sidecar written")
        let changing = Task { try await change.run(on: photo, in: sandbox) { _, _ in written.hold() } }
        try await Self.until { written.reached.fired }
        try #require(written.reached.fired, "the batch wrote the photo's sidecar")
        read.release()
        // The run writes what it read, unless it waits for the batch to be done to read the photo again.
        try await Self.until { indexed.fired || sandbox.index.photoWrites.waiting > 0 }
        written.release()
        try await changing.value
        let run = await indexing.value
        #expect(run.failures.isEmpty, "\(run.failures)")

        var expected = change.applied(to: before)
        (expected.title, expected.caption) = ("Tram 28", "Seen from Graça")
        let after = try await Shown.of(photo, in: sandbox.index)
        #expect(after == expected, "the batch's change and the other apps', before \(before)")
        let again = await IndexerRun.collect(
            LibraryIndexer(index: sandbox.index, configuration: .testing()).update([FolderChange(sandbox.root)]),
        )
        #expect(again.summary?.photosUpdated == 0, "the next listing finds the photo as it is")
    }

    @Test func `a read of a photo the library is writing, or has changed since its listing, isn't written`(
    ) async throws {
        let sandbox = try await HealthSandbox.make(["A.JPG": HealthImages.data(.jpeg, seed: 1)])
        defer { sandbox.remove() }
        try #require(await sandbox.index().failures.isEmpty)
        let row = try #require(try await sandbox.rows()["A.JPG"])
        let folder = LibraryIndexer.path(sandbox.root)
        let writes = sandbox.index.photoWrites
        var read = row
        read.rating = 5
        func written(listed: PhotoRecord) async throws -> LibraryIndexer.Batcher.Outcome {
            var photo = LibraryIndexer.PendingPhoto(folder: folder, record: read, isNew: false)
            photo.listed = listed
            let item = LibraryIndexer.Batcher.Item.photo(photo)
            return try await sandbox.index.write { try LibraryIndexer.Batcher.apply([item], $0, writing: writes) }
        }

        let writing = writes.begin([row.id])
        var outcome = try await written(listed: row)
        #expect(outcome.stale.map(\.photo) == [row.id] && outcome.updated.isEmpty, "while a batch writes it")
        writing.end()
        var earlier = row
        earlier.sidecarModified = Date(timeIntervalSince1970: 1_700_000_000)
        outcome = try await written(listed: earlier)
        #expect(outcome.stale.map(\.photo) == [row.id] && outcome.updated.isEmpty, "changed since its listing")
        #expect(try await sandbox.rows()["A.JPG"] == row)

        outcome = try await written(listed: row)
        #expect(outcome.stale.isEmpty && outcome.updated == [row.id], "as its listing found it")
        #expect(try await sandbox.rows()["A.JPG"]?.rating == 5)
    }

    @Test func `the metadata and keyword batches hold their photos as written until their sidecars' dates are in`(
    ) async throws {
        let sandbox = try await HealthSandbox.make(["A.JPG": HealthImages.data(.jpeg, seed: 1)])
        defer { sandbox.remove() }
        try sandbox.sidecar("A.JPG", PhotoMetadata(rating: 1))
        try #require(await sandbox.index().failures.isEmpty)
        let photo = try #require(try await sandbox.rows()["A.JPG"]?.id)
        let writes = sandbox.index.photoWrites
        let seen = Mutex<[Change: Bool]>([:])
        for change in Change.allCases {
            try await change.run(on: photo, in: sandbox) { _, _ in
                seen.withLock { $0[change] = writes.isWriting(photo) }
            }
        }
        #expect(seen.withLock { $0 } == [.keyword: true, .collection: true, .ratingAndLabel: true])
        #expect(!writes.isWriting(photo), "let go once each is done")
    }
}
