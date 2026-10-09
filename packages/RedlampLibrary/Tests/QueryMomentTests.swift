import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// `is:unpicked-moment` (LIB-41): the photos in moments without a pick as a term of the query language, its
/// moments found among the photos it filters with the Tighter–Looser setting it's run with: a source's for its
/// filter, the library's for a search, and the library's at the default setting for a source's own query.
struct QueryMomentTests {
    /// A day's shooting by the camera's clock in two folders. Wedding: sessions at 10:00 (A), 10:03 (B) and 12:00 (C),
    /// five frames ten seconds apart each, A2 picked. Second Body: a session at 12:00:05 (D), three frames ten seconds
    /// apart between C's, D2 picked, one at 15:00 (E), and a scan without a capture time.
    struct Day {
        let sandbox: IndexSandbox
        let ids: [String: Int64]

        var index: LibraryIndex {
            sandbox.index
        }

        static let wedding = PhotoSource.folder(folder("Wedding"), includingSubfolders: false)
        static let secondBody = PhotoSource.folder(folder("Second Body"), includingSubfolders: false)

        static func folder(_ path: String) -> URL {
            URL(fileURLWithPath: IndexSandbox.rootPath + "/" + path, isDirectory: true)
        }

        static func make() async throws -> Day {
            let sandbox = try await IndexSandbox.make()
            let folders = try await sandbox.addFolders(["Wedding", "Second Body"])
            let (wedding, second) = try (#require(folders["Wedding"]), #require(folders["Second Body"]))
            let june14 = Double(QueryCalendar.days(2025, 6, 14)) * 86400
            var records: [PhotoRecord] = []
            func session(_ prefix: String, in folder: Int64, at start: Double, frames: Int, picked: Int? = nil) {
                for frame in 0 ..< frames {
                    records.append(PhotoRecord(
                        folder: folder, name: "\(prefix)\(frame + 1).NEF",
                        captured: Date(timeIntervalSince1970: june14 + start + Double(frame) * 10),
                        flag: frame + 1 == picked ? .pick : nil,
                    ))
                }
            }
            session("A", in: wedding, at: 10 * 3600, frames: 5, picked: 2)
            session("B", in: wedding, at: 10 * 3600 + 180, frames: 5)
            session("C", in: wedding, at: 12 * 3600, frames: 5)
            session("D", in: second, at: 12 * 3600 + 5, frames: 3, picked: 2)
            session("E", in: second, at: 15 * 3600, frames: 3)
            records.append(PhotoRecord(folder: second, name: "SCAN.TIF"))
            let ids = try await sandbox.upsert(records)
            return Day(sandbox: sandbox, ids: Dictionary(uniqueKeysWithValues: zip(records.map(\.name), ids)))
        }

        func engine(loaded: Bool = true) async throws -> QueryEngine {
            let engine = QueryEngine(index: index, timeZone: .gmt)
            if loaded {
                try await engine.load()
            }
            return engine
        }

        /// The photos' names, sorted.
        func names(_ ids: some Sequence<Int64>) -> [String] {
            ids.map { id in self.ids.first { $0.value == id }?.key ?? "?" }.sorted()
        }

        /// The frames of the sessions named, sorted.
        static func frames(_ sessions: String, extra: [String] = []) -> [String] {
            let counts: [Character: Int] = ["A": 5, "B": 5, "C": 5, "D": 3, "E": 3]
            return (sessions.flatMap { session in (1 ... (counts[session] ?? 0)).map { "\(session)\($0).NEF" } }
                + extra).sorted()
        }

        /// Gives photo `name` `flag` in the index, and the engine the change.
        func setFlag(_ flag: PhotoFlag?, of name: String, engine: QueryEngine) async throws {
            let id = try #require(ids[name])
            try await index.write { writer in
                try writer.database.execute("UPDATE photos SET flag = \(PhotoRecord.code(for: flag)) WHERE id = \(id)")
            }
            try await engine.update(photos: [id])
        }

        func remove() {
            sandbox.remove()
        }
    }

    private static let unpicked = LibraryQuery.filter(LibraryQuery.Filter(.trait, .equal, [.trait(.unpickedMoment)]))

    private static func looser(_ steps: Int) -> MomentSetting {
        MomentSetting(looseness: steps)
    }

    // MARK: - The term

    @Test func `the term is a trait the language reads and writes, standing for no query over the fields`() throws {
        #expect(try LibraryQuery(parsing: "is:unpicked-moment") == Self.unpicked)
        #expect(try LibraryQuery(parsing: "IS:Unpicked-Moment") == Self.unpicked, "as other traits, any case")
        #expect(Self.unpicked.description == "is:unpicked-moment")
        #expect(LibraryQuery.Trait.unpickedMoment.title == "Moments without a Pick")
        #expect(LibraryQuery.Trait.unpickedMoment.query == nil)
        #expect(LibraryQuery.Trait.allCases.filter { $0.query == nil } == [.unpickedMoment])
        for text in ["is:unpicked-moment rating>=3", "-is:unpicked-moment", "(is:panorama,unpicked-moment OR kw:x) a"] {
            let query = try LibraryQuery(parsing: text)
            #expect(query.findsMoments, "\(text)")
            #expect(try LibraryQuery(parsing: query.description) == query)
            #expect(LibraryQuery(QueryRules(query)) == query)
        }
        #expect(try !LibraryQuery(parsing: "is:panorama is:no-location flag:pick").findsMoments)
        #expect(throws: LibraryQueryError.self) { try LibraryQuery(parsing: "is:unpicked") }
    }

    // MARK: - Sources and searches

    @Test func `a folder's filter finds the moments of its own photos, as the folder's setting finds them`(
    ) async throws {
        let day = try await Day.make()
        defer { day.remove() }
        let engine = try await day.engine()
        let wedding = try await engine.list(Day.wedding, matching: Self.unpicked)
        #expect(day.names(wedding) == Day.frames("BC"), "C has no pick of its own, though D's was taken beside it")
        #expect(wedding.source == Day.wedding)
        let looser = try await engine.list(Day.wedding, matching: Self.unpicked, moments: Self.looser(3))
        #expect(day.names(looser) == Day.frames("C"), "three steps looser, the pause after A no longer starts B")
        let tightest = try await engine.list(Day.wedding, matching: Self.unpicked, moments: Self.looser(-4))
        #expect(day.names(tightest) == Day.frames("BC"))
        let second = try await engine.list(Day.secondBody, matching: Self.unpicked)
        #expect(day.names(second) == Day.frames("E", extra: ["SCAN.TIF"]), "the photos without a capture time too")

        let covered = try await engine.list(Day.wedding, matching: LibraryQuery(parsing: "-is:unpicked-moment"))
        #expect(day.names(covered) == Day.frames("A"))
        let besides = try await engine.list(
            Day.wedding,
            matching: LibraryQuery(parsing: "is:unpicked-moment -flag:pick"),
        )
        #expect(day.names(besides) == Day.frames("BC"), "leaving out picks leaves the moments as they were")
        let either = try await engine.list(
            Day.wedding,
            matching: LibraryQuery(parsing: "is:unpicked-moment OR flag:pick"),
        )
        #expect(day.names(either) == Day.frames("BC", extra: ["A2.NEF"]))
        let late = try await engine.list(
            Day.wedding,
            matching: LibraryQuery(parsing: "is:unpicked-moment date:2025-06-14T12"),
        )
        #expect(day.names(late) == Day.frames("C"))
    }

    @Test func `a search finds the library's moments, with the setting it's given`() async throws {
        let day = try await Day.make()
        defer { day.remove() }
        let engine = try await day.engine()
        #expect(try await day.names(engine.ids("is:unpicked-moment")) == Day.frames("BE", extra: ["SCAN.TIF"]))
        #expect(try await day.names(engine.ids("is:unpicked-moment in:Wedding")) == Day.frames("B"))
        var looser: [Int64] = []
        for try await found in engine.search(Self.unpicked, moments: Self.looser(3)) {
            looser = Array(found.ids)
        }
        #expect(day.names(looser) == Day.frames("E", extra: ["SCAN.TIF"]))

        let searched = try await LibrarySearch.run(Self.unpicked, moments: Self.looser(3), index: day.index)
        #expect(searched.count == 4)
        let report = try await LibraryGroupReport.run(
            Self.unpicked,
            by: .moment,
            setting: Self.looser(3),
            index: day.index,
        )
        #expect(report.groups.photoSets.map { day.names($0) } == [Day.frames("E"), ["SCAN.TIF"]])
        #expect(report.coverage.unpicked == [0, 1], "grouped as they were found")
    }

    @Test func `a source's own query and a smart collection's find the library's moments at the default setting`(
    ) async throws {
        let day = try await Day.make()
        defer { day.remove() }
        let path = try #require(CollectionPath("Uncovered"))
        let paths = LibraryPaths(root: day.index.url.deletingLastPathComponent())
        try CollectionDefinitions(collections: [path: .smart("is:unpicked-moment")])
            .save(to: CollectionDefinitions.url(in: paths))
        let engine = try await day.engine()
        let library = Day.frames("BE", extra: ["SCAN.TIF"])
        #expect(try await day.names(engine.list(.collection(path))) == library)
        let filtered = try await engine.list(.collection(path), matching: .all, moments: Self.looser(3))
        #expect(day.names(filtered) == library, "the setting is the filter's, not the collection's")
        #expect(try await day.names(engine.list(.query(Self.unpicked))) == library)
        let within = try await engine.list(.collection(path), matching: Self.unpicked, moments: Self.looser(3))
        #expect(day.names(within) == library, "without A among the collection's photos, B is a moment without a pick")
    }

    @Test func `a pick given or taken changes the moments without one`() async throws {
        let day = try await Day.make()
        defer { day.remove() }
        let engine = try await day.engine()
        #expect(try await day.names(engine.list(Day.wedding, matching: Self.unpicked)) == Day.frames("BC"))
        try await day.setFlag(.pick, of: "B3.NEF", engine: engine)
        #expect(try await day.names(engine.list(Day.wedding, matching: Self.unpicked)) == Day.frames("C"))
        try await day.setFlag(.reject, of: "A2.NEF", engine: engine)
        #expect(try await day.names(engine.list(Day.wedding, matching: Self.unpicked)) == Day.frames("AC"))
        try await day.setFlag(.pick, of: "C5.NEF", engine: engine)
        #expect(try await day.names(engine.ids("is:unpicked-moment")) == Day.frames("AE", extra: ["SCAN.TIF"]))
    }

    @Test func `before the store is ready, a search with the term waits for it rather than ask SQL`() async throws {
        let day = try await Day.make()
        defer { day.remove() }
        let engine = try await day.engine(loaded: false)
        #expect(!engine.isLoaded)
        #expect(try await day.names(engine.ids("is:unpicked-moment")) == Day.frames("BE", extra: ["SCAN.TIF"]))
        #expect(engine.isLoaded)
    }

    // MARK: - The filter bar

    @Test func `completion offers it with the source's photos it finds, and the columns and offers count with the setting`(
    ) async throws {
        let day = try await Day.make()
        defer { day.remove() }
        let engine = try await day.engine()
        let typed = await engine.completions("unpick", field: nil, in: Day.wedding)
        #expect(typed.first == QueryCompletion(field: .trait, value: "unpicked-moment", count: 10))
        #expect(typed.first?.term == "is:unpicked-moment")
        let named = await engine.completions("moments with", field: nil, in: Day.wedding, moments: Self.looser(3))
        #expect(named.first?.value == "unpicked-moment" && named.first?.count == 5, "by its title")
        #expect(await engine.completions("pick", field: .trait).first?.count == 9, "the library's moments")

        let requests = [FacetColumnRequest(.folder, query: Self.unpicked), FacetColumnRequest(.flag, query: .all)]
        var counted: [FacetColumnCounts] = []
        for try await counts in engine.columns(requests, in: Day.wedding, moments: Self.looser(3)) {
            counted.append(counts)
        }
        #expect(counted.map(\.total) == [5, 15])
        counted = []
        for try await counts in engine.columns(requests, in: Day.wedding) {
            counted.append(counts)
        }
        #expect(counted.map(\.total) == [10, 15], "counted again for the other setting")

        let nothing = try LibraryQuery(parsing: "is:unpicked-moment flag:pick")
        let removal = try await engine.removal(from: nothing, in: Day.wedding)
        #expect(removal?.term == "flag:pick" && removal?.count == 10)
        let looser = try await engine.removal(from: nothing, in: Day.wedding, moments: Self.looser(3))
        #expect(looser?.term == "flag:pick" && looser?.count == 5)
    }

    // MARK: - The coverage it's found from

    @Test func `the rows it finds are MomentCoverage's photos, for lists large and small at every setting`() {
        var random = SeededRandom(seed: 41)
        var library = GroupLibrary()
        var time = GroupLibrary.june14
        while library.photos.count < 700 {
            let frames = random.int(in: 1 ... 25)
            for _ in 0 ..< frames {
                let undated = random.chance(0.04)
                let flag: PhotoFlag? = random.chance(0.05) ? .pick : random.chance(0.05) ? .reject : nil
                library.add("P\(library.photos.count).NEF", at: undated ? nil : time, flag: flag)
                time += random.chance(0.2) ? random.unit() : Double(random.int(in: 1 ... 40))
            }
            time += Double(random.pick([20, 70, 150, 400, 1200, 4000, 20000]) + random.int(below: 30))
        }
        let store = library.store
        let grouping = LibraryGrouping(store: store, names: library.names)
        let all = store.ids(sortedBy: QuerySort())
        for round in 0 ..< 24 {
            let share = [0.02, 0.1, 0.13, 0.5, 1][round % 5]
            let ids = ContiguousArray(all.filter { _ in random.unit() < share })
            let list = PhotoList(source: .allPhotographs, sort: QuerySort(), ids: ids)
            let rows = store.rows(withIDs: Array(ids))
            for looseness in MomentSetting.tightest ... MomentSetting.loosest {
                let setting = MomentSetting(looseness: looseness)
                let expected = Set(grouping.coverage(of: list, setting: setting).photos)
                var found = Set<Int64>()
                store.unpickedMoments(of: rows, setting: setting).forEach { row in
                    found.insert(store.ids[row])
                    return true
                }
                #expect(found == expected, "\(ids.count) photos, looseness \(looseness)")
            }
        }
    }
}
