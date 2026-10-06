import Foundation
import RedlampDocument
import Synchronization
import Testing
@testable import RedlampLibrary

/// Eight photos that differ in every field the query language asks about, numbered 1 to 8 in the
/// order they're added (their IDs' order). Photos 1 to 3, 5 and 6 have IPTC locations, 1, 2, 3 and
/// 6 creators, and 4 and 7 custom labels.
struct QueryTestLibrary {
    let sandbox: IndexSandbox
    /// Photo IDs, by number from 1.
    let ids: [Int64]
    let folders: [String: Int64]

    var index: LibraryIndex {
        sandbox.index
    }

    /// 21 August 2019 at noon, UTC: what today is to the engines here.
    static let now = date(2019, 8, 21)

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        Date(timeIntervalSince1970: Double(QueryCalendar.days(year, month, day) * 86400 + hour * 3600 + minute * 60))
    }

    static func make() async throws -> QueryTestLibrary {
        let sandbox = try await IndexSandbox.make()
        let folders = try await sandbox.addFolders([
            "2024", "2024/Lisbon Trip", "2024/Studio", "2019", "2019/Algarve", "Voyages",
            "Voyages/Été à Montréal 2014",
        ])
        let lisbon = try #require(folders["2024/Lisbon Trip"])
        let studio = try #require(folders["2024/Studio"])
        let algarve = try #require(folders["2019/Algarve"])
        let montreal = try #require(folders["Voyages/Été à Montréal 2014"])
        let ids = try await sandbox.index.write { writer in
            let xt5 = try writer.cameraID(for: "Fujifilm X-T5")
            let r5 = try writer.cameraID(for: "Canon EOS R5")
            let iphone = try writer.cameraID(for: "Apple iPhone 15 Pro")
            let xf35 = try writer.lensID(for: "XF35mmF1.4 R")
            let rf50 = try writer.lensID(for: "RF50mm F1.8 STM")
            let ids = try writer.upsertPhotos([
                PhotoRecord(
                    folder: lisbon, name: "DSCF0001.RAF", captured: date(2024, 6, 14, 10), camera: xt5, lens: xf35,
                    iso: 200, aperture: 1.4, shutter: 1.0 / 250, focal: 35, width: 7728, height: 5152, latitude: 38.7,
                    longitude: -9.1, rating: 5, flag: .pick, label: .red, edited: true,
                    sidecarModified: date(2025, 1, 2), title: "Tram 28",
                    caption: "Alfama at dusk", creator: "Ana Silva", copyright: "© 2024 Ana Silva",
                    location: PhotoLocation(
                        country: "Portugal", state: "Lisboa", city: "Lisboa", sublocation: "Alfama", countryCode: "PT",
                    ),
                ),
                PhotoRecord(
                    folder: lisbon, name: "DSCF0002.RAF", captured: date(2024, 6, 14, 10), camera: xt5, lens: xf35,
                    iso: 6400, aperture: 2.8, shutter: 1.0 / 30, focal: 35, rating: 3, label: .blue, edited: true,
                    sidecarModified: date(2025, 3, 1), xmpModified: date(2024, 6, 15), creator: "Ana Silva; João Costa",
                    location: PhotoLocation(country: "Portugal", city: "Lisboa", countryCode: "PT"),
                ),
                PhotoRecord(
                    folder: studio, name: "IMG_0010.CR3", captured: date(2024, 7, 1, 9), camera: r5, lens: rf50,
                    iso: 100, aperture: 8, shutter: 2, focal: 50, width: 8192, height: 5464, flag: .reject,
                    caption: "Headshots for Acme",
                    creator: "Studio Acme", copyright: "Acme Corp",
                    location: PhotoLocation(country: "Portugal", city: "Porto"),
                ),
                PhotoRecord(
                    folder: studio, name: "IMG_0009.HEIC", camera: iphone, iso: 64, aperture: 1.78, shutter: 1.0 / 120,
                    focal: 6.765, width: 3024, height: 4032, rating: 1, marked: true, customLabel: "Hero",
                ),
                PhotoRecord(
                    folder: algarve, name: "Sunset.JPG", captured: date(2019, 8, 20, 19, 30), width: 12000,
                    height: 4000, latitude: 37.1, longitude: -8.6, rating: 4, label: .green,
                    caption: "Sunset over the harbour",
                    location: PhotoLocation(
                        country: "Portugal", state: "Faro", city: "Lagoa", sublocation: "Praia da Marinha",
                        countryCode: "PT",
                    ),
                ),
                PhotoRecord(
                    folder: montreal, name: "Café-0001.JPG", captured: date(2014, 7, 4), camera: xt5, lens: xf35,
                    iso: 800, aperture: 4, shutter: 1.0 / 500, focal: 23, width: 6000, height: 4000, rating: 2,
                    label: .purple, creator: "Élodie Tremblay",
                    location: PhotoLocation(country: "Canada", state: "Québec", city: "Montréal", countryCode: "CA"),
                ),
                PhotoRecord(folder: studio, name: "IMG_0011.PNG", width: 2000, height: 500, customLabel: "Client"),
                PhotoRecord(
                    folder: algarve,
                    name: "DSC_0100.NEF",
                    captured: date(2019, 8, 21, 8),
                    iso: 3200,
                    label: .yellow,
                ),
            ])
            try writer.setKeywords(["Places/Portugal/Lisbon", "Animals/Birds"], forPhoto: ids[0])
            try writer.setKeywords(["sunset"], forPhoto: ids[4])
            try writer.database.execute("""
            INSERT INTO collections (id, parent, name, kind, path) VALUES (1, NULL, 'Portfolio', 0, 'Portfolio'),
              (2, 1, '2024', 1, 'Portfolio/2024'), (3, NULL, 'Clients', 1, 'Clients'), (4, 9, 'Orphan', 1, NULL),
              (5, NULL, 'AC/DC', 1, 'AC%2FDC');
            INSERT INTO collection_photos (collection, photo) VALUES (2, \(ids[0])), (2, \(ids[2])), (3, \(ids[4])),
              (4, \(ids[6])), (5, \(ids[7]));
            """)
            return ids
        }
        return QueryTestLibrary(sandbox: sandbox, ids: ids, folders: folders)
    }

    func engine(loaded: Bool) async throws -> QueryEngine {
        let engine = QueryEngine(index: index, timeZone: .gmt, now: { Self.now })
        if loaded {
            try await engine.load()
        }
        return engine
    }

    /// The photos' numbers, in their order.
    func numbers(_ ids: some Sequence<Int64>) -> [Int] {
        ids.map { id in (self.ids.firstIndex(of: id) ?? -1) + 1 }
    }

    func remove() {
        sandbox.remove()
    }
}

extension QueryEngine {
    /// Every result a search hands over, to its end.
    func results(_ query: LibraryQuery, sort: QuerySort = QuerySort(), pageSize: Int = 100) async throws
        -> [QueryResult] {
        var results: [QueryResult] = []
        for try await result in search(query, sort: sort, pageSize: pageSize) {
            results.append(result)
        }
        return results
    }

    /// The photos a search finds, in order.
    func ids(_ text: String, sort: QuerySort = QuerySort()) async throws -> [Int64] {
        try await Array(results(LibraryQuery(parsing: text), sort: sort).last?.ids ?? [])
    }
}

/// Holds back what waits at it until it opens.
final class QueryGate: Sendable {
    private let state = Mutex((open: false, waiters: [CheckedContinuation<Void, Never>]()))

    func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                if !state.open {
                    state.waiters.append(continuation)
                }
                return state.open
            }
            if isOpen {
                continuation.resume()
            }
        }
    }

    /// Returns once `count` are waiting.
    func waitForWaiters(_ count: Int) async throws {
        while state.withLock({ $0.waiters.count }) < count {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// The index, with text lookups held at a gate.
struct GatedQuerySource: QuerySource {
    let base: IndexQuerySource
    let gate: QueryGate

    func columnStore() async throws -> ColumnStore {
        try await base.columnStore()
    }

    func names() async throws -> QueryNames {
        try await base.names()
    }

    func photoIDs(matching match: String) async throws -> [Int64] {
        await gate.wait()
        return try await base.photoIDs(matching: match)
    }

    func photoIDs(withKeywords keywords: [Int64]) async throws -> [Int64] {
        try await base.photoIDs(withKeywords: keywords)
    }

    func photoIDs(inCollections collections: [Int64]) async throws -> [Int64] {
        try await base.photoIDs(inCollections: collections)
    }

    func applying(_ ids: [Int64], to store: ColumnStore) async throws -> ColumnStore {
        try await base.applying(ids, to: store)
    }

    func run(
        _ sql: QuerySQL, pageSize: Int, cancellation: QueryCancellation,
        firstPage: @escaping @Sendable (ContiguousArray<Int64>) -> Void,
    ) async throws -> ContiguousArray<Int64> {
        try await base.run(sql, pageSize: pageSize, cancellation: cancellation, firstPage: firstPage)
    }
}
