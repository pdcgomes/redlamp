import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// The traits Wide Open, Telephoto and Ultra Wide and the fields `focal35` and `widest` (LIB-06): parsed, found
/// alike by SQL and the column store, counted as facets and in the filter bar's columns, offered in completion
/// with their counts, and kept in the store's snapshot.
struct QueryLensTests {
    /// Eight photos, numbered from 1: their f-number, their lens's widest, their 35 mm focal length.
    static let photos: [(aperture: Double?, widest: Double?, focal35: Double?)] = [
        (1.8, 1.8, 85), // wide open, telephoto
        (2.0, 1.8, 50), // a third of a stop down
        (1.9, 1.8, nil), // within a sixth of a stop: wide open
        (2.8, 2.8, 24), // wide open; 24 mm isn't ultra wide
        (8, 2.8, 18), // ultra wide
        (4, nil, 70), // telephoto from 70 mm; no widest, so not wide open
        (nil, 1.4, nil), // no aperture
        (1.4, 1.8, 135), // wider than its lens's recorded widest: wide open; telephoto
    ]

    /// What each query finds, by the photos' numbers.
    static let expected: [(String, [Int])] = [
        ("is:wide-open", [1, 3, 4, 8]),
        ("is:telephoto", [1, 6, 8]),
        ("is:ultra-wide", [5]),
        ("-is:wide-open", [2, 5, 6, 7]),
        ("is:telephoto,ultra-wide", [1, 5, 6, 8]),
        ("is:wide-open is:telephoto", [1, 8]),
        ("focal35:24..70", [2, 4, 6]),
        ("focal35<24", [5]),
        ("focal35:85mm", [1]),
        ("widest<=1.8", [1, 2, 3, 7, 8]),
        ("widest:2.8", [4, 5]),
        ("widest>2", [4, 5]),
    ]

    static func library() async throws -> (IndexSandbox, [Int64]) {
        let sandbox = try await IndexSandbox.make()
        let folder = try #require(try await sandbox.addFolders(["Lenses"])["Lenses"])
        let ids = try await sandbox.index.write { writer in
            try writer.upsertPhotos(photos.enumerated().map { number, photo in
                PhotoRecord(
                    folder: folder, name: "P\(number + 1).JPG", captured: QueryTestLibrary.date(2024, 6, 1 + number),
                    aperture: photo.aperture, widestAperture: photo.widest, focal35: photo.focal35,
                )
            })
        }
        return (sandbox, ids)
    }

    @Test func `the fields and traits parse, and read back as written`() throws {
        let query = try LibraryQuery(parsing: "focal35:24..70mm widest<=1.4 IS:Wide-Open,telephoto is:ultra-wide")
        #expect(query.description == "focal35:24..70 widest<=1.4 is:wide-open,telephoto is:ultra-wide")
        #expect(try LibraryQuery(parsing: query.description) == query)
        #expect(LibraryQuery.Field(name: "WIDEST") == .widestAperture && LibraryQuery.Field.focal35.isOrdered)
        #expect(throws: LibraryQueryError.self) { try LibraryQuery(parsing: "focal35:long") }
        do {
            _ = try LibraryQuery(parsing: "widest:fast")
        } catch {
            #expect(error.message == "widest is an f-number, or a range such as 1.2..2")
        }
        do {
            _ = try LibraryQuery(parsing: "is:bokeh")
        } catch {
            #expect(error.message.contains("wide-open, telephoto, ultra-wide"), "\(error.message)")
        }
        #expect(LibraryQuery.Trait.telephoto.query == .filter(.init(.focal35, .greaterOrEqual, [.number(70)])))
        #expect(LibraryQuery.Trait.ultraWide.query == .filter(.init(.focal35, .less, [.number(24)])))
        #expect(LibraryQuery.Trait.wideOpen.query == nil && !LibraryQuery.filter(
            .init(.trait, .equal, [.trait(.wideOpen)]),
        ).needsStore)
    }

    @Test func `SQL and the column store find the same photos for each trait and field`() async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let sql = QueryEngine(index: sandbox.index, timeZone: .gmt)
        let store = QueryEngine(index: sandbox.index, timeZone: .gmt)
        try await store.load()
        for (text, numbers) in Self.expected {
            let wanted = numbers.map { ids[$0 - 1] }
            #expect(try await sql.ids(text) == wanted, "SQL: \(text)")
            #expect(try await store.ids(text) == wanted, "store: \(text)")
        }
    }

    @Test func `the store follows a photo's lens's fields as they change`() async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let engine = QueryEngine(index: sandbox.index, timeZone: .gmt)
        try await engine.load()
        #expect(try await engine.ids("is:ultra-wide") == [ids[4]])
        try await sandbox.index.write { writer in
            try writer.database.execute("UPDATE photos SET focal35 = 16, widest_aperture = 2 WHERE id = \(ids[1])")
        }
        try await engine.update(photos: [ids[1]])
        #expect(try await engine.ids("is:ultra-wide") == [ids[1], ids[4]])
        #expect(try await engine.ids("is:wide-open") == [ids[0], ids[1], ids[2], ids[3], ids[7]])
    }

    @Test func `facets and the filter bar's columns count the photos by each`() async throws {
        let (sandbox, _) = try await Self.library()
        defer { sandbox.remove() }
        let engine = QueryEngine(index: sandbox.index, timeZone: .gmt)
        try await engine.load()
        var facets: [Facet: [String?]] = [:]
        for try await counts in engine.facets([.focal35, .widestAperture], for: .all) {
            facets[counts.facet] = counts.values.map { "\($0.name ?? "none") \($0.count)" }
        }
        #expect(facets[.focal35] == ["18 1", "24 1", "50 1", "70 1", "85 1", "135 1", "none 2"])
        #expect(facets[.widestAperture] == ["1.4 1", "1.8 4", "2.8 2", "none 1"])

        var columns: [FacetColumnCounts] = []
        let query = try LibraryQuery(parsing: "is:telephoto")
        for try await counts in engine.columns(
            [FacetColumnRequest(.focal35, query: query), FacetColumnRequest(.widestAperture, query: query)],
            in: .allPhotographs,
        ) {
            columns.append(counts)
        }
        #expect(columns.map(\.total) == [3, 3])
        #expect(columns.first?.values.compactMap(\.name) == ["70", "85", "135"])
        #expect(columns.last?.values.map(\.name) == ["1.8", nil])
        let chosen = try #require(columns.first?.values.first?.filter)
        #expect(chosen.description == "focal35:70")
        #expect(FacetColumn.focal35.field == .focal35 && FacetColumn.widestAperture.facet == .widestAperture)
    }

    @Test func `completion offers the traits with the photos they find`() async throws {
        let (sandbox, _) = try await Self.library()
        defer { sandbox.remove() }
        let engine = QueryEngine(index: sandbox.index, timeZone: .gmt)
        try await engine.load()
        let tele = await engine.completions("tele", field: nil)
        #expect(tele.first.map { $0.term == "is:telephoto" && $0.count == 3 } == true, "\(tele)")
        let wide = await engine.completions("wide", field: .trait)
        #expect(wide.map(\.value) == ["wide-open", "ultra-wide"], "\(wide)")
        #expect(wide.map(\.count) == [4, 1])
        let joined = await engine.completions("ultrawide", field: nil)
        #expect(joined.first?.value == "ultra-wide", "\(joined)")
    }

    @Test func `the store's snapshot keeps the two columns`() async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let part = try await sandbox.index.read { try $0.columnStorePart(ids: 0 ... Int64.max) }
        let store = await ColumnStore.joining([part])
        let url = sandbox.directory.appending(path: "Index.columns")
        let generation = IndexGeneration(schema: LibraryIndex.schemaVersion, counter: 3, token: 9)
        try ColumnSnapshot.write(store, names: QueryNames(), generation: generation, to: url)
        let read = try #require(ColumnSnapshot.read(at: url, generation: generation)).store
        func values(_ store: ColumnStore) -> [[UInt16]] {
            [store.widestApertures, store.focal35s].map { column in column.withUnsafeBufferPointer { Array($0) } }
        }
        #expect(values(read) == values(store))
        #expect(values(store) == [
            [180, 180, 180, 280, 280, 0, 140, 180], [850, 500, 0, 240, 180, 700, 0, 1350],
        ])
        let wideOpen = read.rows(matching: .leaf(.wideOpen), sets: [:])
        #expect(Array(read.ids(of: wideOpen, sortedBy: QuerySort())) == [ids[0], ids[2], ids[3], ids[7]])
    }
}
