import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Orientation (LIB-41): a column of the column store from the size the index keeps, upright, and the
/// language's `orientation:`, with its facet and completions, as grouping by orientation reads it.
struct QueryOrientationTests {
    /// Photos turned every way, by name: a phone's raw as the indexer keeps it, 3024 by 4032 with
    /// EXIF's orientation 6, and one whose size the index doesn't have.
    private static func library() async throws -> (sandbox: IndexSandbox, ids: [String: Int64]) {
        let sandbox = try await IndexSandbox.make()
        let folder = try #require(try await sandbox.addFolders(["Shoot"])["Shoot"])
        func time(_ minute: Int) -> Date {
            Date(timeIntervalSince1970: GroupLibrary.june14 + Double(10 * 3600 + minute * 60))
        }
        let photos = [
            PhotoRecord(folder: folder, name: "WIDE.JPG", captured: time(0), width: 6000, height: 4000),
            PhotoRecord(folder: folder, name: "TALL.JPG", captured: time(1), width: 4000, height: 6000),
            PhotoRecord(folder: folder, name: "SQUARE.JPG", captured: time(2), width: 3000, height: 3000),
            PhotoRecord(
                folder: folder, name: "PHONE.DNG", captured: time(3), width: 3024, height: 4032, orientation: 6,
            ),
            PhotoRecord(folder: folder, name: "UNKNOWN.JPG", captured: time(4)),
            PhotoRecord(folder: folder, name: "PANORAMA.JPG", captured: time(5), width: 12000, height: 4000),
        ]
        let ids = try await sandbox.upsert(photos)
        return (sandbox, Dictionary(uniqueKeysWithValues: zip(photos.map(\.name), ids)))
    }

    @Test func `orientation finds the photos turned each way, with the column store as with SQL`() async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let names = Dictionary(uniqueKeysWithValues: ids.map { ($0.value, $0.key) })
        let expected: [(String, [String])] = [
            ("orientation:landscape", ["WIDE.JPG", "PANORAMA.JPG"]),
            ("orientation:portrait", ["TALL.JPG", "PHONE.DNG"]),
            ("orientation:square", ["SQUARE.JPG"]),
            ("orientation:none", ["UNKNOWN.JPG"]),
            ("-orientation:none", ["WIDE.JPG", "TALL.JPG", "SQUARE.JPG", "PHONE.DNG", "PANORAMA.JPG"]),
            ("orientation:portrait,square", ["TALL.JPG", "SQUARE.JPG", "PHONE.DNG"]),
            ("orientation!=landscape", ["TALL.JPG", "SQUARE.JPG", "PHONE.DNG", "UNKNOWN.JPG"]),
            ("orientation:portrait aspect>=1.4", ["TALL.JPG"]),
        ]
        let engine = QueryEngine(index: sandbox.index, timeZone: .gmt)
        var withSQL: [[Int64]] = []
        for (text, _) in expected {
            try await withSQL.append(engine.ids(text))
        }
        #expect(!engine.isLoaded, "the store isn't built yet, so SQL answers")
        try await engine.load()
        for ((text, found), sql) in zip(expected, withSQL) {
            let columns = try await engine.ids(text)
            #expect(columns.compactMap { names[$0] } == found, "\(text)")
            #expect(columns == sql, "\(text)")
        }
    }

    @Test func `orientations are a facet, complete as they're typed, and give their groups filters`() async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let engine = QueryEngine(index: sandbox.index, timeZone: .gmt)
        try await engine.load()
        var facets: [FacetCounts] = []
        for try await counts in engine.facets([.orientation], for: .all) {
            facets.append(counts)
        }
        let values = try #require(facets.first?.values)
        #expect(values.map(\.name) == ["landscape", "portrait", "square", nil] && values.map(\.count) == [2, 2, 1, 1])
        #expect(values.map { $0.filter?.description } == [
            "orientation:landscape", "orientation:portrait", "orientation:square", "orientation:none",
        ])

        let typed = await engine.completions("portr", field: nil)
        #expect(typed.map(\.term) == ["orientation:portrait"] && typed.first?.count == 2)
        let fields = await engine.completions("sq", field: .orientation)
        #expect(fields.map(\.term) == ["orientation:square"] && fields.first?.count == 1)
        let inside = await engine.completions("s", field: .orientation).map(\.term)
        #expect(inside == ["orientation:square", "orientation:landscape"], "a start before a part inside")
        #expect(QueryCompletion.fields.contains(.orientation))
        #expect(QueryCompletion(field: .orientation, value: "landscape").term == "orientation:landscape")

        let grouping = try await engine.grouping()
        let list = try await engine.list(.allPhotographs)
        let groups = grouping.groups(of: list, by: .orientation)
        #expect(groups.map(\.name) == ["Landscape", "Portrait", "Square", "No orientation"])
        for group in groups {
            let filter = try #require(group.filter)
            #expect(try await Set(engine.list(.allPhotographs, matching: filter).ids) == Set(group.photos))
        }
        let (tall, phone) = try (#require(ids["TALL.JPG"]), #require(ids["PHONE.DNG"]))
        #expect(groups[1].photos.elementsEqual([tall, phone]))
    }

    @Test func `the column follows a photo whose size changes`() async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let engine = QueryEngine(index: sandbox.index, timeZone: .gmt)
        try await engine.load()
        let unknown = try #require(ids["UNKNOWN.JPG"])
        #expect(engine.store?.orientation(of: unknown) == nil)
        try await sandbox.index.write { writer in
            var row = try #require(try writer.photo(id: unknown))
            (row.width, row.height) = (2000, 3000)
            try writer.upsertPhotos([row])
        }
        try await engine.update(photos: [unknown])
        #expect(engine.store?.orientation(of: unknown) == .portrait)
        #expect(try await engine.ids("orientation:portrait").contains(unknown))
        #expect(try await engine.ids("orientation:none").isEmpty)
    }

    static let raws = PhotoMetadataReaderTests.root.appending(path: "tests/fixtures/raw")
    /// An iPhone's ProRAW shot upright: its sensor's 4032 by 3024, and EXIF's orientation 6.
    static let rotated = raws.appending(path: "IMG_1361.DNG")
    /// A Sony's raw, shot level: its sensor's 6000 by 4000, and orientation 1.
    static let level = raws.appending(path: "_DSC0009.ARW")

    @Test(.enabled(if: [rotated, level].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }))
    func `a raw shot on its side is portrait by its own orientation, not its sensor's frame`() async throws {
        let folder = try TemporaryFolder(on: Self.raws)
        for raw in [Self.rotated, Self.level] {
            try FileManager.default.copyItem(at: raw, to: folder.url.appending(path: raw.lastPathComponent))
        }
        let indexFolder = try TemporaryFolder()
        let index = try await LibraryIndex.open(at: indexFolder.url.appending(path: "Index.sqlite"))
        defer { index.closeAndWait() }
        let run = await IndexerRun.collect(LibraryIndexer(index: index, configuration: .testing()).index([folder.url]))
        try #require(run.failures.isEmpty, "\(run.failures)")
        let rows = try await index.read { reader in
            try reader.database.prepare("SELECT id, name, width, height, orientation FROM photos").map { row in
                (
                    row.string(at: 1) ?? "",
                    (row.int64(at: 0), row.optionalInt(at: 2), row.optionalInt(at: 3), row.optionalInt(at: 4)),
                )
            }
        }
        let byName = Dictionary(uniqueKeysWithValues: rows)
        let dng = try #require(byName["IMG_1361.DNG"])
        let arw = try #require(byName["_DSC0009.ARW"])
        #expect(dng.1 == 3024 && dng.2 == 4032 && dng.3 == 6, "the index keeps the size upright")
        #expect(arw.1 == 6000 && arw.2 == 4000)

        let engine = QueryEngine(index: index)
        try await engine.load()
        let store = try #require(engine.store)
        #expect(store.orientation(of: dng.0) == .portrait && store.orientation(of: arw.0) == .landscape)
        let grouping = try await engine.grouping(stacks: StackFinder.find(in: index, store: store))
        let groups = try await grouping.groups(of: engine.list(.allPhotographs), by: .orientation)
        #expect(groups.map(\.value) == [.orientation(.landscape), .orientation(.portrait)])
        #expect(groups.map { Array($0.photos) } == [[arw.0], [dng.0]])
        #expect(try await engine.ids("orientation:portrait") == [dng.0])
        #expect(try await engine.ids("orientation:landscape") == [arw.0])
    }
}
