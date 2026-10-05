import Foundation
import RedlampDocument
import Synchronization

public extension BenchScenarios {
    /// Adds the photo lists' scenario (LIB-10) after the others, at `photos` photos held in memory,
    /// then on the fixture.
    static func registerLists(photos: Int = ListScenario.defaultPhotos) {
        register(ListScenario(photos: photos))
    }
}

/// Photo lists and selections (LIB-10): first at a million photos held in the column store, as the
/// query engine's own benchmark holds them, then over an index of the fixture. It makes All
/// Photographs in capture order, a folder with its subfolders and a query's list from the store;
/// selects all of All Photographs, inverts a selection of half of it and extends a selection from a
/// quarter of the way in to three quarters, as the main thread does inside a frame; and changes,
/// adds and removes 1,000 photos, then brings the store up to date and makes the list again with its
/// diff. The design's budgets, at a million: a list made under 50 ms and a diff under 50 ms, both off
/// the main thread, and each change to a selection under 2 ms. On the fixture, each list holds as
/// many photos as the manifest says; everywhere, each diff applied to the list before gives the list
/// after. Each step is timed `runs` times: its median is held to the budget, and its slowest
/// reported beside it, since the Macs this runs on are often busy with other builds.
public struct ListScenario: BenchScenario {
    public static let defaultPhotos = 1_000_000
    static let listBudget = 50.0
    static let diffBudget = 50.0
    /// Microseconds.
    static let selectionBudget = 2000.0
    static let runs = 7
    static let changes = 1000

    public let name = "lists"
    public let photos: Int
    let indexFolder: URL?

    public init(photos: Int = ListScenario.defaultPhotos) {
        self.init(photos: photos, indexFolder: nil)
    }

    /// Keeps the fixture's index in `indexFolder` rather than in the temporary folder.
    init(photos: Int, indexFolder: URL?) {
        self.photos = max(photos, 8)
        self.indexFolder = indexFolder
    }

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        let synthetic = try await measureSynthetic()
        return try await synthetic + measureFixture(context)
    }

    // MARK: - In memory

    private func measureSynthetic() async throws -> [BenchResult] {
        let library = SyntheticListLibrary(count: photos)
        var builder = ColumnStore.Builder(capacity: photos)
        for id in 1 ... Int64(photos) {
            builder.add(library.row(id))
        }
        let source = SyntheticListSource(library: library, store: builder.finish())
        let engine = QueryEngine(source: source, timeZone: .gmt)
        try await engine.load()
        let size = BenchResult.grouped(photos)
        let folder = URL(fileURLWithPath: SyntheticListLibrary.root + "/Archive", isDirectory: true)
        var (results, lists) = try await makeLists(engine, prefix: "library-lists", of: size, [
            ("all", "All Photographs in capture order", .allPhotographs),
            ("folder", "A folder with its subfolders", .folder(folder, includingSubfolders: true)),
            ("query", "rating>=3", .query(LibraryQuery(parsing: "rating>=3"))),
        ], budget: .below(Self.listBudget, "ms"))
        guard let all = lists.first else { return results }
        results += select(in: all, prefix: "library-lists", of: size, budget: .below(Self.selectionBudget, "µs"))

        var random = SeededRandom(seed: 2026)
        var changed = Changed()
        var next = Int64(photos) + 1
        for _ in 0 ..< Self.runs {
            let count = min(Self.changes, photos / 4) / 3
            let before = try await engine.list(.allPhotographs)
            let ordered = Self.pick(2 * count, of: before, &random)
            let (updated, removed) = (Array(ordered.prefix(count)), Array(ordered.dropFirst(count)))
            let inserted = (0 ..< min(Self.changes, photos / 4) - 2 * count).map { next + Int64($0) }
            next += Int64(inserted.count)
            source.stage(updated.map { library.row($0, changed: true) } + inserted.map { library.row($0) })
            try await diff(before, changing: updated + removed + inserted, in: engine, into: &changed)
        }
        return results + changeResults(
            changed, count: min(Self.changes, photos / 4), of: size, prefix: "library-lists",
            budget: .below(Self.diffBudget, "ms"),
        )
    }

    // MARK: - On the fixture

    private func measureFixture(_ context: BenchContext) async throws -> [BenchResult] {
        let setup = try await QueryScenario.engine(for: context, in: indexFolder)
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-bench-lists-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = try await setup.index.snapshot(to: folder)
        await setup.index.close()
        let index = try await LibraryIndex.open(at: copy)
        let engine = QueryEngine(index: index)
        try await engine.load()

        let manifest = context.manifest
        var sources: [(id: String, name: String, source: PhotoSource)] = try [
            ("all", "All Photographs in capture order", .allPhotographs),
            ("query", "rating>=3", .query(LibraryQuery(parsing: "rating>=3"))),
            ("rejected", "Rejected", .rejected),
        ]
        var expected = [manifest.totals.photos, manifest.count(of: "rating>=3"), manifest.count(of: "flag:reject")]
        if let top = Self.largestTopFolder(in: manifest) {
            let url = context.fixture.appending(path: top.path, directoryHint: .isDirectory)
            sources.insert(
                ("folder", "\(top.path) with its subfolders", .folder(url, includingSubfolders: true)),
                at: 1,
            )
            expected.insert(top.photos, at: 1)
        }
        let size = BenchResult.grouped(manifest.totals.photos)
        var (results, lists) = try await makeLists(engine, prefix: "library-lists-fixture", of: size, sources)
        for (entry, (list, count)) in zip(sources, zip(lists, expected)) {
            results.append(BenchResult(
                scenario: name, id: "library-lists-fixture-\(entry.id)-count", name: "Photos in \(entry.name)",
                value: Double(list.count), unit: "photos", budget: .exactly(Double(count ?? -1), "photos"),
            ))
        }
        guard let all = lists.first else { return results }
        results += select(in: all, prefix: "library-lists-fixture", of: size)

        let count = max(min(Self.changes, manifest.totals.photos / 4) / 3, 1)
        let before = try await engine.list(.allPhotographs)
        var random = SeededRandom(seed: 7)
        let ordered = Self.pick(min(2 * count, before.count), of: before, &random)
        let (updated, removed) = (Array(ordered.prefix(count)), Array(ordered.dropFirst(count)))
        let inserted = try await index.write { writer -> [Int64] in
            var moved: [PhotoRecord] = []
            for (number, id) in updated.enumerated() {
                guard var photo = try writer.photo(id: id) else { continue }
                photo.rating = (photo.rating + 1) % 6
                if number.isMultiple(of: 2) {
                    photo.captured = (photo.captured ?? Date(timeIntervalSince1970: 0)).addingTimeInterval(86400 * 400)
                }
                moved.append(photo)
            }
            try writer.upsertPhotos(moved)
            let template = try updated.first.flatMap { try writer.photo(id: $0) }
            let added = (0 ..< max(min(Self.changes, manifest.totals.photos / 4) - 2 * count, 1)).compactMap { number in
                template.map { template in
                    PhotoRecord(
                        folder: template.folder, name: "LISTBENCH_\(number).JPG", size: 1,
                        captured: Date(timeIntervalSince1970: 1_400_000_000 + Double(number) * 977),
                        rating: number % 6,
                    )
                }
            }
            let ids = try writer.upsertPhotos(added)
            try writer.deletePhotos(removed)
            return ids
        }
        var changed = Changed()
        try await diff(before, changing: updated + removed + inserted, in: engine, into: &changed)
        await index.close()
        return results + changeResults(
            changed, count: updated.count + removed.count + inserted.count, of: size, prefix: "library-lists-fixture",
            budget: nil,
        )
    }

    /// `count` different photos of `list`, in ID order.
    static func pick(_ count: Int, of list: PhotoList, _ random: inout SeededRandom) -> [Int64] {
        var picked = Set<Int64>()
        while picked.count < min(count, list.count) {
            picked.insert(list[random.int(below: list.count)])
        }
        return picked.sorted()
    }

    /// The top folder whose photos and its subfolders' are the most, and how many there are.
    static func largestTopFolder(in manifest: FixtureManifest) -> (path: String, photos: Int)? {
        let tops = Set(manifest.folders.map { String($0.path.split(separator: "/").first ?? "") })
        return tops.filter { !$0.isEmpty }.map { top in
            (
                top,
                manifest.folders.filter { $0.path == top || $0.path.hasPrefix(top + "/") }.reduce(0) { $0 + $1.photos },
            )
        }.max { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 > $1.0) }
    }

    // MARK: - Steps

    /// Durations of a step timed several times.
    struct Timings {
        private(set) var samples: [Duration] = []

        mutating func add(_ duration: Duration) {
            samples.append(duration)
        }

        var median: Duration {
            let sorted = samples.sorted()
            return sorted.isEmpty ? .zero : sorted[sorted.count / 2]
        }

        var slowest: Duration {
            samples.max() ?? .zero
        }
    }

    /// A step's median, under `budget`, and its slowest, in milliseconds or microseconds.
    private func timed(
        _ timings: Timings, id: String, name: String, inMicroseconds: Bool = false, budget: BenchBudget? = nil,
    ) -> [BenchResult] {
        let (unit, value) = inMicroseconds ? ("µs", Self.microseconds) : ("ms", Self.milliseconds)
        guard timings.samples.count > 1 else {
            return [BenchResult(
                scenario: self.name, id: id, name: name, value: value(timings.median), unit: unit, budget: budget,
            )]
        }
        return [
            BenchResult(
                scenario: self.name, id: id, name: "\(name), median of \(timings.samples.count)",
                value: value(timings.median), unit: unit, budget: budget,
            ),
            BenchResult(
                scenario: self.name, id: id + "-slowest", name: "\(name), slowest", value: value(timings.slowest),
                unit: unit,
            ),
        ]
    }

    /// Makes each source's list `runs` times: how long it took, and the lists.
    private func makeLists(
        _ engine: QueryEngine, prefix: String, of size: String,
        _ sources: [(id: String, name: String, source: PhotoSource)], budget: BenchBudget? = nil,
    ) async throws -> ([BenchResult], [PhotoList]) {
        let clock = ContinuousClock()
        var results: [BenchResult] = []
        var lists: [PhotoList] = []
        for entry in sources {
            var timings = Timings()
            var list: PhotoList?
            for _ in 0 ..< Self.runs {
                let started = clock.now
                list = try await engine.list(entry.source)
                timings.add(clock.now - started)
            }
            guard let list else { continue }
            lists.append(list)
            results += timed(
                timings, id: "\(prefix)-\(entry.id)",
                name: "\(entry.name) of \(size), made (\(BenchResult.grouped(list.count)) photos)", budget: budget,
            )
        }
        return (results, lists)
    }

    /// Times selecting all of `list`, inverting a selection of half of it, extending one across half
    /// of it, and listing the selected photos in order.
    private func select(in list: PhotoList, prefix: String, of size: String, budget: BenchBudget? = nil)
        -> [BenchResult] {
        guard list.count >= 4 else { return [] }
        let clock = ContinuousClock()
        var (all, invert, extend, ids) = (Timings(), Timings(), Timings(), Timings())
        var selected = 0
        for _ in 0 ..< Self.runs {
            var selection = PhotoSelection()
            selection.select(list[list.count / 4], in: list)
            var started = clock.now
            selection.extend(to: list[list.count * 3 / 4], in: list)
            extend.add(clock.now - started)
            selected = selection.count
            started = clock.now
            let selectedIDs = selection.ids(in: list)
            ids.add(clock.now - started)
            selected = min(selected, selectedIDs.count)
            started = clock.now
            selection.invert(in: list)
            invert.add(clock.now - started)
            started = clock.now
            selection.selectAll(in: list)
            all.add(clock.now - started)
        }
        let span = list.count * 3 / 4 - list.count / 4 + 1
        let half = BenchResult.grouped(span)
        return timed(
            all,
            id: "\(prefix)-select-all",
            name: "All \(size) selected",
            inMicroseconds: true,
            budget: budget,
        )
            + timed(
                invert, id: "\(prefix)-invert", name: "A selection of \(half) inverted", inMicroseconds: true,
                budget: budget,
            )
            + timed(
                extend, id: "\(prefix)-extend", name: "A selection extended across \(half)", inMicroseconds: true,
                budget: budget,
            )
            + [BenchResult(
                scenario: name, id: "\(prefix)-extended", name: "Photos the extended selection holds",
                value: Double(selected), unit: "photos", budget: .exactly(Double(span), "photos"),
            )]
            + timed(ids, id: "\(prefix)-selected-ids", name: "The \(half) selected, in order")
    }

    /// How long changes took, each step timed: the store brought up to date, All Photographs made
    /// again, and its diff; and how many photos the diffs applied to the lists before didn't put
    /// where the lists after have them.
    struct Changed {
        var store = Timings()
        var list = Timings()
        var diff = Timings()
        var total = Timings()
        var mismatched = 0
    }

    /// Brings the store up to date with photos `changed`, then makes All Photographs again with its
    /// diff from `before`, adding the times to `timed`.
    private func diff(
        _ before: PhotoList, changing changed: [Int64], in engine: QueryEngine, into timed: inout Changed,
    ) async throws {
        let clock = ContinuousClock()
        var started = clock.now
        try await engine.update(photos: changed)
        timed.store.add(clock.now - started)
        started = clock.now
        let after = try await engine.list(.allPhotographs)
        let made = clock.now - started
        started = clock.now
        let diff = PhotoListDiff(from: before, to: after, changed: changed)
        let diffed = clock.now - started
        timed.list.add(made)
        timed.diff.add(diffed)
        timed.total.add(made + diffed)
        var ids = Array(before.ids)
        diff.apply(to: &ids) { after[$0] }
        timed.mismatched += ids.count == after.count ? zip(ids, after).count { $0 != $1 } : max(ids.count, after.count)
    }

    /// The results of `changed`, `count` photos changed, added and removed each time, as `prefix`
    /// names them.
    private func changeResults(_ changed: Changed, count: Int, of size: String, prefix: String, budget: BenchBudget?)
        -> [BenchResult] {
        let changes = "\(BenchResult.grouped(count)) photos changed, added and removed"
        return timed(changed.store, id: "\(prefix)-store-changed", name: "\(changes): the store brought up to date")
            + timed(changed.list, id: "\(prefix)-remade", name: "\(changes): All Photographs of \(size) made again")
            + timed(changed.diff, id: "\(prefix)-diff-only", name: "\(changes): its diff", inMicroseconds: true)
            + timed(
                changed.total, id: "\(prefix)-diff", name: "\(changes): All Photographs made again with its diff",
                budget: budget,
            )
            + [BenchResult(
                scenario: name, id: "\(prefix)-diff-mismatched", name: "Photos a diff didn't put in place",
                value: Double(changed.mismatched), unit: "photos", budget: .exactly(0, "photos"),
            )]
    }

    static func milliseconds(_ duration: Duration) -> Double {
        duration / .milliseconds(1)
    }

    static func microseconds(_ duration: Duration) -> Double {
        duration / .microseconds(1)
    }
}

/// A million photos as the column store holds them, made from their IDs: folders by archive or
/// client, year and month; capture times over 20 years; a third rated, a twentieth picked and as
/// many rejected, a tenth labelled.
struct SyntheticListLibrary: Sendable {
    static let root = "/Volumes/Million"
    let names: QueryNames
    private let leaves: [Int64]

    init(count _: Int) {
        var names = QueryNames()
        var leaves: [Int64] = []
        func add(_ path: String) -> Int64 {
            let id = Int64(names.folders.count + 1)
            names.folders[id] = path
            return id
        }
        _ = add(Self.root)
        for top in ["Archive", "Clients"] {
            _ = add(Self.root + "/" + top)
            for year in 2006 ..< 2026 {
                _ = add("\(Self.root)/\(top)/\(year)")
                for month in 1 ... 12 {
                    leaves.append(add("\(Self.root)/\(top)/\(year)/\(year)-\(month < 10 ? "0" : "")\(month)"))
                }
            }
        }
        for camera in 1 ... 25 {
            names.cameras[Int64(camera)] = "Camera \(camera)"
        }
        for lens in 1 ... 40 {
            names.lenses[Int64(lens)] = "Lens \(lens)"
        }
        self.names = names
        self.leaves = leaves
    }

    /// Photo `id`'s row; `changed`, with another rating, and for half of them another capture time.
    func row(_ id: Int64, changed: Bool = false) -> ColumnStore.Row {
        var hash = UInt64(bitPattern: id) &* 0x9E37_79B9_7F4A_7C15
        hash = (hash ^ (hash >> 30)) &* 0xBF58_476D_1CE4_E5B9
        hash = (hash ^ (hash >> 27)) &* 0x94D0_49BB_1331_11EB
        hash ^= hash >> 31
        let half = leaves.count / 2
        let folder = leaves[(hash % 100 < 70 ? 0 : half) + Int(hash >> 8 % UInt64(half))]
        var captured = 1_136_073_600 + Double(hash >> 16 % 631_152_000)
        var rating = hash >> 24 % 3 == 0 ? Int(1 + hash >> 28 % 5) : 0
        if changed {
            rating = (rating + 1) % 6
            if id.isMultiple(of: 2) {
                captured += 86400 * 400
            }
        }
        let flag = hash >> 32 % 20
        return ColumnStore.Row(HotColumns(
            id: id, folder: folder, captured: captured, camera: Int64(1 + hash >> 36 % 25),
            lens: Int64(1 + hash >> 41 % 40), rating: rating, flag: flag == 0 ? 1 : flag == 1 ? 2 : 0,
            label: hash >> 47 % 10 == 0 ? 1 : 0, marked: false, edited: hash >> 51 % 4 == 0,
            iso: Double(100 << (hash >> 53 % 6)), aperture: 2.8, focal: 35, kind: PhotoRecord.Kind.raw.rawValue,
            name: Self.name(of: id),
        ))
    }

    static func name(of id: Int64) -> String {
        let digits = String(id)
        return "IMG_" + String(repeating: "0", count: max(0, 7 - digits.count)) + digits + ".ARW"
    }
}

/// The query engine's source for a `SyntheticListLibrary` held in memory, with changed and added
/// photos' rows staged before the engine reads them.
final class SyntheticListSource: QuerySource {
    struct Unsupported: Error {}

    let library: SyntheticListLibrary
    let store: ColumnStore
    private let staged = Mutex<[Int64: ColumnStore.Row]>([:])

    init(library: SyntheticListLibrary, store: ColumnStore) {
        self.library = library
        self.store = store
    }

    /// The rows `applying` gives the photos in `rows`; a photo asked for without one is removed.
    func stage(_ rows: [ColumnStore.Row]) {
        staged.withLock { staged in
            for row in rows {
                staged[row.hot.id] = row
            }
        }
    }

    func columnStore() async throws -> ColumnStore {
        store
    }

    func names() async throws -> QueryNames {
        library.names
    }

    func photoIDs(matching _: String) async throws -> [Int64] {
        []
    }

    func photoIDs(withKeywords _: [Int64]) async throws -> [Int64] {
        []
    }

    func photoIDs(inCollections _: [Int64]) async throws -> [Int64] {
        []
    }

    func applying(_ ids: [Int64], to store: ColumnStore) async throws -> ColumnStore {
        let rows = staged.withLock { staged in ids.compactMap { staged.removeValue(forKey: $0) } }
        let found = Set(rows.map(\.hot.id))
        var store = store
        store.apply(ColumnStore.Changes(upserted: rows, removed: ids.filter { !found.contains($0) })) {
            SyntheticListLibrary.name(of: $0)
        }
        return store
    }

    func run(
        _: QuerySQL, pageSize _: Int, cancellation _: QueryCancellation,
        firstPage _: @escaping @Sendable (ContiguousArray<Int64>) -> Void,
    ) async throws -> ContiguousArray<Int64> {
        throw Unsupported()
    }
}
