import Foundation
import RedlampDocument

/// What grouping a list's photos reads (LIB-41): the column store as a query engine has it, with the
/// small tables' names of folders, cameras and lenses; and the library's stacks (LIB-28), which
/// grouping never splits. A grouping is a pass over the list's capture times and a few over the list,
/// which a million photos take well under a second for; call it off the main thread.
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
        let newestFirst = list.sort.key == .captured && !list.sort.ascending
        let byTime = { (codes: [Int64]) in codes.sorted { newestFirst ? $0 > $1 : $0 < $1 } }
        let sorted: Sorted
        let describe: (_ code: Int64?, _ group: Int, _ span: ClosedRange<Int64>?) -> (GroupValue, String, LibraryQuery?)
        switch key {
        case .ungrouped:
            sorted = self.sorted(list, rows: rows, own: ContiguousArray(repeating: 0, count: list.count)) { $0 }
            describe = { _, _, _ in (.all, "All photos", nil) }
        case .moment:
            sorted = self.sorted(list, rows: rows, own: moments(of: list, rows: rows, setting: setting), order: byTime)
            let dated = sorted.codes.count { $0 != .min }
            describe = { code, group, span in
                guard let code else { return (.moment(nil), Self.undated, nil) }
                let filter = sorted.crossed.contains(code) ? nil : span.flatMap(Self.filter(spanning:))
                return (.moment(newestFirst ? dated - 1 - group : group), Self.name(of: span), filter)
            }
        case .day:
            let days = column(rows, store.captured) { $0 == .min ? .min : Int64(QueryCalendar.day(ofMilliseconds: $0)) }
            sorted = self.sorted(list, rows: rows, own: days, order: byTime)
            describe = { code, _, _ in
                guard let code else { return (.day(nil), Self.undated, nil) }
                let (year, month, date) = QueryCalendar.civil(Int(code))
                let day = QueryDate.day(year, month, date)
                let filter = LibraryQuery.filter(LibraryQuery.Filter(.date, .equal, [.date(day)]))
                return (.day(day), GroupNames.day(Int(code)), sorted.crossed.contains(code) ? nil : filter)
            }
        case .folder, .camera, .lens:
            let named = named(key, rows: rows)
            sorted = self.sorted(list, rows: rows, own: named.codes) { Self.byName($0, named.names) }
            let values = Set(sorted.codes + sorted.crossed).compactMap { named.names[$0] }.sorted()
            let filters = GroupFilters(field: named.field, values: values)
            describe = { code, _, _ in
                guard let code, let name = named.names[code] else { return (named.value(nil), named.none, nil) }
                return (named.value(name), name, sorted.crossed.contains(code) ? nil : filters.filter(for: name))
            }
        case .orientation:
            let codes = column(rows, store.orientations) { $0 == 0 ? .min : Int64($0) }
            sorted = self.sorted(list, rows: rows, own: codes) { $0.sorted() }
            describe = { code, _, _ in
                let orientation = code.flatMap { PhotoOrientation(code: UInt8($0)) }
                let filter = sorted.crossed.contains(code ?? .min) ? nil
                    : LibraryQuery.filter(LibraryQuery.Filter(.orientation, .equal, [.orientation(orientation)]))
                return (.orientation(orientation), orientation?.rawValue.capitalized ?? "No orientation", filter)
            }
        case .momentCamera:
            let combined = momentCameras(of: list, rows: rows, setting: setting)
            sorted = self.sorted(list, rows: rows, own: combined.codes) { codes in
                codes.sorted { lhs, rhs in
                    let (left, right) = (combined.moment(lhs), combined.moment(rhs))
                    guard left != right else { return combined.camera(lhs) < combined.camera(rhs) }
                    if left == combined.undated || right == combined.undated {
                        return right == combined.undated
                    }
                    return newestFirst ? left > right : left < right
                }
            }
            let moments = sorted.codes.map(combined.moment)
            let dated = Set(moments).subtracting([combined.undated]).count
            var ordinals: [Int] = []
            for (group, moment) in moments.enumerated() {
                let shown = group == 0 ? 0 : moment == moments[group - 1] ? ordinals[group - 1] : ordinals[group - 1] +
                    1
                ordinals.append(shown)
            }
            // Each camera's term once: a list's moments are many more than its cameras.
            let filters = GroupFilters(field: .camera, values: combined.cameras)
            let cameras = Dictionary(combined.cameras.map { ($0, filters.filter(for: $0)) }) { first, _ in first }
            describe = { code, group, span in
                let camera = code.flatMap(combined.cameraName)
                let suffix = " — " + (camera ?? "No camera")
                guard let code, combined.moment(code) != combined.undated else {
                    return (.momentCamera(nil, camera: camera), Self.undated + suffix, nil)
                }
                let ordinal = newestFirst ? dated - 1 - ordinals[group] : ordinals[group]
                var filter: LibraryQuery?
                if !sorted.crossed.contains(code), let camera, let times = span.flatMap(Self.filter(spanning:)),
                   let byCamera = cameras[camera] ?? nil {
                    filter = .joined([times, byCamera], or: false)
                }
                return (.momentCamera(ordinal, camera: camera), Self.name(of: span) + suffix, filter)
            }
        }
        let details = sorted.codes.enumerated().map { group, code in
            let span = sorted.layout.span(of: group)
            let (value, name, filter) = describe(code == .min ? nil : code, group, span)
            return PhotoGroups.Detail(
                value: value, name: name, picks: sorted.layout.picks[group], filter: filter, span: span,
            )
        }
        return PhotoGroups(
            key: key, setting: setting, list: list, photos: sorted.layout.photos, starts: sorted.layout.starts,
            details: details, groupOfPlace: sorted.layout.groupOfPlace,
        )
    }

    /// `list`'s moments, as `groups(of:by:setting:)` makes them, the photos without a capture time
    /// last.
    func moments(of list: PhotoList, setting: MomentSetting = MomentSetting()) -> PhotoGroups {
        groups(of: list, by: .moment, setting: setting)
    }
}

extension LibraryGrouping {
    static let undated = "No capture time"

    /// A span of capture times in words.
    static func name(of span: ClosedRange<Int64>?) -> String {
        span.map { GroupNames.span($0.lowerBound, $0.upperBound) } ?? undated
    }

    /// The `date:` finding the capture times of `span`, in milliseconds, to the second: the second of
    /// both ends, or a range from the second of its first to that of its last. A moment's photos are
    /// further from another moment's than a second, as the shortest pause starting a moment is 15 s.
    /// Nil for times before the year 1 or after 9999, which the language doesn't write.
    static func filter(spanning span: ClosedRange<Int64>) -> LibraryQuery? {
        let (first, last) = (
            QueryDate.second(ofMilliseconds: span.lowerBound),
            QueryDate.second(ofMilliseconds: span.upperBound),
        )
        guard case let .time(start, _, _, _) = first, case let .time(end, _, _, _) = last, start >= 1, end <= 9999
        else { return nil }
        return .filter(LibraryQuery.Filter(.date, .equal, [first == last ? .date(first) : .dateRange(first, last)]))
    }

    /// `codes` by their names, in the Finder's order.
    static func byName(_ codes: [Int64], _ names: [Int64: String]) -> [Int64] {
        codes.map { code in (code: code, name: names[code] ?? "", key: FinderOrder.key(names[code] ?? "")) }
            .sorted { $0.key == $1.key ? $0.name < $1.name : $0.key.lexicographicallyPrecedes($1.key) }.map(\.code)
    }

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

    /// Each photo's code from its row's value in `column`, by place: `Int64.min` for a photo the store
    /// doesn't hold.
    func column<T>(_ rows: ContiguousArray<Int32>, _ column: StoreColumn<T>, _ code: (T) -> Int64)
        -> ContiguousArray<Int64> {
        var codes = ContiguousArray<Int64>(repeating: .min, count: rows.count)
        codes.withUnsafeMutableBufferPointer { codes in
            column.withUnsafeBufferPointer { column in
                for (place, row) in rows.enumerated() where row >= 0 {
                    codes[place] = code(column[Int(row)])
                }
            }
        }
        return codes
    }

    /// A key whose values are names in the small tables: each photo's code by place, `Int64.min` for
    /// none or one without a name, and each code's name.
    struct NamedColumn {
        let field: LibraryQuery.Field
        let codes: ContiguousArray<Int64>
        let names: [Int64: String]
        let none: String
        let value: (String?) -> GroupValue
    }

    func named(_ key: GroupKey, rows: ContiguousArray<Int32>) -> NamedColumn {
        switch key {
        case .folder:
            let largest = Int(min(names.folders.keys.max() ?? -1, 1 << 24))
            var known = [Bool](repeating: false, count: largest + 1)
            for id in names.folders.keys where id >= 0 && id <= largest {
                known[Int(id)] = true
            }
            let folders = names.folders
            let codes = column(rows, store.folders) { folder in
                let id = Int(folder)
                let named = id >= 0 && (id < known.count ? known[id] : folders[Int64(id)] != nil)
                return named ? Int64(id) : .min
            }
            return NamedColumn(
                field: .folder,
                codes: codes,
                names: folders,
                none: "No folder",
                value: GroupValue.folder,
            )
        case .lens:
            let (codes, lenses) = coded(rows, store.lenses, ids: store.lensIDs, names: names.lenses)
            return NamedColumn(field: .lens, codes: codes, names: lenses, none: "No lens", value: GroupValue.lens)
        default:
            let (codes, cameras) = coded(rows, store.cameras, ids: store.cameraIDs, names: names.cameras)
            return NamedColumn(
                field: .camera,
                codes: codes,
                names: cameras,
                none: "No camera",
                value: GroupValue.camera,
            )
        }
    }

    /// Each photo's code in one of the store's columns of camera or lens codes, by place, those without
    /// a name `Int64.min`, and the codes' names; `ids` are the codes' IDs in the index's tables.
    private func coded(
        _ rows: ContiguousArray<Int32>, _ column: StoreColumn<UInt16>, ids: ContiguousArray<Int64>,
        names: [Int64: String],
    ) -> (ContiguousArray<Int64>, [Int64: String]) {
        var named: [Int64: String] = [:]
        for (code, id) in ids.enumerated() where code != 0 {
            named[Int64(code)] = names[id]
        }
        let known = ids.indices.map { $0 != 0 && named[Int64($0)] != nil }
        return (self.column(rows, column) { known[Int($0)] ? Int64($0) : .min }, named)
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

    /// Each photo's moment and camera as one code: the moment (`undated` for the photos without a
    /// capture time) times the cameras and one, and the camera's place among them by name, the photos
    /// without one last.
    struct MomentCameras {
        let codes: ContiguousArray<Int64>
        /// The cameras' names in the Finder's order.
        let cameras: [String]
        let undated: Int64

        func moment(_ code: Int64) -> Int64 {
            code / Int64(cameras.count + 1)
        }

        func camera(_ code: Int64) -> Int64 {
            code % Int64(cameras.count + 1)
        }

        func cameraName(_ code: Int64) -> String? {
            let place = Int(camera(code))
            return place < cameras.count ? cameras[place] : nil
        }
    }

    func momentCameras(of list: PhotoList, rows: ContiguousArray<Int32>, setting: MomentSetting) -> MomentCameras {
        let moments = moments(of: list, rows: rows, setting: setting)
        let named = named(.camera, rows: rows)
        let ordered = Self.byName(Array(named.names.keys), named.names)
        var places: [Int64: Int64] = [:]
        for (place, code) in ordered.enumerated() {
            places[code] = Int64(place)
        }
        let largest = Int(named.names.keys.max() ?? 0)
        let placeOfCode = (0 ... largest).map { places[Int64($0)] ?? Int64(ordered.count) }
        let undated = (moments.lazy.filter { $0 != .min }.max() ?? -1) + 1
        let width = Int64(ordered.count + 1)
        var codes = ContiguousArray<Int64>(repeating: 0, count: list.count)
        for place in codes.indices {
            let moment = moments[place] == .min ? undated : moments[place]
            let camera = named.codes[place]
            codes[place] = moment * width + (camera == .min || Int(camera) > largest
                ? Int64(ordered.count) : placeOfCode[Int(camera)])
        }
        return MomentCameras(codes: codes, cameras: ordered.compactMap { named.names[$0] }, undated: undated)
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

    /// A list's photos laid out by their groups' codes: the codes in the groups' order, those without
    /// the field last, and the codes a stack's photos were taken from or given to.
    struct Sorted {
        let codes: [Int64]
        let layout: GroupLayout
        let crossed: Set<Int64>
    }

    /// `list`'s photos grouped by `own`, each one's code by its place (`Int64.min` for the photos
    /// without the field), every photo of a stack taking the code of the photo standing for it; `order`
    /// puts the codes but `Int64.min` in their groups' order.
    func sorted(
        _ list: PhotoList, rows: ContiguousArray<Int32>, own: ContiguousArray<Int64>,
        order: ([Int64]) -> [Int64],
    ) -> Sorted {
        var codes = own
        var crossed = Set<Int64>()
        for (place, standIn) in standIns(in: list) {
            let (mine, theirs) = (own[Int(place)], own[Int(standIn)])
            if mine != theirs {
                crossed.insert(mine)
                crossed.insert(theirs)
            }
            codes[Int(place)] = theirs
        }
        var numbering = CodeNumbering(codes)
        var numbers = ContiguousArray<Int32>(repeating: 0, count: codes.count)
        for place in codes.indices {
            numbers[place] = numbering.number(codes[place])
        }
        var ordered = order(numbering.codes.filter { $0 != .min })
        if numbering.codes.contains(.min) {
            ordered.append(.min)
        }
        var ranks = ContiguousArray<Int32>(repeating: 0, count: ordered.count)
        for (rank, code) in ordered.enumerated() {
            ranks[Int(numbering.number(code))] = Int32(rank)
        }
        let layout = GroupLayout(list, rows: rows, groups: ordered.count, store: store) { ranks[Int(numbers[$0])] }
        return Sorted(codes: ordered, layout: layout, crossed: crossed)
    }
}

/// A list's photos laid out group after group, keeping the list's order in each, with each group's
/// picks and the capture times it spans.
struct GroupLayout {
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
