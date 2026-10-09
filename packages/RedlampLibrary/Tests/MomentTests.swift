import Foundation
import Testing
@testable import RedlampLibrary

/// Moments (LIB-41): photos taken together, found from pauses in capture time.
struct MomentTests {
    private static let june14 = GroupLibrary.june14

    @Test func `moments split at the pauses of a wedding's cadence and a walk's`() throws {
        var library = GroupLibrary()
        let ceremony = library.shoot(200, from: Self.june14 + 14 * 3600) { Double(3 + $0 % 6) }
        let reception = try library.shoot(150, from: #require(library.photo(ceremony[199]).captured) + 300) {
            Double(2 + $0 % 5)
        }
        let morning = library.shoot(40, from: Self.june14 + 86400 + 9 * 3600) { 75 + Double($0 * 37 % 206) }
        let afternoon = try library.shoot(30, from: #require(library.photo(morning[39]).captured) + 50 * 60) {
            75 + Double($0 * 53 % 206)
        }
        let moments = library.grouping().moments(of: library.list)
        #expect(moments.photoSets == [ceremony, reception, morning, afternoon])
        #expect(moments.map(\.value) == [.moment(0), .moment(1), .moment(2), .moment(3)])
        #expect(moments.first?.name == "14 June 2025, 14:00 to 14:18")
        #expect(moments.last?.name.hasPrefix("15 June 2025, 11:") == true)
        #expect(moments.allSatisfy { $0.filter != nil && $0.picks == 0 })
        #expect(moments.first?.filter?.description == "date:2025-06-14T14:00:00..2025-06-14T14:18:12")
        let span = try #require(moments.first?.span)
        #expect(span.lowerBound.timeIntervalSince1970 == Self.june14 + 14 * 3600)
        #expect(span.upperBound.timeIntervalSince1970 == Self.june14 + 14 * 3600 + 1092)
    }

    @Test func `looser never finds more moments than tighter, each looser moment holding whole tighter ones`() {
        let library = Self.mixed(seed: 41)
        let grouping = library.grouping()
        var previous: PhotoGroups?
        var counts: [Int] = []
        for looseness in MomentSetting.tightest ... MomentSetting.loosest {
            let moments = grouping.moments(of: library.list, setting: MomentSetting(looseness: looseness))
            if let previous {
                #expect(moments.count <= previous.count, "\(looseness)")
                for tighter in previous {
                    #expect(Set(tighter.photos.map { moments.index(of: $0) }).count == 1, "\(looseness)")
                }
            }
            #expect(moments.reduce(0) { $0 + $1.count } == library.photos.count)
            counts.append(moments.count)
            previous = moments
        }
        #expect(counts.first ?? 0 > counts.last ?? 0, "\(counts)")
    }

    @Test func `the same photos give the same moments in whatever order they arrive`() {
        let library = Self.mixed(seed: 7)
        let grouping = library.grouping()
        let moments = grouping.moments(of: library.list)
        var random = SeededRandom(seed: 12)
        for _ in 0 ..< 3 {
            let shuffled = PhotoList(
                source: .allPhotographs, sort: QuerySort(),
                ids: ContiguousArray(library.list.ids.shuffled(using: &random)),
            )
            let again = grouping.moments(of: shuffled)
            #expect(again.map(\.name) == moments.map(\.name))
            #expect(again.map(\.value) == moments.map(\.value))
            #expect(again.map { Set($0.photos) } == moments.map { Set($0.photos) })
            for (index, group) in again.enumerated() {
                #expect(Array(group.photos) == shuffled.ids.filter { again.index(of: $0) == index })
            }
        }
    }

    @Test func `photos taken at the same time go by name, then by ID`() {
        var library = GroupLibrary()
        library.folders[2] = "/Volumes/Test/Photos/Other"
        let time = Self.june14 + 12 * 3600
        let b = library.add("B.JPG", at: time)
        let a2 = library.add("A.JPG", at: time, folder: 2)
        let a3 = library.add("A.JPG", at: time)
        let ten = library.add("IMG_10.JPG", at: time)
        let nine = library.add("IMG_9.JPG", at: time)
        let earlier = library.add("Z.JPG", at: time - 1)
        let grouping = library.grouping()
        let expected = [earlier, a2, a3, b, nine, ten]
        let list = PhotoList(source: .allPhotographs, ids: [ten, b, a3, earlier, nine, a2])
        #expect(grouping.captureOrder(of: list, rows: grouping.rows(of: list)).places.map { list[Int($0)] } == expected)

        for name in 0 ..< 100 {
            library.add("Other \(name).JPG", at: time + 3600 + Double(name))
        }
        let larger = library.grouping()
        #expect(larger.captureOrder(of: list, rows: larger.rows(of: list)).places.map { list[Int($0)] } == expected)
        #expect(larger.moments(of: list).photoSets == [list.ids.map(\.self)])
    }

    @Test func `photos without a capture time are a group of their own, last`() {
        var library = GroupLibrary()
        let first = library.shoot(5, from: Self.june14 + 10 * 3600) { _ in 5 }
        let undated = library.add("SCAN_0001.TIF", at: nil)
        let second = library.shoot(5, from: Self.june14 + 15 * 3600) { _ in 5 }
        let alsoUndated = library.add("SCAN_0002.TIF", at: nil)
        let list = PhotoList(
            source: .allPhotographs,
            ids: ContiguousArray([alsoUndated, 999] + second + [undated] + first),
        )
        let moments = library.grouping().moments(of: list)
        #expect(moments.photoSets == [first, second, [alsoUndated, 999, undated]])
        #expect(moments.map(\.value) == [.moment(0), .moment(1), .moment(nil)])
        #expect(moments.last?.name == "No capture time" && moments.last?.span == nil)
        #expect(moments.index(of: 999) == 2 && moments.index(of: 1000) == nil)
    }

    @Test func `two cameras whose clocks agree share their moments`() throws {
        var library = GroupLibrary()
        let start = Self.june14 + 16 * 3600
        let a = library.shoot(100, from: start, camera: 1) { _ in 4 }
        let b = library.shoot(80, from: start + 2, camera: 2) { _ in 5 }
        let later = try #require(library.photo(a[99]).captured) + 600
        let c = library.shoot(30, from: later, camera: 1) { _ in 4 }
        let d = library.shoot(30, from: later + 1.5, camera: 2) { _ in 4 }
        let moments = library.grouping().moments(of: library.list)
        #expect(moments.map { Set($0.photos) } == [Set(a + b), Set(c + d)])
    }

    @Test func `a stack is kept whole, going where its top photo goes`() throws {
        var library = GroupLibrary()
        let start = Self.june14 + 20 * 3600
        let fast = library.shoot(30, from: start) { _ in 2 }
        let end = try #require(library.photo(fast[29]).captured)
        let long = library.add("LONG_0001.NEF", at: end + 2, shutter: 30)
        let longer = library.add("LONG_0002.NEF", at: end + 33, shutter: 30)
        let later = library.shoot(20, from: start + 3600) { _ in 2 }
        let alone = library.add("ALONE.NEF", at: start + 7200)
        library.choices.stack([alone, fast[3], later[5]], top: later[5], in: library.grouping().stacks)
        let grouping = library.grouping()
        #expect(grouping.stacks.count(of: .burst) == 1 && grouping.stacks.count(of: .manual) == 1)

        let tightest = MomentSetting(looseness: MomentSetting.tightest)
        let unstacked = GroupLibrary.unstacked(library).moments(of: library.list, setting: tightest)
        #expect(unstacked.photoSets == [fast + [long], [longer], later, [alone]])
        let moments = grouping.moments(of: library.list, setting: tightest)
        #expect(moments.photoSets == [fast.filter { $0 != fast[3] } + [long, longer], [fast[3]] + later + [alone]])
        #expect(moments.map(\.value) == [.moment(0), .moment(1)])
        #expect(grouping.moments(of: library.list).photoSets == moments.photoSets)
    }

    @Test func `bursts and a raw beside its JPEG don't set a walk's pace`() {
        var library = GroupLibrary()
        var time = Self.june14 + 8 * 3600
        for shot in 0 ..< 30 {
            for frame in 0 ..< 5 {
                let base = String(format: "WALK_%02d_%d", shot, frame)
                library.add(base + ".NEF", at: time + Double(frame) / 10)
                library.add(base + ".JPG", at: time + Double(frame) / 10)
            }
            time += 120 + Double(shot % 4) * 30
        }
        let moments = library.grouping().moments(of: library.list)
        #expect(moments.count == 1 && moments.first?.count == 300)
    }

    @Test func `a pause past the ceiling starts a moment however sparse the photos around it`() {
        var library = GroupLibrary()
        let yearly = (0 ..< 5).map { library.add("YEAR_\($0).JPG", at: Self.june14 + Double($0) * 365 * 86400) }
        #expect(library.grouping().moments(of: library.list).photoSets == yearly.map { [$0] })

        var sparse = GroupLibrary()
        let photos = (0 ..< 3).map { sparse.add("SPARSE_\($0).JPG", at: Self.june14 + Double($0) * 50 * 60) }
        #expect(sparse.grouping().moments(of: sparse.list).photoSets == [photos])
        let tightest = MomentSetting(looseness: MomentSetting.tightest)
        #expect(sparse.grouping().moments(of: sparse.list, setting: tightest).photoSets == photos.map { [$0] })
    }

    @Test func `moments start where the rule says, the median of each pause's own window worked out afresh`() {
        var random = SeededRandom(seed: 29)
        var times: [Int64] = [0]
        for _ in 0 ..< 6000 {
            let gap = switch random.int(below: 10) {
            case 0 ..< 5: Int64(random.int(in: 1 ... 30000))
            case 5, 6: Int64(random.int(in: 0 ... 1000))
            case 7: Int64(random.int(in: 30000 ... 600_000))
            case 8: Int64(random.int(in: 600_000 ... 8_000_000))
            default: Int64(random.int(in: 8_000_000 ... 400_000_000))
            }
            times.append(times[times.count - 1] + gap)
        }
        for looseness in MomentSetting.tightest ... MomentSetting.loosest {
            let setting = MomentSetting(looseness: looseness)
            let found = times.withUnsafeBufferPointer { MomentFinder.starts($0, setting: setting) }
            #expect(Array(found) == Self.starts(times, setting: setting), "looseness \(looseness)")
        }
    }

    /// `MomentFinder.starts` as its documentation states the rule, each pause's window sorted afresh.
    private static func starts(_ times: [Int64], setting: MomentSetting) -> [Int32] {
        var pauses: [Int64] = []
        var after: [Int32] = []
        for place in times.indices.dropFirst() {
            let gap = times[place] - times[place - 1]
            if gap > Int64(StackFinder.burstGap * 1000) {
                pauses.append(gap)
                after.append(Int32(place))
            }
        }
        let (around, floor) = (MomentFinder.gapsAround, Int64((setting.floor * 1000).rounded()))
        var starts: [Int32] = []
        for pause in pauses.indices where pauses[pause] > floor {
            let lower = max(0, min(pause - around / 2, pauses.count - around - 1))
            var window = Array(pauses[lower ..< min(pauses.count, lower + around + 1)])
            window.remove(at: window.firstIndex(of: pauses[pause]) ?? 0)
            window.sort()
            let median = window.isEmpty ? .infinity : window.count % 2 == 1 ? Double(window[window.count / 2])
                : Double(window[window.count / 2 - 1] + window[window.count / 2]) / 2
            if Double(pauses[pause]) > setting.multiple * min(median, MomentSetting.slowestPace * 1000) {
                starts.append(after[pause])
            }
        }
        return starts
    }

    @Test func `one setting moves the floor and the multiple together`() throws {
        let standard = MomentSetting()
        #expect(standard.looseness == 0 && standard.floor == 60 && standard.multiple == 4 && standard.ceiling == 3600)
        let tightest = MomentSetting(looseness: -9)
        #expect(tightest.looseness == -4 && tightest.floor == 15 && tightest.multiple == 2 && tightest.ceiling == 1800)
        let loosest = MomentSetting(looseness: MomentSetting.loosest)
        #expect(loosest.floor == 240 && loosest.multiple == 8 && loosest.ceiling == 7200)
        for looseness in MomentSetting.tightest ..< MomentSetting.loosest {
            let (setting, looser) = (MomentSetting(looseness: looseness), MomentSetting(looseness: looseness + 1))
            #expect(looser.floor > setting.floor && looser.multiple > setting.multiple)
        }
        let decoded = try JSONDecoder().decode(MomentSetting.self, from: Data(#"{"looseness": 12}"#.utf8))
        #expect(decoded == loosest)
        #expect(try JSONDecoder().decode(MomentSetting.self, from: JSONEncoder().encode(tightest)) == tightest)
    }

    @Test func `moments come newest first when the list is sorted from the newest`() {
        let library = Self.mixed(seed: 3)
        let grouping = library.grouping()
        let oldest = grouping.moments(of: library.list)
        let store = library.store
        let newest = PhotoList(
            source: .allPhotographs, sort: QuerySort(.captured, ascending: false),
            ids: store.ids(sortedBy: QuerySort(.captured, ascending: false)),
        )
        let moments = grouping.moments(of: newest)
        let dated = oldest.filter { $0.value != .moment(nil) }
        #expect(moments.prefix(dated.count).map(\.value) == dated.reversed().map(\.value))
        #expect(moments.prefix(dated.count).map { Set($0.photos) } == dated.reversed().map { Set($0.photos) })
        #expect(moments.last?.value == .moment(nil))
    }

    /// Sessions from a seed: shots a few seconds apart, minutes apart and hours apart, a few of them
    /// a raw beside its JPEG, from two cameras, some without a capture time, and a manual stack
    /// across moments.
    static func mixed(seed: UInt64) -> GroupLibrary {
        var library = GroupLibrary()
        var random = SeededRandom(seed: seed)
        var time = june14
        for shot in 0 ..< 3000 {
            let base = String(format: "MIX_%04d", shot)
            let camera = Int64(1 + random.int(below: 2))
            let captured: Double? = random.int(below: 200) == 0 ? nil : time
            library.add(base + ".NEF", at: captured, camera: camera)
            if random.int(below: 5) == 0 {
                library.add(base + ".JPG", at: captured, camera: camera)
            }
            let roll = random.int(below: 100)
            time += roll < 60 ? random.unit() * 8 : roll < 85 ? 30 + random.unit() * 600 : 600 + random.unit() * 20000
        }
        let stacks = library.grouping().stacks
        library.choices.stack([1, 1500, 2900], top: 1500, in: stacks)
        return library
    }
}

extension GroupLibrary {
    /// `library`'s grouping without its stacks.
    static func unstacked(_ library: GroupLibrary) -> LibraryGrouping {
        LibraryGrouping(store: library.store, names: library.names)
    }
}
