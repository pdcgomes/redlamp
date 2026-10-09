import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

struct ColumnStoreTests {
    /// Rows like a library's, from a seed: names that tie and differ only by case or zeros, capture
    /// times that tie or are missing, edits saved at different times.
    static func rows(_ count: Int, seed: UInt64, firstID: Int64 = 1) -> [ColumnStore.Row] {
        var random = SeededRandom(seed: seed)
        let names = [
            "DSC_0001.ARW",
            "dsc_0001.arw",
            "DSC_1.ARW",
            "DSC_0010.ARW",
            "IMG_2.JPG",
            "IMG_10.JPG",
            "Café.jpg",
            "cafe.jpg",
            "東京-0001.JPG",
            "a.jpg",
            "a1.jpg",
            "a\u{1}.jpg",
            "Zebra.png",
            "Wedding in the hills 2.JPG",
            "Wedding in the hills 10.JPG",
            "wedding in the hills 10.jpg",
            "DSC05507.ARW",
            "DSC-5513.ARW",
            "Café_1.jpg",
            "Cafe\u{301}01.jpg",
            "Ｆｕｌｌ.jpg",
        ]
        return (0 ..< count).map { offset in
            let edited = random.chance(0.3)
            return ColumnStore.Row(
                HotColumns(
                    id: firstID + Int64(offset), folder: Int64(random.int(in: 1 ... 5)),
                    captured: random.chance(0.1) ? nil : Double(1_500_000_000 + random.int(below: 50) * 3600)
                        + (random.chance(0.2) ? 0.25 : 0),
                    camera: random.chance(0.2) ? nil : Int64(random.int(in: 1 ... 4)),
                    lens: random.chance(0.3) ? nil : Int64(random.int(in: 10 ... 13)), rating: random.int(in: 0 ... 5),
                    flag: random.int(in: 0 ... 2), label: random.int(in: 0 ... 5), marked: random.chance(0.1),
                    edited: edited, iso: random.chance(0.1) ? nil : random.pick([100, 400, 800, 3200]),
                    aperture: random.pick([1.4, 2.8, 4, 5.6]), focal: random.pick([23, 35, 50, 6.765]),
                    kind: random.int(in: 1 ... 3),
                    name: random.chance(0.5) ? random.pick(names) : "IMG_\(random.int(below: 2000)).CR3",
                ),
                shutter: random.pick([1.0 / 250, 1, 30]),
                details: random.chance(0.3) ? [.location, .caption] : [],
                sidecarModified: edited || random.chance(0.2) ? Double(1_700_000_000 + random.int(below: 1000)) : nil,
                size: Int64(random.int(below: 40)) * 1_000_000,
                modified: random.chance(0.1) ? nil : Double(1_600_000_000 + random.int(below: 30) * 60),
                state: random.chance(0.1) ? .offline : [],
            )
        }
    }

    @Test func `short text's lookups in one pass find the rows each finds alone, ORed`() {
        var rows = Self.rows(5000, seed: 71)
        for index in rows.indices {
            rows[index].creator = index % 3 == 0 ? "Ana Silva" : index % 5 == 0 ? "Abel" : nil
            if index % 4 == 0 {
                rows[index].location = PhotoLocation(country: "Portugal", city: index % 8 == 0 ? "Lisboa" : "Porto")
            }
        }
        let store = ColumnStore(rows: rows)
        let alternatives: [[QueryPlan]] = [
            [.leaf(.folders([2, 4])), .leaf(.cameras([1])), .leaf(.lenses([2, 3]))],
            [.leaf(.folders([1, 2, 3, 4, 5])), .leaf(.cameras([2])), .leaf(.lenses([1]))],
            [
                .leaf(.codes(.creator, CodeTable.make([1]))),
                .leaf(.codes(.place, CodeTable.make([1, 2]))),
                .leaf(.folders([3])),
            ],
            [.leaf(.cameras([9])), .leaf(.lenses([9]))],
            [.leaf(.folders([2])), .leaf(.cameras([1])), .leaf(.packed(shift: 0, mask: 0x7, accepted: 1 << 5))],
        ]
        for plans in alternatives {
            var expected = RowBits(rows: store.rowCount)
            for plan in plans {
                expected.formUnion(store.rows(matching: plan, sets: [:]))
            }
            #expect(store.rows(matching: .or(plans), sets: [:]) == expected, "\(plans)")
        }
    }

    /// The order the store promises, worked out from the rows themselves.
    static func expected(_ rows: [ColumnStore.Row], _ sort: QuerySort) -> [Int64] {
        func captured(_ row: ColumnStore.Row) -> Int64 {
            ColumnEncoding.captured(row.hot.captured)
        }
        let sorted = rows.sorted { lhs, rhs in
            let (left, right) = (lhs.hot, rhs.hot)
            switch sort.key {
            case .captured:
                return (captured(lhs), left.id) < (captured(rhs), right.id)
            case .name:
                let order = FinderOrder.compare(left.name, right.name)
                return order == 0 ? left.id < right.id : order < 0
            case .rating:
                return (left.rating, captured(lhs), left.id) < (right.rating, captured(rhs), right.id)
            case .edited:
                let (leftEdit, rightEdit) = (
                    ColumnEncoding.editedAt(edited: left.edited, sidecarModified: lhs.sidecarModified),
                    ColumnEncoding.editedAt(edited: right.edited, sidecarModified: rhs.sidecarModified),
                )
                return (leftEdit, captured(lhs), left.id) < (rightEdit, captured(rhs), right.id)
            case .modified:
                let (leftDate, rightDate) = (
                    ColumnEncoding.modifiedAt(lhs.modified),
                    ColumnEncoding.modifiedAt(rhs.modified),
                )
                return (leftDate, captured(lhs), left.id) < (rightDate, captured(rhs), right.id)
            case .size:
                return (lhs.size, captured(lhs), left.id) < (rhs.size, captured(rhs), right.id)
            }
        }.map(\.hot.id)
        return sort.ascending ? sorted : sorted.reversed()
    }

    static let sorts = QuerySort.Key.allCases.flatMap { [QuerySort($0), QuerySort($0, ascending: false)] }

    @Test func `a store holds each photo's row, finds it by ID and keeps every sort order`() {
        let rows = Self.rows(300, seed: 3)
        let store = ColumnStore(rows: rows)
        #expect(store.count == 300 && store.rowCount == 300)
        for row in rows {
            #expect(store.row(of: row.hot.id).map { store.ids[$0] } == row.hot.id)
        }
        #expect(store.row(of: 0) == nil && store.row(of: 301) == nil && store.row(of: -4) == nil)
        for sort in Self.sorts {
            #expect(Array(store.ids(sortedBy: sort)) == Self.expected(rows, sort), "\(sort)")
        }
        let duplicated = ColumnStore(rows: rows + [rows[0]])
        #expect(duplicated.count == 300)
    }

    @Test func `a store joined from parts read side by side is the store of all their rows`() async throws {
        let rows = Self.rows(900, seed: 4, firstID: 5)
        var parts: [ColumnStore.Part] = []
        for range in [0 ..< 250, 250 ..< 260, 260 ..< 900] {
            var part = ColumnStore.Part(capacity: range.count)
            for row in rows[range] {
                part.add(row)
            }
            parts.append(part)
        }
        let joined = await ColumnStore.joining(parts + [ColumnStore.Part()])
        let whole = ColumnStore(rows: rows)
        #expect(joined.count == 900 && joined.rowCount == 900 && joined.row(of: 4) == nil)
        for sort in Self.sorts {
            #expect(Array(joined.ids(sortedBy: sort)) == Self.expected(rows, sort), "\(sort)")
        }
        for row in rows {
            let index = try #require(joined.row(of: row.hot.id))
            let other = try #require(whole.row(of: row.hot.id))
            #expect(joined.cameraIDs[Int(joined.cameras[index])] == row.hot.camera ?? 0)
            #expect(joined.lensIDs[Int(joined.lenses[index])] == row.hot.lens ?? 0)
            #expect(joined.packed[index] == whole.packed[other] && joined.editedAt[index] == whole.editedAt[other])
            #expect(joined.nameRanks[index] == whole.nameRanks[other])
        }
    }

    @Test func `the columns hold the encodings, the codes and the packed fields`() throws {
        let rows = Self.rows(50, seed: 5)
        let store = ColumnStore(rows: rows)
        for row in rows {
            let index = try #require(store.row(of: row.hot.id))
            let hot = row.hot
            #expect(store.captured[index] == ColumnEncoding.captured(hot.captured))
            #expect(store.iso[index] == ColumnEncoding.iso(hot.iso))
            #expect(try store.aperture[index] == UInt16((#require(hot.aperture) * 100).rounded()))
            #expect(store.cameraIDs[Int(store.cameras[index])] == hot.camera ?? 0)
            #expect(store.lensIDs[Int(store.lenses[index])] == hot.lens ?? 0)
            let packed = store.packed[index]
            #expect(Packed.rating(packed) == hot.rating && Packed.flag(packed) == hot.flag)
            #expect(Packed.label(packed) == hot.label && (packed & Packed.marked != 0) == hot.marked)
            #expect((packed & Packed.details(.location) != 0) == row.details.contains(.location))
            #expect(store.folders[index] == Int32(hot.folder) && store.kinds[index] == UInt8(hot.kind))
        }
    }

    @Test func `the encodings are the ones the SQL computes`() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute("""
        CREATE TABLE photos (id INTEGER PRIMARY KEY, iso REAL, aperture REAL, focal REAL, shutter REAL, captured REAL,
          edited INTEGER, sidecar_modified REAL, rating INTEGER, flag INTEGER, label INTEGER, kind INTEGER)
        """)
        let numbers: [Double?] = [
            nil, 0, 0.4, 0.5, 0.49999999999999994, 1, 1.395, 1.405, 1.78, 2.8, 2.7999999, 6.765, 23.95, 99.5, 100,
            800.4999, 800.5, 6553.5, 65534.5, 65535, 70000, 4294.967295, 1e30, -5, -0.6, .infinity, -.infinity,
            1.0 / 8000, 1.0 / 3, 1e-9,
        ]
        let times: [Double?] = [
            nil, 0, -0.0005, 1_718_359_200.123, -86400.5, 978_307_199.5, 978_307_200, 4e9, -4e9, 1e300, -1e300,
        ]
        let insert = try database.prepare("""
        INSERT INTO photos (iso, aperture, focal, shutter, captured, edited, sidecar_modified, rating, flag, label, kind)
        VALUES (?1, ?1, ?1, ?1, ?2, ?3, ?2, ?4, ?4, ?4, ?5)
        """)
        var expected: [[Int64]] = []
        for (index, number) in numbers.enumerated() {
            let time = times[index % times.count]
            let edited = index % 3 != 0
            let small = [-1, 0, 2, 5, 9, 300][index % 6]
            try insert.bind(number, at: 1)
            try insert.bind(time, at: 2)
            try insert.bind(edited, at: 3)
            try insert.bind(small, at: 4)
            try insert.bind(small, at: 5)
            try insert.run()
            let row = ColumnStore.Row(HotColumns(
                id: 1, folder: 1, captured: time, camera: nil, lens: nil, rating: small, flag: small, label: small,
                marked: false, edited: edited, iso: number, aperture: number, focal: number, kind: small, name: "",
            ))
            let packed = Packed.pack(row)
            expected.append([
                Int64(ColumnEncoding.iso(number)), Int64(ColumnEncoding.aperture(number)),
                Int64(ColumnEncoding.focal(number)), Int64(ColumnEncoding.shutter(number)),
                ColumnEncoding.captured(time), Int64(ColumnEncoding.editedAt(edited: edited, sidecarModified: time)),
                Int64(Packed.rating(packed)), Int64(Packed.flag(packed)), Int64(Packed.label(packed)),
                Int64(UInt8(clamping: small)),
            ])
        }
        let expressions = [
            ColumnEncoding.isoSQL, ColumnEncoding.apertureSQL, ColumnEncoding.focalSQL, ColumnEncoding.shutterSQL,
            ColumnEncoding.capturedSQL, ColumnEncoding.editedAtSQL, ColumnEncoding.ratingSQL, ColumnEncoding.flagSQL,
            ColumnEncoding.labelSQL, ColumnEncoding.kindSQL,
        ]
        let computed = try database.prepare("SELECT \(expressions.joined(separator: ", ")) FROM photos p ORDER BY id")
            .map { row in (0 ..< Int32(expressions.count)).map { row.int64(at: $0) } }
        #expect(computed.count == expected.count)
        for (index, (sql, swift)) in zip(computed, expected).enumerated() {
            #expect(sql == swift, "row \(index): \(String(describing: numbers[index]))")
        }
    }

    @Test func `changes add, update and remove rows, and leave every order as a new store would have it`() throws {
        var current = Dictionary(uniqueKeysWithValues: Self.rows(200, seed: 7).map { ($0.hot.id, $0) })
        var store = ColumnStore(rows: current.values)
        var random = SeededRandom(seed: 8)
        var nextID: Int64 = 1000
        for round in 0 ..< 6 {
            var upserted: [ColumnStore.Row] = []
            var removed: [Int64] = []
            let existing = current.keys.sorted()
            for id in existing where random.chance(0.15) {
                removed.append(id)
                current[id] = nil
            }
            for id in existing where current[id] != nil && random.chance(0.15) {
                var row = Self.rows(1, seed: UInt64(round * 1000) + UInt64(id), firstID: id)[0]
                row.hot.folder = try #require(current[id]?.hot.folder)
                upserted.append(row)
                current[id] = row
            }
            for row in Self.rows(random.int(in: 0 ... 40), seed: UInt64(round + 100), firstID: nextID) {
                upserted.append(row)
                current[row.hot.id] = row
            }
            nextID += 100
            let changed = Set(upserted.map(\.hot.id))
            var asked: Set<Int64> = []
            store.apply(ColumnStore.Changes(upserted: upserted, removed: removed + [999_999])) { id in
                asked.insert(id)
                return current[id]?.hot.name
            }
            #expect(asked.isDisjoint(with: changed), "photos in the changes aren't asked about")
            let rows = Array(current.values)
            #expect(store.count == rows.count)
            for id in removed {
                #expect(store.row(of: id) == nil)
            }
            for sort in Self.sorts {
                #expect(Array(store.ids(sortedBy: sort)) == Self.expected(rows, sort), "round \(round), \(sort)")
            }
        }
        let beforeCompacting = store
        store.compact()
        #expect(store.rowCount == store.count && beforeCompacting.rowCount > store.rowCount)
        for sort in Self.sorts {
            #expect(store.ids(sortedBy: sort) == beforeCompacting.ids(sortedBy: sort))
        }
        for id in current.keys {
            #expect(store.row(of: id).map { store.ids[$0] } == id)
        }
    }

    @Test func `the name order is Folders': digits by value, case, accents and width folded, an ASCII name first`() {
        let ascending = [
            ("a.jpg", "a1.jpg"), ("a1.jpg", "ab.jpg"), ("IMG_2.JPG", "IMG_10.JPG"), ("DSC_0009.ARW", "DSC_0010.ARW"),
            ("Été", "Ezz"), ("Zebra", "東京"), ("DSC_0001.ARW", "DSCF0001.RAF"), ("a 2.jpg", "a-2.jpg"),
            ("DSC05507.ARW", "DSC_5513.ARW"), ("a-2.jpg", "a2.jpg"), ("a2.jpg", "a_2.jpg"), ("cafe", "Café"),
            ("full", "Ｆｕｌｌ"), ("Café", "Cafe 2"),
        ]
        for (first, second) in ascending {
            #expect(FinderOrder.compare(first, second) < 0, "\(first) before \(second)")
            #expect(FinderOrder.compare(second, first) > 0, "\(second) after \(first)")
            #expect(FinderOrder.key(first).lexicographicallyPrecedes(FinderOrder.key(second)), "\(first)'s key first")
            #expect(FileOrder.precedes(first, second), "and in Folders")
        }
        for (first, second) in [("img_0001.jpg", "IMG_1.JPG"), ("Café", "café"), ("Caf\u{E9}", "Cafe\u{301}")] {
            #expect(FinderOrder.compare(first, second) == 0, "\(first) and \(second)")
            #expect(FinderOrder.key(first) == FinderOrder.key(second))
        }
    }

    @Test func `a photo takes about 90 bytes, its sort orders included`() {
        let store = ColumnStore(rows: Self.rows(100_000, seed: 9))
        let perPhoto = Double(store.memoryFootprint) / Double(store.count)
        print("Column store: \(store.memoryFootprint) bytes for \(store.count) photos, \(perPhoto) bytes a photo")
        #expect(perPhoto < 94)
    }
}
