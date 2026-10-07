import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// A time of day in `date:` (LIB-41): an hour, a minute or a second of a day by the camera's clock,
/// after a `T`, alone or at either end of a range, so each moment has a filter finding its photos.
struct QueryTimeTests {
    private static func parse(_ text: String, asYouType: Bool = false) throws(LibraryQueryError) -> LibraryQuery {
        try LibraryQuery(parsing: text, asYouType: asYouType)
    }

    private static func date(_ value: LibraryQuery.Value, _ comparison: LibraryQuery.Comparison = .equal)
        -> LibraryQuery {
        .filter(LibraryQuery.Filter(.date, comparison, [value]))
    }

    private static func june14(_ time: QueryTime) -> QueryDate {
        .time(2025, 6, 14, time)
    }

    @Test func `a date takes an hour, a minute or a second after a T, alone or at either end of a range`() throws {
        let cases: [(String, LibraryQuery)] = [
            ("date:2025-06-14T14", Self.date(.date(Self.june14(.hour(14))))),
            ("date:2025-06-14T14:03", Self.date(.date(Self.june14(.minute(14, 3))))),
            ("taken:2025-06-14t09:05:07", Self.date(.date(Self.june14(.second(9, 5, 7))))),
            ("date:2025-6-14T9:05", Self.date(.date(Self.june14(.minute(9, 5))))),
            (
                "date:2025-06-14T14:03:12..2025-06-14T14:47:05",
                Self.date(.dateRange(Self.june14(.second(14, 3, 12)), Self.june14(.second(14, 47, 5)))),
            ),
            (
                "date:2025-06-14T23:50..2025-06-15",
                Self.date(.dateRange(Self.june14(.minute(23, 50)), .day(2025, 6, 15))),
            ),
            ("date:2025-06-14T18..", Self.date(.dateRange(Self.june14(.hour(18)), nil))),
            ("date:..2025-06-14T08:00", Self.date(.dateRange(nil, Self.june14(.minute(8, 0))))),
            ("date>=2025-06-14T14:00", Self.date(.date(Self.june14(.minute(14, 0))), .greaterOrEqual)),
            ("date:2025-06-14,2025-06-15T00", .filter(LibraryQuery.Filter(.date, .equal, [
                .date(.day(2025, 6, 14)), .date(.time(2025, 6, 15, .hour(0))),
            ]))),
        ]
        for (text, expected) in cases {
            #expect(try Self.parse(text) == expected, "\(text)")
        }
        let canonical = [
            ("date:2025-6-14t9:05", "date:2025-06-14T09:05"),
            ("date:2025-06-14T7", "date:2025-06-14T07"),
            ("date:2025-06-14T14:03:12..2025-06-14T14:47:05", "date:2025-06-14T14:03:12..2025-06-14T14:47:05"),
            ("taken<2025-06-14T00:00:01", "date<2025-06-14T00:00:01"),
        ]
        for (text, expected) in canonical {
            let query = try Self.parse(text)
            #expect(query.description == expected, "\(text)")
            #expect(try Self.parse(query.description) == query, "\(text)")
        }
    }

    @Test func `a time that can't be read names its characters, and one still being typed is left out`() throws {
        let cases: [(String, Range<Int>, String)] = [
            ("date:2025-06-14T24", 5 ..< 18, "dates are written"),
            ("date:2025-06-14T14:60", 5 ..< 21, "dates are written"),
            ("date:2025-06-14T14:5", 5 ..< 20, "dates are written"),
            ("date:2025-06-14T14:05:7", 5 ..< 23, "dates are written"),
            ("date:2025-06-14T", 5 ..< 16, "dates are written"),
            ("date:T14:00", 5 ..< 11, "dates are written"),
            ("date:2025-06T14", 5 ..< 15, "dates are written"),
            ("date:todayT14", 5 ..< 13, "dates are written"),
            ("date:2025-06-14T15:00..2025-06-14T14:59", 5 ..< 39, "this range runs backwards"),
        ]
        for (text, range, message) in cases {
            do {
                _ = try Self.parse(text)
                Issue.record("\(text) should be an error")
            } catch {
                #expect(error.range == range, "\(text): \(error.message)")
                #expect(error.message.hasPrefix(message), "\(text): \(error.message)")
            }
        }
        let rating = LibraryQuery.filter(LibraryQuery.Filter(.rating, .equal, [.number(3)]))
        #expect(try Self.parse("rating:3 date:2025-06-14T", asYouType: true) == rating)
        #expect(try Self.parse("rating:3 date:2025-06-14T14:", asYouType: true) == rating)
        #expect(try Self.parse("date:2025-06-14T14:0", asYouType: true) == .all)
    }

    @Test func `a time spans its hour, minute or second of the camera's clock`() {
        let day = Int64(QueryCalendar.days(2025, 6, 14)) * QueryCalendar.millisecondsPerDay
        #expect(Self.june14(.hour(14)).interval(today: 0) == day + 50_400_000 ..< day + 54_000_000)
        #expect(Self.june14(.minute(14, 3)).interval(today: 0) == day + 50_580_000 ..< day + 50_640_000)
        #expect(Self.june14(.second(14, 3, 12)).interval(today: 0) == day + 50_592_000 ..< day + 50_593_000)
        #expect(Self.june14(.second(23, 59, 59)).interval(today: 0).upperBound == day + QueryCalendar
            .millisecondsPerDay)
        #expect(QueryDate.second(ofMilliseconds: day + 50_592_750) == Self.june14(.second(14, 3, 12)))
        #expect(QueryDate.second(ofMilliseconds: -1) == .time(1969, 12, 31, .second(23, 59, 59)))
    }

    /// Photos taken at times either side of a second's, a minute's and an hour's ends, by name.
    private static func library() async throws -> (sandbox: IndexSandbox, ids: [String: Int64]) {
        let sandbox = try await IndexSandbox.make()
        let folder = try #require(try await sandbox.addFolders(["Shoot"])["Shoot"])
        let times: [(String, Double?)] = [
            ("EVE", -0.25), ("A", 50591.75), ("B", 50592), ("C", 50592.5), ("D", 50592.75), ("E", 50593),
            ("F", 53999.75), ("G", 54000), ("NEXT", 86400), ("UNDATED", nil),
        ]
        let photos = times.map { name, seconds in
            PhotoRecord(
                folder: folder, name: name + ".JPG",
                captured: seconds.map { Date(timeIntervalSince1970: GroupLibrary.june14 + $0) },
            )
        }
        let ids = try await sandbox.upsert(photos)
        return (sandbox, Dictionary(uniqueKeysWithValues: zip(times.map(\.0), ids)))
    }

    @Test func `times find the same photos with the column store as with SQL, to the millisecond`() async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let names = Dictionary(uniqueKeysWithValues: ids.map { ($0.value, $0.key) })
        let expected: [(String, [String])] = [
            ("date:2025-06-14T14:03:12", ["B", "C", "D"]),
            ("date:2025-06-14T14:03", ["A", "B", "C", "D", "E"]),
            ("date:2025-06-14T14", ["A", "B", "C", "D", "E", "F"]),
            ("date:2025-06-14T14:03:12..2025-06-14T14:59", ["B", "C", "D", "E", "F"]),
            ("date>2025-06-14T14:03:12", ["E", "F", "G", "NEXT"]),
            ("date<=2025-06-14T00:00", ["EVE"]),
            ("date:2025-06-13T23:59:59..2025-06-14T00:00:00", ["EVE"]),
            ("date:2025-06-14 -date:2025-06-14T14", ["G"]),
            ("date:2025-06-15T00:00:00", ["NEXT"]),
        ]
        let engine = QueryEngine(index: sandbox.index, timeZone: .gmt)
        var withSQL: [[Int64]] = []
        for (text, _) in expected {
            try await withSQL.append(engine.ids(text))
        }
        try await engine.load()
        for ((text, found), sql) in zip(expected, withSQL) {
            let columns = try await engine.ids(text)
            #expect(columns.compactMap { names[$0] } == found, "\(text)")
            #expect(columns == sql, "\(text)")
        }
    }

    @Test func `each moment's filter finds exactly its photos, with the column store as with SQL`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folders = try await sandbox.addFolders(["Wedding", "Walk"])
        let (wedding, walk) = try (#require(folders["Wedding"]), #require(folders["Walk"]))
        let ten = GroupLibrary.june14 + 10 * 3600
        // Every 2 s from two cameras, a pause of 20 s, every 2 s again; a walk the next day.
        var photos: [PhotoRecord] = []
        let (a, b) = try await sandbox.index.write { writer in
            try (writer.cameraID(for: "Nikon Z 6"), writer.cameraID(for: "Nikon Z 6II"))
        }
        for shot in 0 ..< 10 {
            photos.append(PhotoRecord(
                folder: wedding, name: "W\(shot).NEF", captured: Date(timeIntervalSince1970: ten + Double(shot) * 2.5),
                camera: shot % 2 == 0 ? a : b,
            ))
            photos.append(PhotoRecord(
                folder: wedding, name: "X\(shot).NEF",
                captured: Date(timeIntervalSince1970: ten + 42.5 + Double(shot) * 2), camera: a,
            ))
        }
        for shot in 0 ..< 30 {
            photos.append(PhotoRecord(
                folder: walk, name: "WALK\(shot).JPG",
                captured: Date(timeIntervalSince1970: ten + 86400 + Double(shot * 400)), camera: b,
            ))
        }
        photos.append(PhotoRecord(folder: walk, name: "SCAN.TIF"))
        try await sandbox.upsert(photos)
        let engine = QueryEngine(index: sandbox.index, timeZone: .gmt)
        try await engine.load()
        let grouping = try await engine.grouping(stacks: StackFinder.find(
            in: sandbox.index,
            store: #require(engine.store),
        ))
        let list = try await engine.list(.allPhotographs)

        let tightest = grouping.moments(of: list, setting: MomentSetting(looseness: MomentSetting.tightest))
        #expect(tightest.map(\.count) == [10, 10, 30, 1])
        #expect(tightest.map { $0.filter?.description } == [
            "date:2025-06-14T10:00:00..2025-06-14T10:00:22", "date:2025-06-14T10:00:42..2025-06-14T10:01:00",
            "date:2025-06-15T10:00:00..2025-06-15T13:13:20", nil,
        ])
        let byDefault = grouping.moments(of: list)
        #expect(byDefault.map(\.count) == [20, 30, 1], "a pause of 20 s doesn't start a moment by default")
        for (setting, key) in [(MomentSetting.tightest, GroupKey.moment), (0, .moment), (-4, .momentCamera)] {
            let groups = grouping.groups(of: list, by: key, setting: MomentSetting(looseness: setting))
            for group in groups {
                guard let filter = group.filter else {
                    #expect(group.span == nil, "\(key) \(group.name)")
                    continue
                }
                #expect(try LibraryQuery(parsing: filter.description) == filter)
                let columns = try await engine.list(.allPhotographs, matching: filter)
                #expect(Set(columns.ids) == Set(group.photos), "\(key) \(group.name): \(filter)")
                let sql = try await sandbox.index.read { reader in
                    var ids: [Int64] = []
                    try reader.run(
                        QuerySQL(filter.searchable, sort: QuerySort(), today: 0),
                        cancellation: QueryCancellation(),
                    ) {
                        ids.append($0)
                    }
                    return ids
                }
                #expect(sql == Array(columns.ids), "\(key) \(group.name): \(filter)")
            }
        }
        let split = grouping.groups(
            of: list,
            by: .momentCamera,
            setting: MomentSetting(looseness: MomentSetting.tightest),
        )
        #expect(split.first?.filter?.description
            == #"date:2025-06-14T10:00:00..2025-06-14T10:00:20 camera:"Nikon Z 6" -camera:"Nikon Z 6II""#)
    }
}
