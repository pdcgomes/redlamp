import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

struct LibraryLiveTests {
    /// The next update, checking that its diff applied to `list` gives its list.
    private static func next(
        _ iterator: inout PhotoListUpdates.Iterator, after list: PhotoList,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) async throws -> PhotoListUpdate {
        let update = try #require(await iterator.next(), sourceLocation: sourceLocation)
        var ids = Array(list.ids)
        update.diff.apply(to: &ids) { update.list[$0] }
        #expect(ids == Array(update.list.ids), "the diff doesn't give the list", sourceLocation: sourceLocation)
        return update
    }

    @Test func `a burst of ten thousand of the indexer's events makes a diff or two, not one each`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let live = LibraryLive(engine: engine, configuration: .init(latency: .milliseconds(250)))
        let updates = live.open(.allPhotographs)
        var iterator = updates.makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first.diff.reset && first.list.count == 8)

        let studio = try #require(library.folders["2024/Studio"])
        let added = try await library.index.write { writer in
            try writer.upsertPhotos((0 ..< 10000).map { number in
                PhotoRecord(
                    folder: studio, name: "BURST_\(number).JPG",
                    captured: QueryTestLibrary.date(2020, 1, 1).addingTimeInterval(Double(number * 37 % 10000)),
                )
            })
        }
        for id in added {
            live.receive(.photosInserted([id]))
        }
        live.receive(.folderIndexed(FolderIndexed(path: IndexSandbox.rootPath + "/2024/Studio", inserted: 10000)))

        var list = first.list
        var diffs = 0
        while list.count < 10008 {
            list = try await Self.next(&iterator, after: list).list
            diffs += 1
        }
        #expect(diffs <= 2, "\(diffs) diffs")
        #expect(Set(list.ids) == Set(library.ids + added))
        updates.close()
        #expect(await iterator.next() == nil)
    }

    @Test func `lists follow photos changed, added and removed, each with the diff it needs`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let live = LibraryLive(engine: engine, configuration: .init(latency: .seconds(60)))
        let ids = library.ids
        var rated = live.open(.allPhotographs, sort: QuerySort(.rating, ascending: false)).makeAsyncIterator()
        let algarve = URL(fileURLWithPath: IndexSandbox.rootPath + "/2019/Algarve", isDirectory: true)
        var folder = live.open(.folder(algarve, includingSubfolders: false)).makeAsyncIterator()
        let ratedFirst = try #require(await rated.next())
        let folderFirst = try #require(await folder.next())
        #expect(library.numbers(ratedFirst.list) == [1, 5, 2, 6, 4, 3, 8, 7])
        #expect(library.numbers(folderFirst.list) == [5, 8])

        // A rating changed in the studio: the rated list moves the photo, the folder has nothing to do.
        try await library.index.write { try $0.setOrganising([.rating(5)], forPhotos: [ids[2]]) }
        live.photosChanged([ids[2]])
        await live.settle()
        let moved = try await Self.next(&rated, after: ratedFirst.list)
        #expect(library.numbers(moved.list) == [3, 1, 5, 2, 6, 4, 8, 7])
        #expect(moved.diff == PhotoListDiff(moved: [PhotoListDiff.Move(from: 5, to: 0)]))

        // A photo of the folder removed: each list loses it, the folder's first change since it was shown.
        try await library.index.write { try $0.deletePhotos([ids[4]]) }
        live.receive(.photosRemoved([ids[4]]))
        await live.settle()
        let shrunk = try await Self.next(&rated, after: moved.list)
        #expect(shrunk.diff == PhotoListDiff(removed: [2]))
        let left = try await Self.next(&folder, after: folderFirst.list)
        #expect(library.numbers(left.list) == [8] && left.diff == PhotoListDiff(removed: [0]))
    }

    @Test func `a view that falls behind takes one update, from the list it took last`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let live = LibraryLive(engine: engine, configuration: .init(latency: .seconds(60)))
        let ids = library.ids
        var iterator = live.open(.allPhotographs).makeAsyncIterator()
        let first = try #require(await iterator.next())
        let studio = try #require(library.folders["2024/Studio"])

        let added = try await library.index.write { writer in
            try writer.upsertPhotos([PhotoRecord(folder: studio, name: "LATE.JPG", captured: QueryTestLibrary.now)])
        }
        live.receive(.photosInserted(added))
        await live.settle()
        try await library.index.write { try $0.deletePhotos([ids[0], ids[1]]) }
        live.receive(.photosRemoved([ids[0], ids[1]]))
        await live.settle()

        let caughtUp = try await Self.next(&iterator, after: first.list)
        #expect(Set(caughtUp.list.ids) == Set(ids.dropFirst(2) + added))
        #expect(caughtUp.diff.removed.count == 2 && caughtUp.diff.inserted.count == 1)
        live.photosChanged([ids[5]])
        await live.settle()
        let updated = try await Self.next(&iterator, after: caughtUp.list)
        #expect(try updated.diff == PhotoListDiff(updated: [#require(caughtUp.list.index(of: ids[5]))]))
    }

    @Test func `change tracking's events reach the lists, and the rest are let by`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let live = LibraryLive(engine: engine, configuration: .init(latency: .milliseconds(20)))
        var iterator = live.open(.rejected).makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(library.numbers(first.list) == [3])
        live.receive(ChangeTracker.Event.replayed(volume: "TEST-VOLUME", folders: 3))
        live.receive(ChangeTracker.Event.indexer(.volumeOffline("TEST-VOLUME")))
        try await library.index.write { try $0.setOrganising([.flag(.reject)], forPhotos: [library.ids[7]]) }
        live.receive(ChangeTracker.Event.indexer(.photosUpdated([library.ids[7]])))
        let rejected = try await Self.next(&iterator, after: first.list)
        #expect(library.numbers(rejected.list) == [8, 3] && rejected.diff == PhotoListDiff(inserted: [0]))
    }

    @Test func `a list kept by the indexer's own events ends with every photo of the fixture`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 400, seed: 43))
        defer { sandbox.remove() }
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let live = LibraryLive(engine: engine, configuration: .init(latency: .milliseconds(50)))
        let rootFolder = URL(fileURLWithPath: sandbox.rootPath, isDirectory: true)
        let updates = live.open(.folder(rootFolder, includingSubfolders: true), sort: QuerySort(.name))
        var iterator = updates.makeAsyncIterator()
        var list = try #require(await iterator.next()).list
        #expect(list.isEmpty)

        let indexer = LibraryIndexer(index: sandbox.index, configuration: .testing(batchSize: 25))
        var events = 0
        for await event in indexer.index([sandbox.root]) {
            live.receive(event)
            events += 1
        }
        await live.settle()
        var diffs = 0
        while list.count < sandbox.manifest.totals.photos {
            list = try await Self.next(&iterator, after: list).list
            diffs += 1
        }
        #expect(list.count == sandbox.manifest.totals.photos && diffs < events)
        let all = try await engine.list(.allPhotographs, sort: QuerySort(.name))
        #expect(list.ids == all.ids)
        updates.close()
    }
}
