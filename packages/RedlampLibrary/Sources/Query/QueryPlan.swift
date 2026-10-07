import Foundation
import RedlampDocument

/// A query compiled against a column store: tests of its columns, and sets of rows looked up in the
/// index for text, keyword and collection terms. Folder, camera and lens terms are matched in the
/// small tables, and creator, copyright, location and custom label terms in the store's names, and
/// become IDs and codes the column pass tests.
indirect enum QueryPlan: Sendable, Hashable {
    case all
    case nothing
    case leaf(Leaf)
    case not(QueryPlan)
    case and([QueryPlan])
    case or([QueryPlan])

    enum Leaf: Sendable, Hashable {
        /// The rows whose packed field `shift` bits up (`mask` wide) has a value whose bit is in
        /// `accepted`.
        case packed(shift: UInt16, mask: UInt16, accepted: UInt32)
        /// The rows with `bit` set in the packed field.
        case bit(UInt16)
        /// The rows with any of these `PhotoRecord.State` bits.
        case state(UInt8)
        case iso(Range<Int64>)
        case aperture(Range<Int64>)
        case focal(Range<Int64>)
        case shutter(Range<Int64>)
        case megapixels(Range<Int64>)
        case aspect(Range<Int64>)
        case captured(Range<Int64>)
        /// A bit per `PhotoRecord.Kind`.
        case kinds(UInt64)
        /// A bit per `PhotoOrientation.code`, bit 0 for none.
        case orientations(UInt8)
        case cameras([UInt16])
        case lenses([UInt16])
        case folders([Int32])
        /// The rows whose code in a column of names has its bit in the table (`CodeTable`).
        case codes(CodeColumn, ContiguousArray<UInt64>)
        /// The rows with a name in the column.
        case present(CodeColumn)
        case rows(RowSet)
    }

    /// The store's columns of codes for names.
    enum CodeColumn: Sendable, Hashable {
        case creator, copyright, customLabel, place
    }

    /// Photos looked up in the index.
    enum RowSet: Sendable, Hashable {
        /// An FTS5 query of the text index.
        case match(String)
        case keywords([Int64])
        case collections([Int64])
    }

    /// `query` against `store`: nil is every photo.
    init(_ query: LibraryQuery?, store: ColumnStore, vocabulary: QueryVocabulary, today: Int) {
        self = query.map { Self.compile($0, store: store, vocabulary: vocabulary, today: today) } ?? .all
    }

    /// The photos of the collection at `path`, or of every collection inside it, smart collections'
    /// queries included.
    init(collection path: CollectionPath, store: ColumnStore, vocabulary: QueryVocabulary, today: Int) {
        let ids = vocabulary.names.collections.compactMap { id, text in
            CollectionPath(text)?.isWithin(path) == true ? id : nil
        }
        var plans: [QueryPlan] = ids.isEmpty ? [] : [.leaf(.rows(.collections(ids.sorted())))]
        for smart in vocabulary.smartCollections() where smart.path.isWithin(path) {
            plans.append(smart.query.map {
                QueryPlan($0.searchable, store: store, vocabulary: vocabulary, today: today)
            } ?? .nothing)
        }
        self = Self.any(plans)
    }

    /// The row sets it needs looked up.
    var rowSets: Set<RowSet> {
        switch self {
        case .all, .nothing: []
        case let .leaf(.rows(set)): [set]
        case .leaf: []
        case let .not(plan): plan.rowSets
        case let .and(plans), let .or(plans): plans.reduce(into: []) { $0.formUnion($1.rowSets) }
        }
    }

    // MARK: - Compiling

    private static func compile(
        _ query: LibraryQuery, store: ColumnStore, vocabulary: QueryVocabulary, today: Int,
    ) -> QueryPlan {
        switch query {
        case .all:
            return .all
        case let .text(text):
            let synonyms = vocabulary.hasKeywordSynonyms ? vocabulary.ids(in: .keywordSynonyms, matching: text) : []
            return any([
                .leaf(.rows(.match(QueryText.match(text)))),
                folders(vocabulary.ids(in: .folders, matching: text)),
                cameras(vocabulary.ids(in: .cameras, matching: text), store),
                lenses(vocabulary.ids(in: .lenses, matching: text), store),
                codes(.creator, store.creatorNames.codes(containing: text)),
                codes(.place, store.placeNames.places(where: nil, contains: text)),
                synonyms.isEmpty ? .nothing : .leaf(.rows(.keywords(synonyms))),
            ])
        case let .filter(filter):
            let alternatives = filter.values.map { value in
                compile(filter.field, filter.comparison, value, store: store, vocabulary: vocabulary, today: today)
            }
            return filter.comparison == .notEqual ? negated(any(alternatives)) : any(alternatives)
        case let .not(query):
            return negated(compile(query, store: store, vocabulary: vocabulary, today: today))
        case let .and(queries):
            return every(queries.map { compile($0, store: store, vocabulary: vocabulary, today: today) })
        case let .or(queries):
            return any(queries.map { compile($0, store: store, vocabulary: vocabulary, today: today) })
        }
    }

    private static func compile(
        _ field: LibraryQuery.Field, _ comparison: LibraryQuery.Comparison, _ value: LibraryQuery.Value,
        store: ColumnStore, vocabulary: QueryVocabulary, today: Int,
    ) -> QueryPlan {
        if let range = QueryRanges.range(field, comparison, value, today: today) {
            guard !range.isEmpty else { return .nothing }
            switch field {
            case .rating:
                let accepted = (range.lowerBound ..< range.upperBound).reduce(UInt32(0)) { $0 | 1 << UInt32($1) }
                return .leaf(.packed(shift: 0, mask: 0x7, accepted: accepted))
            case .iso: return .leaf(.iso(range))
            case .aperture: return .leaf(.aperture(range))
            case .focal: return .leaf(.focal(range))
            case .shutter: return .leaf(.shutter(range))
            case .megapixels: return .leaf(.megapixels(range))
            case .aspect: return .leaf(.aspect(range))
            default: return .leaf(.captured(range))
            }
        }
        switch (field, value) {
        case let (.trait, .trait(trait)):
            return compile(trait.query, store: store, vocabulary: vocabulary, today: today)
        case let (.flag, .flag(flag)):
            return .leaf(.packed(
                shift: Packed.flagShift,
                mask: 0x3,
                accepted: 1 << UInt32(PhotoRecord.code(for: flag)),
            ))
        case let (.label, .label(label)):
            let colour = labelled(label)
            return label == nil ? every([colour, .not(.leaf(.present(.customLabel)))]) : colour
        case let (.label, .text(name)):
            let custom = codes(.customLabel, store.customLabelNames.codes(named: name))
            return XMPLabelNames.label(named: name).map { any([labelled($0), custom]) } ?? custom
        case let (.creator, .text(text)):
            return codes(.creator, store.creatorNames.codes(containing: text))
        case let (.copyright, .text(text)):
            return codes(.copyright, store.copyrightNames.codes(containing: text))
        case let (.sublocation, .text(text)), let (.city, .text(text)), let (.state, .text(text)),
             let (.country, .text(text)), let (.countryCode, .text(text)):
            guard let part = PlaceCodes.Part(field) else { return .nothing }
            return codes(.place, store.placeNames.places(where: part, contains: text))
        case let (.marked, .bool(yes)):
            return yes ? .leaf(.bit(Packed.marked)) : .not(.leaf(.bit(Packed.marked)))
        case let (.edited, .bool(yes)):
            return yes ? .leaf(.bit(Packed.edited)) : .not(.leaf(.bit(Packed.edited)))
        case let (.missing, .bool(yes)), let (.offline, .bool(yes)), let (.unreadable, .bool(yes)):
            let state: PhotoRecord.State = field == .missing ? .missing : field == .offline ? .offline : .unreadable
            let leaf = QueryPlan.leaf(.state(UInt8(state.rawValue)))
            return yes ? leaf : .not(leaf)
        case let (.keyword, .text(text)):
            let ids = vocabulary.ids(in: .keywords, matching: text)
            return ids.isEmpty ? .nothing : .leaf(.rows(.keywords(ids)))
        case let (.collection, .text(text)):
            let ids = vocabulary.ids(in: .collections, matching: text)
            return ids.isEmpty ? .nothing : .leaf(.rows(.collections(ids)))
        case let (.camera, .text(text)):
            return cameras(vocabulary.ids(in: .cameras, matching: text), store)
        case let (.lens, .text(text)):
            return lenses(vocabulary.ids(in: .lenses, matching: text), store)
        case let (.folder, .text(text)):
            return folders(vocabulary.ids(in: .folders, matching: text))
        case let (.name, .text(text)):
            return .leaf(.rows(.match(QueryText.match(text, in: .name))))
        case let (.title, .text(text)):
            return .leaf(.rows(.match(QueryText.match(text, in: .title))))
        case let (.caption, .text(text)):
            return .leaf(.rows(.match(QueryText.match(text, in: .caption))))
        case let (.ext, .kind(kind)):
            return .leaf(.kinds(1 << UInt64(kind.rawValue)))
        case let (.orientation, .orientation(orientation)):
            return .leaf(.orientations(1 << (orientation?.code ?? 0)))
        case let (.ext, .text(ext)):
            return .leaf(.rows(.match(QueryText.match("." + ext, in: .name))))
        case let (.has, .detail(detail)):
            let details: ColumnStore.Details
            switch detail {
            case .gps: details = .location
            case .keywords: details = .keywords
            case .caption: details = .caption
            case .title: details = .title
            case .xmp: details = .xmp
            case .creator: return .leaf(.present(.creator))
            case .copyright: return .leaf(.present(.copyright))
            case .location: return .leaf(.present(.place))
            }
            return .leaf(.bit(Packed.details(details)))
        default:
            return .nothing
        }
    }

    /// The rows with one of `codes` in `column`.
    private static func codes(_ column: CodeColumn, _ codes: [UInt32]) -> QueryPlan {
        codes.isEmpty ? .nothing : .leaf(.codes(column, CodeTable.make(codes)))
    }

    /// The rows with colour `label`, or with none.
    private static func labelled(_ label: ColorLabel?) -> QueryPlan {
        .leaf(.packed(shift: Packed.labelShift, mask: 0x7, accepted: 1 << UInt32(PhotoRecord.code(for: label))))
    }

    private static func cameras(_ ids: [Int64], _ store: ColumnStore) -> QueryPlan {
        let codes = Set(ids.compactMap(store.cameraCode(for:))).sorted()
        return codes.isEmpty ? .nothing : .leaf(.cameras(codes))
    }

    private static func lenses(_ ids: [Int64], _ store: ColumnStore) -> QueryPlan {
        let codes = Set(ids.compactMap(store.lensCode(for:))).sorted()
        return codes.isEmpty ? .nothing : .leaf(.lenses(codes))
    }

    private static func folders(_ ids: [Int64]) -> QueryPlan {
        ids.isEmpty ? .nothing : .leaf(.folders(ids.map { Int32(clamping: $0) }))
    }

    private static func every(_ plans: [QueryPlan]) -> QueryPlan {
        let kept = plans.filter { $0 != .all }
        if kept.contains(.nothing) {
            return .nothing
        }
        return kept.isEmpty ? .all : kept.count == 1 ? kept[0] : .and(kept)
    }

    private static func any(_ plans: [QueryPlan]) -> QueryPlan {
        let kept = plans.filter { $0 != .nothing }
        if kept.contains(.all) {
            return .all
        }
        return kept.isEmpty ? .nothing : kept.count == 1 ? kept[0] : .or(kept)
    }

    private static func negated(_ plan: QueryPlan) -> QueryPlan {
        switch plan {
        case .all: .nothing
        case .nothing: .all
        case let .not(inner): inner
        default: .not(plan)
        }
    }
}

// MARK: - Evaluating

extension ColumnStore {
    /// The live rows `plan` accepts, `sets` holding its row sets.
    func rows(matching plan: QueryPlan, sets: [QueryPlan.RowSet: RowBits]) -> RowBits {
        switch plan {
        case .all:
            return live
        case .nothing:
            return RowBits(rows: rowCount)
        case let .leaf(leaf):
            var rows = rows(matching: leaf, sets: sets)
            rows.formIntersection(live)
            return rows
        case let .not(inner):
            var rows = rows(matching: inner, sets: sets)
            rows.complement(in: live)
            return rows
        case let .and(plans):
            var rows = rows(matching: plans[0], sets: sets)
            for plan in plans.dropFirst() where !rows.isEmpty {
                rows.formIntersection(self.rows(matching: plan, sets: sets))
            }
            return rows
        case let .or(plans):
            var rows = rows(matching: plans[0], sets: sets)
            for plan in plans.dropFirst() {
                rows.formUnion(self.rows(matching: plan, sets: sets))
            }
            return rows
        }
    }

    /// `rows` without the photos that can't be read, which lists leave out (LIB-40).
    func readable(_ rows: RowBits) -> RowBits {
        var readable = rows
        readable.subtract(self.rows(matching: .leaf(.state(UInt8(PhotoRecord.State.unreadable.rawValue))), sets: [:]))
        return readable
    }

    /// The rows of the photos `ids`, leaving out those the store doesn't hold.
    func rows(withIDs ids: [Int64]) -> RowBits {
        var rows = RowBits(rows: rowCount)
        for id in ids {
            if let row = row(of: id) {
                rows.insert(row)
            }
        }
        return rows
    }

    /// The rows `leaf` accepts, dead ones included.
    private func rows(matching leaf: QueryPlan.Leaf, sets: [QueryPlan.RowSet: RowBits]) -> RowBits {
        var words = ContiguousArray<UInt64>(repeating: 0, count: (rowCount + 63) / 64)
        switch leaf {
        case let .packed(shift, mask, accepted):
            Self.fill(&words, packed) { UInt64(accepted >> UInt32($0 >> shift & mask) & 1) }
        case let .bit(bit):
            Self.fill(&words, packed) { $0 & bit == 0 ? 0 : 1 }
        case let .state(bits):
            Self.fill(&words, states) { $0 & bits == 0 ? 0 : 1 }
        case let .iso(range):
            Self.fill(&words, iso, within: range)
        case let .aperture(range):
            Self.fill(&words, aperture, within: range)
        case let .focal(range):
            Self.fill(&words, focal, within: range)
        case let .shutter(range):
            Self.fill(&words, shutter, within: range)
        case let .megapixels(range):
            Self.fill(&words, megapixels, within: range)
        case let .aspect(range):
            Self.fill(&words, aspects, within: range)
        case let .captured(range):
            let span = UInt64(bitPattern: range.upperBound &- range.lowerBound)
            let lower = range.lowerBound
            Self.fill(&words, captured) { UInt64(bitPattern: $0 &- lower) < span ? 1 : 0 }
        case let .kinds(kinds):
            Self.fill(&words, self.kinds) { kinds >> UInt64($0) & 1 }
        case let .orientations(codes):
            Self.fill(&words, orientations) { UInt64(codes >> $0 & 1) }
        case let .cameras(codes):
            let table = Self.table(codes.map(Int.init))
            Self.fill(&words, cameras) { Self.lookUp(table, Int($0)) }
        case let .lenses(codes):
            let table = Self.table(codes.map(Int.init))
            Self.fill(&words, lenses) { Self.lookUp(table, Int($0)) }
        case let .folders(ids):
            let table = Self.table(ids.map(Int.init))
            Self.fill(&words, folders) { Self.lookUp(table, Int($0)) }
        case let .codes(column, table):
            switch column {
            case .creator: Self.fill(&words, creators) { Self.lookUp(table, Int($0)) }
            case .copyright: Self.fill(&words, copyrights) { Self.lookUp(table, Int($0)) }
            case .customLabel: Self.fill(&words, customLabels) { Self.lookUp(table, Int($0)) }
            case .place: Self.fill(&words, places) { Self.lookUp(table, Int($0)) }
            }
        case let .present(column):
            switch column {
            case .creator: Self.fill(&words, creators) { $0 == 0 ? 0 : 1 }
            case .copyright: Self.fill(&words, copyrights) { $0 == 0 ? 0 : 1 }
            case .customLabel: Self.fill(&words, customLabels) { $0 == 0 ? 0 : 1 }
            case .place: Self.fill(&words, places) { $0 == 0 ? 0 : 1 }
            }
        case let .rows(set):
            return sets[set] ?? RowBits(rows: rowCount)
        }
        return RowBits(words: words)
    }

    /// Each word of `words` from 64 rows of `column`, a bit for each as `test` gives it.
    @inline(__always)
    private static func fill<T>(
        _ words: inout ContiguousArray<UInt64>,
        _ column: ContiguousArray<T>,
        _ test: (T) -> UInt64,
    ) {
        let rows = column.count
        words.withUnsafeMutableBufferPointer { words in
            column.withUnsafeBufferPointer { column in
                for index in words.indices {
                    let first = index << 6
                    let count = min(64, rows - first)
                    var word: UInt64 = 0
                    for offset in 0 ..< count {
                        word |= test(column[first + offset]) << UInt64(offset)
                    }
                    words[index] = word
                }
            }
        }
    }

    @inline(__always)
    private static func fill(
        _ words: inout ContiguousArray<UInt64>, _ column: ContiguousArray<some FixedWidthInteger & UnsignedInteger>,
        within range: Range<Int64>,
    ) {
        let lower = UInt64(max(range.lowerBound, 0))
        let span = UInt64(max(range.upperBound, 0)) &- lower
        fill(&words, column) { UInt64($0) &- lower < span ? 1 : 0 }
    }

    /// A bit for each of `values`, none negative.
    private static func table(_ values: [Int]) -> ContiguousArray<UInt64> {
        var table = ContiguousArray<UInt64>(repeating: 0, count: (values.max() ?? 0) / 64 + 1)
        for value in values where value >= 0 {
            table[value >> 6] |= 1 << UInt64(value & 63)
        }
        return table
    }

    @inline(__always)
    private static func lookUp(_ table: ContiguousArray<UInt64>, _ value: Int) -> UInt64 {
        let word = value >> 6
        guard value >= 0, word < table.count else { return 0 }
        return table[word] >> UInt64(value & 63) & 1
    }

    /// From `start` places into `order` (from its end when descending), appends the IDs of rows in
    /// `matches` to `ids` until `limit` of them are there or `places` places are passed; returns
    /// where it stopped.
    func collect(
        _ matches: RowBits, in order: ContiguousArray<Int32>, ascending: Bool, from start: Int, limit: Int, places: Int,
        into ids: inout ContiguousArray<Int64>,
    ) -> Int {
        let end = min(order.count, start + places)
        var place = start
        order.withUnsafeBufferPointer { order in
            self.ids.withUnsafeBufferPointer { photos in
                matches.words.withUnsafeBufferPointer { words in
                    let last = order.count - 1
                    while place < end, ids.count < limit {
                        let row = Int(order[ascending ? place : last - place])
                        if words[row >> 6] >> UInt64(row & 63) & 1 != 0 {
                            ids.append(photos[row])
                        }
                        place += 1
                    }
                }
            }
        }
        return place
    }
}
