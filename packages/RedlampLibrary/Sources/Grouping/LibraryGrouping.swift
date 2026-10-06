import Foundation
import RedlampDocument

/// What grouping a list's photos reads (LIB-41): the column store as a query engine has it, with the
/// small tables' names, and the library's stacks (LIB-28), which grouping never splits. A grouping is
/// a pass over the list's capture times and a few over the list, which a million photos take well
/// under a second for; call it off the main thread.
public struct LibraryGrouping: Sendable {
    let store: ColumnStore
    let names: QueryNames
    /// The stacks `StackFinder` found in the store.
    public let stacks: Stacks

    init(store: ColumnStore, names: QueryNames = QueryNames(), stacks: Stacks = Stacks()) {
        self.store = store
        self.names = names
        self.stacks = stacks
    }
}

public extension QueryEngine {
    /// What grouping reads, from the column store as it is now (once a load or change in progress is
    /// done), loading it first if it hasn't been; `stacks` are those `StackFinder` found in it. Like
    /// `list`, it cancels nothing.
    func grouping(stacks: Stacks = Stacks()) async throws -> LibraryGrouping {
        if await loadedSnapshot() == nil {
            try await load()
        }
        guard let (store, vocabulary, _) = snapshot() else {
            return LibraryGrouping(store: ColumnStore(), stacks: stacks)
        }
        return LibraryGrouping(store: store, names: vocabulary.names, stacks: stacks)
    }
}

public extension LibraryGrouping {
    /// `list`'s photos grouped by `key`, its moments as `setting` finds them. A photo the store doesn't
    /// hold has none of the fields.
    func groups(of list: PhotoList, by key: GroupKey, setting: MomentSetting = MomentSetting()) -> PhotoGroups {
        let rows = rows(of: list)
        let own = switch key {
        case .ungrouped: ContiguousArray<Int64>(repeating: 0, count: list.count)
        case .moment: moments(of: list, rows: rows, setting: setting)
        }
        return grouped(list, by: key, setting: setting, rows: rows, own: own)
    }

    /// `list`'s moments, as `groups(of:by:setting:)` makes them, the photos without a capture time
    /// last.
    func moments(of list: PhotoList, setting: MomentSetting = MomentSetting()) -> PhotoGroups {
        groups(of: list, by: .moment, setting: setting)
    }
}

extension LibraryGrouping {
    /// Each of `list`'s photos' row in the store, by its place; -1 for a photo the store doesn't hold.
    func rows(of list: PhotoList) -> ContiguousArray<Int32> {
        var rows = ContiguousArray<Int32>(repeating: -1, count: list.count)
        rows.withUnsafeMutableBufferPointer { rows in
            for (place, id) in list.ids.enumerated() {
                if let row = store.row(of: id) {
                    rows[place] = Int32(row)
                }
            }
        }
        return rows
    }

    /// The places of `list`'s photos with a capture time in capture order, ties by name and then ID as
    /// the store orders names, and their times; `rows` are the photos' rows.
    func captureOrder(of list: PhotoList, rows: ContiguousArray<Int32>) -> (
        places: ContiguousArray<Int32>, times: ContiguousArray<Int64>,
    ) {
        var places = ContiguousArray<Int32>()
        places.reserveCapacity(list.count)
        var times = ContiguousArray<Int64>()
        store.captured.withUnsafeBufferPointer { captured in
            store.nameRanks.withUnsafeBufferPointer { ranks in
                rows.withUnsafeBufferPointer { rows in
                    func time(_ place: Int32) -> Int64 {
                        captured[Int(rows[Int(place)])]
                    }
                    func rank(_ place: Int32) -> Int32 {
                        ranks[Int(rows[Int(place)])]
                    }
                    if list.count >= store.count / 8 {
                        store.ids.withUnsafeBufferPointer { ids in
                            for row in store.order(.captured) where captured[Int(row)] != .min {
                                if let place = list.index(of: ids[Int(row)]) {
                                    places.append(Int32(place))
                                }
                            }
                        }
                        var start = 0
                        while start < places.count {
                            var end = start + 1
                            while end < places.count, time(places[end]) == time(places[start]) {
                                end += 1
                            }
                            if end - start > 1 {
                                places[start ..< end].sort { rank($0) < rank($1) }
                            }
                            start = end
                        }
                    } else {
                        for place in rows.indices where rows[place] >= 0 && captured[Int(rows[place])] != .min {
                            places.append(Int32(place))
                        }
                        places.sort { (time($0), rank($0)) < (time($1), rank($1)) }
                    }
                    times.reserveCapacity(places.count)
                    times.append(contentsOf: places.lazy.map(time))
                }
            }
        }
        return (places, times)
    }

    /// Each of `list`'s photos' moment by its place, numbered from 0 in capture order; `Int64.min` for
    /// a photo without a capture time.
    func moments(of list: PhotoList, rows: ContiguousArray<Int32>, setting: MomentSetting) -> ContiguousArray<Int64> {
        let (places, times) = captureOrder(of: list, rows: rows)
        let starts = times.withUnsafeBufferPointer { MomentFinder.starts($0, setting: setting) }
        var moments = ContiguousArray<Int64>(repeating: .min, count: list.count)
        var (moment, next) = (Int64(0), 0)
        for (index, place) in places.enumerated() {
            if next < starts.count, Int(starts[next]) == index {
                moment += 1
                next += 1
            }
            moments[Int(place)] = moment
        }
        return moments
    }

    /// For each photo of `list` in a stack the list has another photo of, but the one standing for the
    /// stack while it's closed: its place, and the place of the photo standing for it. That's the
    /// stack's top, or else the first of its photos the list has in the stack's order (a burst's and a
    /// manual stack's frames by their raws, a raw before its JPEG), as the list shows it closed, so
    /// it's the same photo whatever order the list is in.
    func standIns(in list: PhotoList) -> ContiguousArray<(place: Int32, standIn: Int32)> {
        var found = ContiguousArray<(place: Int32, standIn: Int32)>()
        func gather(_ photos: some Sequence<Int64>, into standIn: inout Int32?) {
            for photo in photos {
                guard let place = list.index(of: photo).map(Int32.init) else { continue }
                if let standIn {
                    found.append((place, standIn))
                } else {
                    standIn = place
                }
            }
        }
        for group in stacks.groups {
            var standIn: Int32?
            for top in stacks.members(of: group) {
                if let pair = stacks.pairIndex(of: top) {
                    gather(stacks.members(of: pair), into: &standIn)
                } else {
                    gather(CollectionOfOne(top), into: &standIn)
                }
            }
        }
        for pair in stacks.pairs {
            let members = stacks.members(of: pair)
            guard let first = members.first, stacks.groupIndex(of: first) == nil else { continue }
            var standIn: Int32?
            gather(members, into: &standIn)
        }
        return found
    }

    /// `list`'s photos grouped by `own`, each one's code by its place (`Int64.min` for the photos
    /// without the field), every photo of a stack taking the code of the photo standing for it.
    func grouped(
        _ list: PhotoList, by key: GroupKey, setting: MomentSetting, rows: ContiguousArray<Int32>,
        own: ContiguousArray<Int64>,
    ) -> PhotoGroups {
        var codes = own
        for (place, standIn) in standIns(in: list) {
            codes[Int(place)] = own[Int(standIn)]
        }
        var numbering = CodeNumbering(codes)
        var numbers = ContiguousArray<Int32>(repeating: 0, count: codes.count)
        for place in codes.indices {
            numbers[place] = numbering.number(codes[place])
        }
        let found = numbering.codes
        let newestFirst = list.sort.key == .captured && !list.sort.ascending
        let order = found.indices.sorted { lhs, rhs in
            let (left, right) = (found[lhs], found[rhs])
            if left == .min || right == .min {
                return right == .min && left != .min
            }
            switch key {
            case .ungrouped: return left < right
            case .moment: return newestFirst ? left > right : left < right
            }
        }
        var ranks = ContiguousArray<Int32>(repeating: 0, count: found.count)
        for (rank, number) in order.enumerated() {
            ranks[number] = Int32(rank)
        }
        let layout = Layout(list, rows: rows, groups: ranks.count, store: store) { ranks[Int(numbers[$0])] }
        let dated = order.count { found[$0] != .min }
        var details: [PhotoGroups.Detail] = []
        details.reserveCapacity(order.count)
        for (group, number) in order.enumerated() {
            let code = found[number]
            let span = layout.span(of: group)
            let value: GroupValue
            let name: String
            switch key {
            case .ungrouped:
                (value, name) = (.all, "All photos")
            case .moment:
                value = .moment(code == .min ? nil : newestFirst ? dated - 1 - group : group)
                name = code == .min ? "No capture time" : span
                    .map { GroupNames.span($0.lowerBound, $0.upperBound) } ?? ""
            }
            details.append(PhotoGroups.Detail(
                value: value, name: name, picks: layout.picks[group], filter: nil, span: span,
            ))
        }
        return PhotoGroups(
            key: key, setting: setting, list: list, photos: layout.photos, starts: layout.starts, details: details,
            groupOfPlace: layout.groupOfPlace,
        )
    }
}

/// A list's photos laid out group after group, keeping the list's order in each, with each group's
/// picks and the capture times it spans.
struct Layout {
    private(set) var photos: ContiguousArray<Int64>
    private(set) var starts: ContiguousArray<Int32>
    private(set) var groupOfPlace: ContiguousArray<Int32>
    private(set) var picks: [Int]
    private var first: [Int64]
    private var last: [Int64]

    /// `list`'s photos in `groups` groups, `group` giving each place's; `rows` are the photos' rows in
    /// `store`.
    init(
        _ list: PhotoList, rows: ContiguousArray<Int32>, groups: Int, store: ColumnStore, group: (Int) -> Int32,
    ) {
        var starts = ContiguousArray<Int32>(repeating: 0, count: groups + 1)
        var groupOfPlace = ContiguousArray<Int32>(repeating: 0, count: list.count)
        for place in 0 ..< list.count {
            let found = group(place)
            groupOfPlace[place] = found
            starts[Int(found) + 1] += 1
        }
        for index in 0 ..< groups {
            starts[index + 1] += starts[index]
        }
        var photos = ContiguousArray<Int64>(repeating: 0, count: list.count)
        var next = starts
        var picks = [Int](repeating: 0, count: groups)
        var first = [Int64](repeating: .max, count: groups)
        var last = [Int64](repeating: .min, count: groups)
        let pick = UInt16(PhotoRecord.code(for: .pick))
        store.packed.withUnsafeBufferPointer { packed in
            store.captured.withUnsafeBufferPointer { captured in
                for place in 0 ..< list.count {
                    let found = Int(groupOfPlace[place])
                    photos[Int(next[found])] = list.ids[place]
                    next[found] += 1
                    let row = Int(rows[place])
                    guard row >= 0 else { continue }
                    if Packed.flag(packed[row]) == pick {
                        picks[found] += 1
                    }
                    let time = captured[row]
                    if time != .min {
                        first[found] = min(first[found], time)
                        last[found] = max(last[found], time)
                    }
                }
            }
        }
        self.photos = photos
        self.starts = starts
        self.groupOfPlace = groupOfPlace
        self.picks = picks
        self.first = first
        self.last = last
    }

    /// The capture times group `group`'s photos span, nil when none has one.
    func span(of group: Int) -> ClosedRange<Int64>? {
        first[group] <= last[group] ? first[group] ... last[group] : nil
    }
}

/// Numbers the codes groups are made of from 0, in the order they're first met: through a table when
/// they span a small range, and a dictionary when they don't.
struct CodeNumbering {
    static let tableLimit: Int64 = 1 << 22

    private let lowest: Int64
    private var table: ContiguousArray<Int32>
    private var others: [Int64: Int32] = [:]
    private var none: Int32 = -1
    /// The codes, by number.
    private(set) var codes = ContiguousArray<Int64>()

    /// Ready for `codes`, `Int64.min` among them being the photos without the field.
    init(_ codes: ContiguousArray<Int64>) {
        var (lowest, highest) = (Int64.max, Int64.min)
        for code in codes where code != .min {
            lowest = min(lowest, code)
            highest = max(highest, code)
        }
        self.lowest = lowest
        let (span, overflow) = highest.subtractingReportingOverflow(lowest)
        table = lowest <= highest && !overflow && span < Self.tableLimit
            ? ContiguousArray(repeating: -1, count: Int(span) + 1) : []
    }

    mutating func number(_ code: Int64) -> Int32 {
        if code == .min {
            if none < 0 {
                none = add(code)
            }
            return none
        }
        let (offset, overflow) = code.subtractingReportingOverflow(lowest)
        if !overflow, offset >= 0, offset < Int64(table.count) {
            if table[Int(offset)] < 0 {
                table[Int(offset)] = add(code)
            }
            return table[Int(offset)]
        }
        if let number = others[code] {
            return number
        }
        let number = add(code)
        others[code] = number
        return number
    }

    private mutating func add(_ code: Int64) -> Int32 {
        codes.append(code)
        return Int32(codes.count - 1)
    }
}
