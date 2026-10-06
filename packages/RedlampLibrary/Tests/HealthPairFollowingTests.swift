import Foundation
import Testing
@testable import RedlampLibrary

/// The pairs check following the column store's changes (LIB-40, LIB-28): whatever changed, what it
/// finds is what finding every pair again finds.
struct HealthPairFollowingTests {
    static func photo(_ row: ColumnStore.Row) -> HealthPairs.Photo {
        HealthPairs.Photo(id: row.hot.id, folder: row.hot.folder, name: row.hot.name, kind: UInt8(row.hot.kind))
    }

    /// What finding every stack in `store` again finds under `rule`, `rows` holding its photos.
    static func recount(_ rule: PairRule, store: ColumnStore, rows: [Int64: ColumnStore.Row]) -> HealthFindings {
        var names = StackNames()
        for row in rows.values {
            names[row.hot.id] = row.hot.name
        }
        let drops = HealthChecker.drops(rule, in: StackFinder.find(in: store, names: names), store: store)
        return HealthChecker.findings(rule, drops: drops, store: store, names: names, texts: [:]) { _ in false }
    }

    static func byPhoto(_ findings: HealthFindings) -> [HealthFinding] {
        findings.findings.sorted { $0.photo < $1.photo }
    }

    @Test func `the pairs followed through random changes are what a full recount finds`() async throws {
        let sandbox = try await HealthSandbox.make([:])
        defer { sandbox.remove() }
        let checker = HealthChecker(index: sandbox.index, paths: sandbox.paths)
        let library = SyntheticStackLibrary(photos: 3000, seed: 11)
        var rows = Dictionary(uniqueKeysWithValues: library.rows.map { ($0.hot.id, $0) })
        var store = library.store()
        var pairs = HealthPairs(library.rows.map(Self.photo))
        var random = SeededRandom(seed: 7, stream: 40)
        var next = Int64(library.rows.count + 1)
        let extensions = ["ARW", "JPG", "HEIC", "jpeg", "png", ""]
        var asked = 0
        for round in 0 ..< 80 {
            var changed = Set<Int64>()
            let count = round % 9 == 4 ? HealthPairs.patched + 40 : 1 + random.int(below: 4)
            for _ in 0 ..< count {
                guard var row = rows[random.pick(Array(rows.keys))] else { continue }
                let other = rows[random.pick(Array(rows.keys))]?.hot
                let base = other.map { NamingJob.split($0.name).base } ?? "IMG"
                switch random.int(below: 8) {
                case 0:
                    row.hot.name = base + "." + random.pick(extensions)
                    row.hot.folder = other?.folder ?? row.hot.folder
                case 1:
                    row.hot.name = "Alone \(next)." + NamingJob.split(row.hot.name).ext
                case 2:
                    rows[row.hot.id] = nil
                    changed.insert(row.hot.id)
                    continue
                case 3:
                    row.hot.id = next
                    row.hot.folder = other?.folder ?? row.hot.folder
                    row.hot.name = base.uppercased() + "." + random.pick(extensions)
                    next += 1
                case 4:
                    row.state = row.state.contains(.unreadable) ? [] : .unreadable
                case 5:
                    row.hot.rating = random.int(below: 6)
                    row.hot.flag = random.int(below: 2)
                case 6:
                    row.hot.folder = other?.folder ?? row.hot.folder
                default:
                    row.hot.edited.toggle()
                }
                row.hot.kind = PhotoRecord.Kind(pathExtension: NamingJob.split(row.hot.name).ext).rawValue
                rows[row.hot.id] = row
                changed.insert(row.hot.id)
            }
            let ids = Array(changed)
            store.apply(ColumnStore.Changes(
                upserted: ids.compactMap { rows[$0] }, removed: ids.filter { rows[$0] == nil },
            )) { rows[$0]?.hot.name }
            pairs.update(ids, to: ids.compactMap { rows[$0] }.map(Self.photo))
            for rule in [PairRule.keepRaw, .keepJPEG] where round % 3 != 0 || rule == .keepRaw {
                let followed = try await checker.pairs(rule, store: store, following: &pairs)
                let recount = Self.recount(rule, store: store, rows: rows)
                #expect(Self.byPhoto(followed) == Self.byPhoto(recount), "round \(round), \(rule)")
                asked += followed.findings.count
            }
        }
        #expect(asked > 1000)
    }

    @Test func `pairs are listed by folder and by name, whatever order the photos came in`() async throws {
        let sandbox = try await HealthSandbox.make([:])
        defer { sandbox.remove() }
        let checker = HealthChecker(index: sandbox.index, paths: sandbox.paths)
        let library = SyntheticStackLibrary(photos: 2000, seed: 3)
        let store = library.store()
        var forwards = HealthPairs(library.rows.map(Self.photo))
        var backwards = HealthPairs(library.rows.reversed().map(Self.photo))
        let found = try await checker.pairs(.keepRaw, store: store, following: &forwards)
        #expect(try await checker.pairs(.keepRaw, store: store, following: &backwards) == found)
        #expect(found.findings.count == library.pairs)
    }
}
