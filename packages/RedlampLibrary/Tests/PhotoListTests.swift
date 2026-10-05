import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

struct PhotoListTests {
    /// The folder of `QueryTestLibrary` at `path` below its root.
    private static func folder(_ path: String) -> URL {
        URL(fileURLWithPath: IndexSandbox.rootPath + "/" + path, isDirectory: true)
    }

    @Test func `a list holds its source's photos in each sort's order, both ways`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        for key in QuerySort.Key.allCases {
            for ascending in [true, false] {
                let sort = QuerySort(key, ascending: ascending)
                let list = try await engine.list(.allPhotographs, sort: sort)
                #expect(try await Array(list.ids) == (engine.ids("", sort: sort)), "\(key) \(ascending)")
                #expect(list.source == .allPhotographs && list.sort == sort)
            }
        }
        let captured = try await engine.list(.allPhotographs)
        #expect(library.numbers(captured) == [4, 7, 6, 5, 8, 1, 2, 3])
        let rated = try await engine.list(.allPhotographs, sort: QuerySort(.rating, ascending: false))
        #expect(library.numbers(rated.prefix(3)) == [1, 5, 2])

        for (place, id) in captured.enumerated() {
            #expect(captured.index(of: id) == place && captured.contains(id))
        }
        #expect(captured.index(of: 0) == nil && !captured.contains(10000) && !captured.contains(-1))
    }

    @Test func `folders, with and without their subfolders, queries and Rejected are sources`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        func numbers(_ source: PhotoSource) async throws -> [Int] {
            try await library.numbers(engine.list(source)).sorted()
        }
        #expect(try await numbers(.folder(Self.folder("2024"), includingSubfolders: true)) == [1, 2, 3, 4, 7])
        #expect(try await numbers(.folder(Self.folder("2024"), includingSubfolders: false)) == [])
        #expect(try await numbers(.folder(Self.folder("2024/Studio/"), includingSubfolders: false)) == [3, 4, 7])
        #expect(try await numbers(.folder(Self.folder("Voyages"), includingSubfolders: true)) == [6])
        #expect(try await numbers(.folder(Self.folder("Voyages/Été à Montréal 2014"), includingSubfolders: false)) ==
            [6])
        #expect(try await numbers(.folder(Self.folder("2019/Alg"), includingSubfolders: true)) == [])
        #expect(try await numbers(.folder(Self.folder("Elsewhere"), includingSubfolders: true)) == [])
        #expect(try await numbers(.folder(URL(fileURLWithPath: IndexSandbox.rootPath), includingSubfolders: true))
            == Array(1 ... 8))
        #expect(try await numbers(.rejected) == [3])
        #expect(try await numbers(.query(LibraryQuery(parsing: "rating>=3"))) == [1, 2, 5])
        #expect(try await numbers(.query(LibraryQuery(parsing: "in:Studio -type:png"))) == [3, 4])
        #expect(try await numbers(.query(.all)) == Array(1 ... 8))
    }

    @Test func `a list made before the store is loaded loads it`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: false)
        #expect(!engine.isLoaded)
        let list = try await engine.list(.rejected)
        #expect(engine.isLoaded && library.numbers(list) == [3])
    }

    // MARK: - Diffs

    /// `diff` applied to `old`'s IDs, its inserted IDs taken from `new`.
    private static func applied(_ diff: PhotoListDiff, _ old: PhotoList, _ new: PhotoList) -> [Int64] {
        var ids = Array(old.ids)
        diff.apply(to: &ids) { new[$0] }
        return ids
    }

    private static func list(_ ids: [Int64]) -> PhotoList {
        PhotoList(source: .allPhotographs, sort: QuerySort(), ids: ContiguousArray(ids))
    }

    @Test func `a diff names each insert, removal, move and update by its index`() {
        let old = Self.list([10, 20, 30, 40, 50, 60])
        // 20 removed, 70 inserted, 50 moved to the front, 30 changed in place.
        let new = Self.list([50, 10, 30, 70, 40, 60])
        let diff = PhotoListDiff(from: old, to: new, changed: [20, 30, 50, 70])
        #expect(diff == PhotoListDiff(
            removed: [1], inserted: [3], moved: [PhotoListDiff.Move(from: 4, to: 0)], updated: [2],
        ))
        #expect(Self.applied(diff, old, new) == Array(new.ids))
        #expect(!diff.isEmpty)

        // Two changed photos swapping places: one moves, the other stays.
        let swapped = PhotoListDiff(from: Self.list([1, 2, 3, 4]), to: Self.list([1, 3, 2, 4]), changed: [2, 3])
        #expect(swapped.moved.count == 1 && swapped.updated.count == 1 && swapped.removed.isEmpty)
        #expect(Self.applied(swapped, Self.list([1, 2, 3, 4]), Self.list([1, 3, 2, 4])) == [1, 3, 2, 4])

        #expect(PhotoListDiff(from: old, to: old, changed: []).isEmpty)
        #expect(PhotoListDiff(from: old, to: old, changed: [40]) == PhotoListDiff(updated: [3]))
        #expect(PhotoListDiff(from: old, to: old, changed: [99, -1]).isEmpty)
    }

    @Test(arguments: 1 ... 40)
    func `diffs of inserts, updates, removals and moves applied to the old list give the new one`(seed: Int) {
        var random = SeededRandom(seed: UInt64(seed))
        let count = random.int(in: 0 ... 300)
        var pool = Array(Int64(1) ... Int64(count + 200))
        pool.shuffle(using: &random)
        let old = Array(pool.prefix(count))
        var new = old
        var changed = Set<Int64>()
        for _ in 0 ..< random.int(in: 0 ... 20) where !new.isEmpty {
            changed.insert(new.remove(at: random.int(below: new.count)))
        }
        for _ in 0 ..< random.int(in: 0 ... 20) where !new.isEmpty {
            let id = new.remove(at: random.int(below: new.count))
            new.insert(id, at: random.int(in: 0 ... new.count))
            changed.insert(id)
        }
        for _ in 0 ..< random.int(in: 0 ... 10) where !new.isEmpty {
            changed.insert(new[random.int(below: new.count)])
        }
        for id in pool.dropFirst(count).prefix(random.int(in: 0 ... 20)) {
            new.insert(id, at: random.int(in: 0 ... new.count))
            changed.insert(id)
        }
        let (before, after) = (Self.list(old), Self.list(new))
        let diff = PhotoListDiff(from: before, to: after, changed: changed)
        #expect(Self.applied(diff, before, after) == new)
        #expect(diff.moved.allSatisfy { changed.contains(old[$0.from]) && new[$0.to] == old[$0.from] })
        #expect(diff.updated.allSatisfy { changed.contains(new[$0]) })
        #expect(diff.removed.allSatisfy { !new.contains(old[$0]) } && diff.inserted
            .allSatisfy { !old.contains(new[$0]) })

        // Told nothing of what changed, a diff still gives the new list.
        let unnamed = PhotoListDiff(from: before, to: after, changed: [])
        #expect(Self.applied(unnamed, before, after) == new)
        #expect(unnamed.moved.count <= diff.moved.count)
    }

    @Test func `a list made again after photos change, arrive and leave applies its diff`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let sort = QuerySort(.rating, ascending: false)
        let before = try await engine.list(.allPhotographs, sort: sort)
        let ids = library.ids
        let studio = try #require(library.folders["2024/Studio"])
        let added = try await library.index.write { writer in
            try writer.setOrganising([.rating(5)], forPhotos: [ids[7]])
            try writer.setOrganising([.flag(.pick)], forPhotos: [ids[2]])
            try writer.deletePhotos([ids[4]])
            return try writer.upsertPhotos([PhotoRecord(folder: studio, name: "IMG_0012.JPG", rating: 2)])
        }
        let changed = [ids[7], ids[2], ids[4]] + added
        try await engine.update(photos: changed)
        let after = try await engine.list(.allPhotographs, sort: sort)
        let diff = PhotoListDiff(from: before, to: after, changed: changed)
        #expect(Self.applied(diff, before, after) == Array(after.ids))
        #expect(library.numbers(before) == [1, 5, 2, 6, 4, 3, 8, 7])
        #expect(try diff.removed == IndexSet(integer: #require(before.index(of: ids[4]))))
        #expect(try diff.inserted == IndexSet(integer: #require(after.index(of: added[0]))))
        #expect(try diff.moved == [PhotoListDiff.Move(
            from: #require(before.index(of: ids[7])), to: #require(after.index(of: ids[7])),
        )])
        #expect(try diff.updated == IndexSet(integer: #require(after.index(of: ids[2]))))
    }

    @Test func `the lists scenario finds the manifest's counts, and its diffs put every photo in place`() async throws {
        let fixture = try TemporaryFolder()
        let summary = try LibraryFixture(spec: .init(photos: 200, seed: 44)).write(to: fixture.url)
        let indexFolder = try TemporaryFolder()
        let context = BenchContext(fixture: fixture.url, manifest: summary.manifest, profile: .ssd)
        let results = try await ListScenario(photos: 20000, indexFolder: indexFolder.url).run(context)
        let counted = results.filter { $0.budget?.kind == .exactly }
        #expect(
            counted.count == 8 && counted.allSatisfy { $0.passed == true },
            "\(counted.filter { $0.passed != true })",
        )
        for id in [
            "library-lists-all",
            "library-lists-diff",
            "library-lists-extend",
            "library-lists-fixture-folder-count",
        ] {
            #expect(results.contains { $0.id == id }, "\(id)")
        }
    }

    // MARK: - Statistics

    @Test func `the statistics count a small fixture's photos, folders, roots and volumes`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 300, seed: 41))
        defer { sandbox.remove() }
        let run = await IndexerRun.collect(
            LibraryIndexer(index: sandbox.index, configuration: .testing()).index([sandbox.root]),
        )
        #expect(run.failures.isEmpty)
        let paths = LibraryPaths(root: sandbox.indexFolder)
        try FileManager.default.createDirectory(at: paths.store, withIntermediateDirectories: true)
        try Data(count: 1234).write(to: paths.store.appending(path: "00.pack"))
        let statistics = try await LibraryStatistics.read(index: sandbox.index, paths: paths)
        let manifest = sandbox.manifest
        let photos = manifest.totals.photos
        #expect(statistics.photos == photos)
        #expect(statistics.folders == manifest.totals.folders + 1)
        #expect(statistics.edited == manifest.totals.edited && statistics.edited == manifest.count(of: "edited:yes"))
        #expect(statistics.rated == photos - (manifest.count(of: "rating:0") ?? -1))
        #expect(statistics.picked == manifest.count(of: "flag:pick"))
        #expect(statistics.rejected == manifest.count(of: "flag:reject"))
        #expect(statistics.labelled == photos - (manifest.count(of: "label:none") ?? -1))
        #expect(statistics.roots == [LibraryStatistics.Root(
            path: sandbox.rootPath,
            sidecars: .besidePhotos,
            photos: photos,
        )])
        #expect(statistics.volumes.count == 1 && statistics.volumes.allSatisfy { !$0.isOffline && $0.photos == photos })
        #expect(statistics.indexBytes > 0 && statistics.storeBytes == 1234)
    }
}
