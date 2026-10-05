import CoreGraphics
import Foundation
import RedlampDocument
import Synchronization
import Testing
@testable import RedlampLibrary

/// The thumbnail maker stores each photo's grid tier under its content key, as the indexer reads
/// the photo.
struct PhotoStoreThumbnailMakerTests {
    static let raw = PhotoMetadataReaderTests.root.appending(path: "tests/fixtures/raw/_DSC0009.ARW")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: raw.path)))
    func `the thumbnail maker stores a fixture photo's grid tier`() throws {
        let folder = try TemporaryFolder()
        let store = PhotoStore(root: folder.url)
        let (head, size) = try PhotoMetadataReaderTests.head(of: Self.raw)
        let key = ContentKey(fileSize: size, head: head)
        #expect(StoreThumbnailMaker(store: store).make(Self.raw, key: key, head: head))

        let file = try LocalFileSystem().attributes(of: Self.raw)
        let data = try #require(store.data(for: key, tier: .grid, size: file.size, modified: file.modified))
        #expect(Array(data.prefix(2)) == [0xFF, 0xD8])
        let image = try #require(StoreImageEncoder.decode(data))
        let reference = try #require(StoreThumbnailMaker.imageIO(Self.raw, nil, PhotoStore.Tier.grid.pixelSize))
        #expect(max(image.width, image.height) == 384)
        #expect(image.width == reference.width && image.height == reference.height)
        #expect(!store.contains(key, tier: .preview))
    }

    @Test func `an injected image source is used, and a photo the store has isn't made again`() throws {
        let folder = try TemporaryFolder()
        let store = PhotoStore(root: folder.url.appending(path: "Store"))
        let photo = folder.url.appending(path: "IMG_0001.DNG")
        try Data(repeating: 9, count: 40000).write(to: photo)
        let made = StoreTestCalls()
        let maker = StoreThumbnailMaker(store: store) { _, bytes, maxPixelSize in
            made.bytes.withLock { $0.append(bytes?.count ?? -1) }
            return maxPixelSize == 384 ? StoreImageEncoderTests.marked(1000, 500) : nil
        }
        let head = try Data(contentsOf: photo)
        let key = ContentKey(fileSize: head.count, head: head)
        #expect(maker.make(photo, key: key, head: head))
        #expect(maker.make(photo, key: key, head: head))
        #expect(made.recorded == [40000])
        let image = try #require(store.data(for: key, tier: .grid).flatMap(StoreImageEncoder.decode))
        #expect(image.width == 384 && image.height == 192)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)],
            ofItemAtPath: photo.path,
        )
        #expect(maker.make(photo, key: key, head: head.prefix(1000)))
        #expect(made.recorded == [40000, -1])
        #expect(!StoreThumbnailMaker(store: store, tier: .preview, image: { _, _, _ in nil })
            .make(photo, key: key, head: head))
    }

    @Test func `the indexer stores each photo's grid tier through the maker`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 60, seed: 31))
        defer { sandbox.remove() }
        let folder = try TemporaryFolder()
        let store = PhotoStore(root: folder.url)
        let maker = StoreThumbnailMaker(store: store)
        let made = StoreTestCalls()
        let scheduler = WorkScheduler(
            widths: .init(onScreen: 4, lookAhead: 2, background: 4), canRunBackground: { true },
        )
        let indexer = LibraryIndexer(
            index: sandbox.index, scheduler: scheduler, configuration: .testing(),
            thumbnails: { photo, key, head in
                maker.make(photo, key: key, head: head)
                made.count.add(1, ordering: .relaxed)
            },
        )
        let run = await IndexerRun.collect(indexer.index([sandbox.root]))
        #expect(run.failures.isEmpty && run.summary?.photosInserted == 60)
        let deadline = ContinuousClock.now + .seconds(60)
        while made.count.load(ordering: .relaxed) < 60, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(made.count.load(ordering: .relaxed) == 60)

        let rows = try await LibraryIndexerTests.rows(sandbox)
        #expect(rows.count == 60)
        for (path, row) in rows {
            let key = try #require(row.contentKey.flatMap(ContentKey.init(data:)), "\(path)")
            let image = try #require(store.data(for: key, tier: .grid).flatMap(StoreImageEncoder.decode), "\(path)")
            let reference = try #require(
                StoreThumbnailMaker.imageIO(URL(fileURLWithPath: path), nil, PhotoStore.Tier.grid.pixelSize),
            )
            #expect(image.width == reference.width && image.height == reference.height, "\(path)")
        }
    }
}

/// What the closures a maker or indexer keeps were called with.
final class StoreTestCalls: Sendable {
    let bytes = Mutex<[Int]>([])
    let count = Atomic(0)

    /// The length of the bytes each call was given, -1 for none.
    var recorded: [Int] {
        bytes.withLock { $0 }
    }
}
