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

    /// Photos looked up in the index, or found in the store from other photos.
    enum RowSet: Sendable, Hashable {
        /// An FTS5 query of the text index.
        case match(String)
        case keywords([Int64])
        case collections([Int64])
        /// The photos in moments without a pick (LIB-41).
        case unpickedMoments(MomentScope)
        /// The photos Library Health's Damaged Files check lists (LIB-40).
        case damaged
    }

    /// `query` against `store`: nil is every photo. `moments` are the photos `is:unpicked-moment`
    /// finds moments among, and how.
    init(
        _ query: LibraryQuery?, store: ColumnStore, vocabulary: QueryVocabulary, today: Int,
        moments: MomentScope = .library,
    ) {
        self = query.map {
            Self.compile($0, store: store, vocabulary: vocabulary, today: today, moments: moments)
        } ?? .all
    }

    /// The photos of the collection at `path`, or of every collection inside it, smart collections'
    /// queries included, each finding the library's moments at the default setting. Photos that can't be
    /// read are left out (LIB-40) unless `unreadable` asks for them; a smart collection whose query finds
    /// them keeps them.
    init(
        collection path: CollectionPath, store: ColumnStore, vocabulary: QueryVocabulary, today: Int,
        unreadable: Bool = false,
    ) {
        let readable = unreadable ? QueryPlan.all : .not(.leaf(.state(UInt8(PhotoRecord.State.unreadable.rawValue))))
        let ids = vocabulary.names.collections.compactMap { id, text in
            CollectionPath(text)?.isWithin(path) == true ? id : nil
        }
        var plans: [QueryPlan] = ids.isEmpty ? [] : [Self.every([.leaf(.rows(.collections(ids.sorted()))), readable])]
        for smart in vocabulary.smartCollections() where smart.path.isWithin(path) {
            plans.append(smart.query.map { query in
                let plan = QueryPlan(query.searchable, store: store, vocabulary: vocabulary, today: today)
                return query.findsUnreadable ? plan : Self.every([plan, readable])
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
        _ query: LibraryQuery, store: ColumnStore, vocabulary: QueryVocabulary, today: Int, moments: MomentScope,
    ) -> QueryPlan {
        func compiled(_ query: LibraryQuery) -> QueryPlan {
            compile(query, store: store, vocabulary: vocabulary, today: today, moments: moments)
        }
        switch query {
        case .all:
            return .all
        case let .text(text):
            let synonyms = vocabulary.hasKeywordSynonyms ? vocabulary.ids(in: .keywordSynonyms, matching: text) : []
            return any([
                QueryText.isSearchable(text) ? .leaf(.rows(.match(QueryText.match(text)))) : .nothing,
                folders(vocabulary.ids(in: .folders, matching: text)),
                cameras(vocabulary.ids(in: .cameras, matching: text), store),
                lenses(vocabulary.ids(in: .lenses, matching: text), store),
                codes(.creator, store.creatorNames.codes(containing: text)),
                codes(.place, store.placeNames.places(where: nil, contains: text)),
                synonyms.isEmpty ? .nothing : .leaf(.rows(.keywords(synonyms))),
            ])
        case let .filter(filter):
            let alternatives = filter.values.map { value in
                compile(
                    filter.field, filter.comparison, value, store: store, vocabulary: vocabulary, today: today,
                    moments: moments,
                )
            }
            return filter.comparison == .notEqual ? negated(any(alternatives)) : any(alternatives)
        case let .not(query):
            return negated(compiled(query))
        case let .and(queries):
            return every(queries.map(compiled))
        case let .or(queries):
            return any(queries.map(compiled))
        }
    }

    private static func compile(
        _ field: LibraryQuery.Field, _ comparison: LibraryQuery.Comparison, _ value: LibraryQuery.Value,
        store: ColumnStore, vocabulary: QueryVocabulary, today: Int, moments: MomentScope,
    ) -> QueryPlan {
        if let range = QueryRanges.range(field, comparison, value, today: today) {
            return compile(field, within: range)
        }
        switch (field, value) {
        case let (.trait, .trait(trait)):
            return compile(trait: trait, store: store, vocabulary: vocabulary, today: today, moments: moments)
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
        case let (.marked, .bool(yes)):
            return yes ? .leaf(.bit(Packed.marked)) : .not(.leaf(.bit(Packed.marked)))
        case let (.edited, .bool(yes)):
            return yes ? .leaf(.bit(Packed.edited)) : .not(.leaf(.bit(Packed.edited)))
        case let (.missing, .bool(yes)), let (.offline, .bool(yes)), let (.unreadable, .bool(yes)):
            let state: PhotoRecord.State = field == .missing ? .missing : field == .offline ? .offline : .unreadable
            let leaf = QueryPlan.leaf(.state(UInt8(state.rawValue)))
            return yes ? leaf : .not(leaf)
        case let (.ext, .kind(kind)):
            return .leaf(.kinds(1 << UInt64(kind.rawValue)))
        case let (.orientation, .orientation(orientation)):
            return .leaf(.orientations(1 << (orientation?.code ?? 0)))
        case let (.has, .detail(detail)):
            return compile(detail: detail)
        case let (_, .text(text)):
            return compile(field, matching: text, store: store, vocabulary: vocabulary)
        default:
            return .nothing
        }
    }

    /// A numeric field, or the capture time, within `range`.
    private static func compile(_ field: LibraryQuery.Field, within range: Range<Int64>) -> QueryPlan {
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

    private static func compile(
        trait: LibraryQuery.Trait, store: ColumnStore, vocabulary: QueryVocabulary, today: Int, moments: MomentScope,
    ) -> QueryPlan {
        switch trait {
        case .unpickedMoment: return .leaf(.rows(.unpickedMoments(moments)))
        case .damaged: return .leaf(.rows(.damaged))
        default:
            guard let query = trait.query else { return .nothing }
            return compile(query, store: store, vocabulary: vocabulary, today: today, moments: moments)
        }
    }

    private static func compile(detail: LibraryQuery.Detail) -> QueryPlan {
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
    }

    /// A field compared with text: the names, words and places that hold it.
    private static func compile(
        _ field: LibraryQuery.Field, matching text: String, store: ColumnStore, vocabulary: QueryVocabulary,
    ) -> QueryPlan {
        switch field {
        case .creator:
            return codes(.creator, store.creatorNames.codes(containing: text))
        case .copyright:
            return codes(.copyright, store.copyrightNames.codes(containing: text))
        case .sublocation, .city, .state, .country, .countryCode:
            guard let part = PlaceCodes.Part(field) else { return .nothing }
            return codes(.place, store.placeNames.places(where: part, contains: text))
        case .keyword:
            let ids = vocabulary.ids(in: .keywords, matching: text)
            return ids.isEmpty ? .nothing : .leaf(.rows(.keywords(ids)))
        case .collection:
            let ids = vocabulary.ids(in: .collections, matching: text)
            return ids.isEmpty ? .nothing : .leaf(.rows(.collections(ids)))
        case .camera:
            return cameras(vocabulary.ids(in: .cameras, matching: text), store)
        case .lens:
            return lenses(vocabulary.ids(in: .lenses, matching: text), store)
        case .folder:
            return folders(vocabulary.ids(in: .folders, matching: text))
        case .name:
            return .leaf(.rows(.match(QueryText.match(text, in: .name))))
        case .title:
            return .leaf(.rows(.match(QueryText.match(text, in: .title))))
        case .caption:
            return .leaf(.rows(.match(QueryText.match(text, in: .caption))))
        case .ext:
            return .leaf(.rows(.match(QueryText.match("." + text, in: .name))))
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
            let lookups = plans.compactMap { plan in
                if case let .leaf(leaf) = plan {
                    Lookup(leaf)
                } else {
                    nil
                }
            }
            guard lookups.count > 1 else {
                var rows = rows(matching: plans[0], sets: sets)
                for plan in plans.dropFirst() {
                    rows.formUnion(self.rows(matching: plan, sets: sets))
                }
                return rows
            }
            var rows = rows(lookingUp: lookups)
            rows.formIntersection(live)
            for plan in plans {
                if case let .leaf(leaf) = plan, Lookup(leaf) != nil {
                    continue
                }
                rows.formUnion(self.rows(matching: plan, sets: sets))
            }
            return rows
        }
    }

    /// A leaf that looks each row's code up in a table: a folder, camera or lens term's, or one in a
    /// column of names. Free text under three characters is several, ORed (LIB-06).
    private enum Lookup {
        case folders(ContiguousArray<UInt64>)
        case cameras(ContiguousArray<UInt64>)
        case lenses(ContiguousArray<UInt64>)
        case codes(QueryPlan.CodeColumn, ContiguousArray<UInt64>)

        init?(_ leaf: QueryPlan.Leaf) {
            switch leaf {
            case let .folders(ids): self = .folders(ColumnStore.table(ids.map(Int.init)))
            case let .cameras(codes): self = .cameras(ColumnStore.table(codes.map(Int.init)))
            case let .lenses(codes): self = .lenses(ColumnStore.table(codes.map(Int.init)))
            case let .codes(column, table): self = .codes(column, table)
            default: return nil
            }
        }
    }

    /// The rows any of `lookups` accepts, dead ones included, in one pass over blocks of rows: each
    /// lookup ORs its bits into the block's words, and skips the words every row of which another
    /// has accepted already.
    private func rows(lookingUp lookups: [Lookup]) -> RowBits {
        var words = ContiguousArray<UInt64>(repeating: 0, count: (rowCount + 63) / 64)
        let rows = rowCount
        words.withUnsafeMutableBufferPointer { words in
            let block = 512
            var start = 0
            while start < words.count {
                let range = start ..< min(start + block, words.count)
                for lookup in lookups {
                    switch lookup {
                    case let .folders(table): Self.look(folders, up: table, into: words, range, rows: rows)
                    case let .cameras(table): Self.look(cameras, up: table, into: words, range, rows: rows)
                    case let .lenses(table): Self.look(lenses, up: table, into: words, range, rows: rows)
                    case let .codes(.creator, table): Self.look(creators, up: table, into: words, range, rows: rows)
                    case let .codes(.copyright, table): Self.look(copyrights, up: table, into: words, range, rows: rows)
                    case let .codes(.customLabel, table):
                        Self.look(customLabels, up: table, into: words, range, rows: rows)
                    case let .codes(.place, table): Self.look(places, up: table, into: words, range, rows: rows)
                    }
                }
                start = range.upperBound
            }
        }
        return RowBits(words: words)
    }

    /// ORs into each of `words` in `range` a bit for each of its 64 rows whose value in `column` has
    /// its bit in `table`, leaving words whose rows are all in already.
    @inline(__always)
    private static func look(
        _ column: StoreColumn<some Any>, up table: ContiguousArray<UInt64>,
        into words: UnsafeMutableBufferPointer<UInt64>,
        _ range: Range<Int>, rows: Int,
    ) {
        column.withUnsafeBufferPointer { column in
            table.withUnsafeBufferPointer { table in
                for index in range {
                    let first = index << 6
                    let count = min(64, rows - first)
                    let full: UInt64 = count == 64 ? .max : (1 << UInt64(count)) - 1
                    guard words[index] != full else { continue }
                    var word: UInt64 = 0
                    for offset in 0 ..< count {
                        let value = Int(column[first + offset])
                        let at = value >> 6
                        if value >= 0, at < table.count {
                            word |= (table[at] >> UInt64(value & 63) & 1) << UInt64(offset)
                        }
                    }
                    words[index] |= word
                }
            }
        }
    }

    /// `rows` without the photos lists leave out: those missing from their folders, which only Library Health's Missing
    /// check lists (DEC-59), and, unless `unreadable`, those that can't be read (LIB-40).
    func listed(_ rows: RowBits, unreadable: Bool = false) -> RowBits {
        var state = PhotoRecord.State.missing
        if !unreadable {
            state.insert(.unreadable)
        }
        var listed = rows
        listed.subtract(self.rows(matching: .leaf(.state(UInt8(state.rawValue))), sets: [:]))
        return listed
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
            fill(&words, column, codes: table)
        case let .present(column):
            fill(&words, present: column)
        case let .rows(set):
            return sets[set] ?? RowBits(rows: rowCount)
        }
        return RowBits(words: words)
    }

    /// Each word of `words` from 64 rows of the column of names `column`, a bit for each whose code is in `table`.
    @inline(__always)
    private func fill(
        _ words: inout ContiguousArray<UInt64>,
        _ column: QueryPlan.CodeColumn,
        codes table: ContiguousArray<UInt64>,
    ) {
        switch column {
        case .creator: Self.fill(&words, creators) { Self.lookUp(table, Int($0)) }
        case .copyright: Self.fill(&words, copyrights) { Self.lookUp(table, Int($0)) }
        case .customLabel: Self.fill(&words, customLabels) { Self.lookUp(table, Int($0)) }
        case .place: Self.fill(&words, places) { Self.lookUp(table, Int($0)) }
        }
    }

    /// Each word of `words` from 64 rows of the column of names `column`, a bit for each with a name.
    @inline(__always)
    private func fill(_ words: inout ContiguousArray<UInt64>, present column: QueryPlan.CodeColumn) {
        switch column {
        case .creator: Self.fill(&words, creators) { $0 == 0 ? 0 : 1 }
        case .copyright: Self.fill(&words, copyrights) { $0 == 0 ? 0 : 1 }
        case .customLabel: Self.fill(&words, customLabels) { $0 == 0 ? 0 : 1 }
        case .place: Self.fill(&words, places) { $0 == 0 ? 0 : 1 }
        }
    }

    /// Each word of `words` from 64 rows of `column`, a bit for each as `test` gives it.
    @inline(__always)
    private static func fill<T>(
        _ words: inout ContiguousArray<UInt64>,
        _ column: StoreColumn<T>,
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
        _ words: inout ContiguousArray<UInt64>,
        _ column: StoreColumn<some FixedWidthInteger & UnsignedInteger & Sendable>,
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
        _ matches: RowBits, in order: StoreColumn<Int32>, ascending: Bool, from start: Int, limit: Int, places: Int,
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
