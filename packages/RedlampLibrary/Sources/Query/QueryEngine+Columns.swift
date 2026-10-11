import Foundation
import RedlampDocument

/// What a metadata column of the filter bar counts its photos by (LIB-18): a facet, keywords or
/// collections.
public enum FacetColumn: String, Sendable, Hashable, CaseIterable, Codable {
    /// `focal35` is the focal length in 35 mm terms, `widestAperture` the lens's widest aperture.
    case date, camera, lens, iso, focal, focal35, aperture, widestAperture, keyword, label, folder, kind, orientation
    case flag, rating, creator, city, country, collection, customLabel

    /// The facet it counts by: days for dates; nil for keywords and collections, which count a photo
    /// under each of its keywords or collections and those above them.
    public var facet: Facet? {
        switch self {
        case .date: .day
        case .camera: .camera
        case .lens: .lens
        case .iso: .iso
        case .focal: .focal
        case .aperture: .aperture
        case .focal35: .focal35
        case .widestAperture: .widestAperture
        case .keyword, .collection: nil
        case .label: .label
        case .folder: .folder
        case .kind: .kind
        case .orientation: .orientation
        case .flag: .flag
        case .rating: .rating
        case .creator: .creator
        case .city: .city
        case .country: .country
        case .customLabel: .customLabel
        }
    }

    /// The field its values filter: a custom label's is `label`.
    public var field: LibraryQuery.Field {
        switch self {
        case .date: .date
        case .camera: .camera
        case .lens: .lens
        case .iso: .iso
        case .focal: .focal
        case .aperture: .aperture
        case .focal35: .focal35
        case .widestAperture: .widestAperture
        case .keyword: .keyword
        case .label, .customLabel: .label
        case .folder: .folder
        case .kind: .ext
        case .orientation: .orientation
        case .flag: .flag
        case .rating: .rating
        case .creator: .creator
        case .city: .city
        case .country: .country
        case .collection: .collection
        }
    }
}

/// A column to count, over the photos of `query`.
public struct FacetColumnRequest: Sendable, Hashable {
    public var column: FacetColumn
    public var query: LibraryQuery

    public init(_ column: FacetColumn, query: LibraryQuery) {
        self.column = column
        self.query = query
    }
}

/// How the photos of a column's query count by its values.
public struct FacetColumnCounts: Sendable, Hashable {
    /// The request it answers, by its place among those asked for.
    public let index: Int
    public let column: FacetColumn
    /// The photos the column's query finds in the source.
    public let total: Int
    /// The values, in the value's order, photos without one last (a nil name): for dates, each day;
    /// for keywords and collections, each one and every one above one, each counting the photos with
    /// it or one inside it once.
    public let values: [FacetValue]

    public init(index: Int, column: FacetColumn, total: Int, values: [FacetValue]) {
        self.index = index
        self.column = column
        self.total = total
        self.values = values
    }
}

public extension QueryEngine {
    /// The photos of `source` that `query` finds, in `sort`'s order, from the column store as it is now
    /// (loading it first if it hasn't been); `is:unpicked-moment` finds the source's moments as `moments`,
    /// its Tighter–Looser setting, finds them. Like `list`, it cancels nothing.
    func list(
        _ source: PhotoSource, matching query: LibraryQuery, sort: QuerySort = QuerySort(),
        moments: MomentSetting = MomentSetting(),
    ) async throws -> PhotoList {
        if await loadedSnapshot() == nil {
            try await load()
        }
        if snapshot().map({ !$0.0.keepsOrder(sort.key) }) == true {
            try await prepareOrder(sort.key)
        }
        guard let (store, vocabulary, generation) = snapshot() else {
            return PhotoList(source: source, sort: sort, ids: [])
        }
        var rows = try await rows(
            of: source, in: store, vocabulary: vocabulary, generation: generation, unreadable: query.findsUnreadable,
        )
        if let searchable = query.searchable {
            let found = try await matches(
                for: searchable, in: store, vocabulary: vocabulary, generation: generation,
                moments: MomentScope(source: source, setting: moments),
            )
            rows.formIntersection(found)
        }
        try Task.checkCancellation()
        return PhotoList(source: source, sort: sort, ids: store.ids(of: rows, sortedBy: sort))
    }

    /// How the photos of `source` that each request's query finds count by its column, handed over as
    /// each column is counted, in the order asked for; `moments` is the source's Tighter–Looser setting,
    /// as `list(_:matching:sort:moments:)` takes it. Columns counted for the same store, source and
    /// query are kept. A later request for facets or columns, or a search, cancels it.
    func columns(
        _ requests: [FacetColumnRequest], in source: PhotoSource, moments: MomentSetting = MomentSetting(),
    ) -> AsyncThrowingStream<FacetColumnCounts, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: FacetColumnCounts.self)
        let scope = MomentScope(source: source, setting: moments)
        let task = Task.detached(priority: .utility) { [self] in
            do {
                guard let (store, vocabulary, generation) = await loadedSnapshot() else {
                    return continuation.finish()
                }
                let today = today
                let sourceRows = try await rows(of: source, in: store, vocabulary: vocabulary, generation: generation)
                var withUnreadable: RowBits?
                for (index, request) in requests.enumerated() {
                    try Task.checkCancellation()
                    let searchable = request.query.searchable
                    let key = ColumnKey(
                        generation: generation, source: source, column: request.column, query: searchable,
                        today: today, moments: searchable?.findsMoments == true ? moments : nil,
                    )
                    if let kept = countedColumn(key) {
                        continuation.yield(FacetColumnCounts(
                            index: index, column: kept.column, total: kept.total, values: kept.values,
                        ))
                        continue
                    }
                    var rows = sourceRows
                    if request.query.findsUnreadable {
                        if withUnreadable == nil {
                            withUnreadable = try await self.rows(
                                of: source, in: store, vocabulary: vocabulary, generation: generation, unreadable: true,
                            )
                        }
                        rows = withUnreadable ?? rows
                    }
                    if let searchable {
                        let found = try await matches(
                            for: searchable, in: store, vocabulary: vocabulary, generation: generation,
                            moments: scope,
                        )
                        rows.formIntersection(found)
                    }
                    let values: [FacetValue]
                    if let facet = request.column.facet {
                        values = try store.counts(by: facet, of: rows, names: vocabulary.names).values
                    } else {
                        let kind = request.column == .collection ? PostingKind.collections : .keywords
                        values = try await store.levelCounts(
                            of: rows, postings: postings(kind), levels: vocabulary.levels(of: kind),
                            field: request.column.field,
                        )
                    }
                    let counts = FacetColumnCounts(
                        index: index, column: request.column, total: rows.count, values: values,
                    )
                    keepColumn(counts, for: key)
                    continuation.yield(counts)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        startFacets(task)
        return stream
    }

    /// The photos whose missing, offline or settling state the index has changed since the store
    /// last read them: after a volume goes offline or comes back, which marks every photo on it at
    /// once. Hand them to `update(photos:)`, or to `LibraryLive.photosChanged`.
    func photosWithChangedState() async throws -> [Int64] {
        guard let (store, _, _) = snapshot() else { return [] }
        let states = try await source.photoStates()
        var changed: [Int64] = []
        for (row, bits) in store.states.enumerated() where bits != 0 && store.live.contains(row) {
            let id = store.ids[row]
            if UInt8(clamping: (states[id]?.rawValue ?? 0) & 0xFF) != bits {
                changed.append(id)
            }
        }
        for (id, state) in states {
            guard let row = store.row(of: id), store.states[row] == 0 else { continue }
            if UInt8(clamping: state.rawValue & 0xFF) != 0 {
                changed.append(id)
            }
        }
        return changed.sorted()
    }
}

// MARK: - Keywords and collections

/// What a photo has several of, which a column counts it under each of.
enum PostingKind: Sendable, Hashable {
    case keywords, collections
}

/// Each photo's keywords or collections, in the order of their photos' IDs.
struct KeywordPostings: Sendable {
    private(set) var pairs: [PhotoKeyword] = []

    init(_ pairs: [PhotoKeyword] = []) {
        self.pairs = pairs
    }

    /// Replaces the keywords of photos `ids` with `fresh`, theirs as the index has them now.
    mutating func replace(photos ids: Set<Int64>, with fresh: [PhotoKeyword]) {
        let kept = pairs.filter { !ids.contains($0.photo) }
        var merged: [PhotoKeyword] = []
        merged.reserveCapacity(kept.count + fresh.count)
        var incoming = fresh.sorted { ($0.photo, $0.keyword) < ($1.photo, $1.keyword) }[...]
        for pair in kept {
            while let next = incoming.first, next.photo < pair.photo {
                merged.append(next)
                incoming = incoming.dropFirst()
            }
            merged.append(pair)
        }
        merged.append(contentsOf: incoming)
        pairs = merged
    }
}

/// The library's keywords and every keyword above one, numbered, for counting photos by them; or its
/// collections and the sets above them.
struct KeywordLevels: Sendable {
    /// The paths, the keywords' and those above them.
    let paths: [String]
    /// By keyword ID: the numbers of its path and of each path above it.
    let levels: [[Int32]]
    /// The paths' numbers in the Finder's order.
    let order: [Int32]

    init(_ keywords: [Int64: String]) {
        var number: [String: Int32] = [:]
        var paths: [String] = []
        func numbered(_ path: String) -> Int32 {
            if let known = number[path] {
                return known
            }
            let next = Int32(paths.count)
            number[path] = next
            paths.append(path)
            return next
        }
        let largest = Int(keywords.keys.max() ?? -1)
        var levels = [[Int32]](repeating: [], count: max(largest + 1, 0))
        for (id, text) in keywords where id >= 0 {
            guard let path = KeywordPath(text) else { continue }
            levels[Int(id)] = (path.ancestors + [path]).map { numbered($0.text) }
        }
        let keys = paths.map(FinderOrder.key)
        order = paths.indices.sorted { lhs, rhs in
            keys[lhs] == keys[rhs] ? paths[lhs] < paths[rhs] : keys[lhs].lexicographicallyPrecedes(keys[rhs])
        }.map { Int32($0) }
        self.paths = paths
        self.levels = levels
    }
}

extension QueryVocabulary {
    /// The keywords' or the collections' levels, made the first time a column of them is counted.
    func levels(of kind: PostingKind) -> KeywordLevels {
        levels.withLock { levels in
            if let made = levels[kind] {
                return made
            }
            let made = KeywordLevels(kind == .keywords ? names.keywords : names.collections)
            levels[kind] = made
            return made
        }
    }
}

extension ColumnStore {
    /// How the rows of `matches` count by keyword or collection (`field`): each one and each one above
    /// it counts the photos with it or one inside it once, in path order, then the photos with none.
    func levelCounts(
        of matches: RowBits, postings: KeywordPostings, levels: KeywordLevels, field: LibraryQuery.Field,
    ) throws -> [FacetValue] {
        var counts = [Int](repeating: 0, count: levels.paths.count)
        var lastRow = [Int](repeating: -1, count: levels.paths.count)
        var withKeywords = 0
        var lastPhotoRow = -1
        for (offset, pair) in postings.pairs.enumerated() {
            if offset & 0xFFF == 0, Task.isCancelled {
                throw CancellationError()
            }
            guard let row = row(of: pair.photo), matches.wordCount > row >> 6, matches.contains(row),
                  pair.keyword >= 0, Int(pair.keyword) < levels.levels.count
            else { continue }
            if row != lastPhotoRow {
                lastPhotoRow = row
                withKeywords += 1
            }
            for level in levels.levels[Int(pair.keyword)] where lastRow[Int(level)] != row {
                lastRow[Int(level)] = row
                counts[Int(level)] += 1
            }
        }
        var values: [FacetValue] = []
        for number in levels.order where counts[Int(number)] > 0 {
            let path = levels.paths[Int(number)]
            values.append(FacetValue(
                name: path, count: counts[Int(number)],
                filter: .filter(LibraryQuery.Filter(field, .equal, [.text(path)])),
            ))
        }
        let without = matches.count - withKeywords
        return values + (without > 0 ? [FacetValue(name: nil, count: without, filter: nil)] : [])
    }
}

// MARK: - Completions

/// A term the filter bar offers to complete what's typed (LIB-18), or a name the palette lists
/// (LIB-19): a field's value from the index.
public struct QueryCompletion: Sendable, Hashable {
    public var field: LibraryQuery.Field
    /// The value as the library names it: a keyword's or a collection's path, a camera's or a lens's
    /// name, a folder's path, a label's name, a colour's or a custom label's, a trait's or an
    /// orientation's, a place's.
    public var value: String
    /// The term as the language writes it: `kw:"Places/Portugal"`, `camera:"X-T5"`, `is:panorama`,
    /// `orientation:portrait`.
    public var term: String
    /// For a trait or an orientation, the photos of the source it finds.
    public var count: Int?
    /// For a name found with a word a typo or two from what was typed, how many (`NameRanking`);
    /// 0 for a name holding what was typed.
    public var typos: Int

    public init(field: LibraryQuery.Field, value: String, count: Int? = nil, typos: Int = 0) {
        self.field = field
        self.value = value
        self.count = count
        self.typos = typos
        term = LibraryQuery.Filter(field, .equal, [Self.queryValue(field, value)]).description
    }

    private static func queryValue(_ field: LibraryQuery.Field, _ value: String) -> LibraryQuery.Value {
        if field == .label, let label = ColorLabel(rawValue: value.lowercased()) {
            return .label(label)
        }
        if field == .trait, let trait = LibraryQuery.Trait(rawValue: value) {
            return .trait(trait)
        }
        if field == .orientation, let orientation = PhotoOrientation(rawValue: value) {
            return .orientation(orientation)
        }
        return .text(value)
    }

    /// The query the term for a trait or an orientation stands for; nil for another field's.
    var counted: LibraryQuery? {
        if field == .trait, let trait = LibraryQuery.Trait(rawValue: value) {
            return .filter(LibraryQuery.Filter(.trait, .equal, [.trait(trait)]))
        }
        guard field == .orientation, let orientation = PhotoOrientation(rawValue: value) else { return nil }
        return .filter(LibraryQuery.Filter(.orientation, .equal, [.orientation(orientation)]))
    }

    /// The fields completion has values for, in the order it offers them.
    public static let fields: [LibraryQuery.Field] = [
        .keyword, .camera, .lens, .folder, .label, .collection, .trait, .orientation, .city, .country, .state,
        .sublocation,
    ]
}

public extension QueryEngine {
    /// The values of `field`, or of every field completion has values for when it's nil
    /// (`QueryCompletion.fields`), best first, as `NameRanking` ranks them: as the filter bar's text
    /// completes a term. A trait or an orientation comes with the photos of `source` it finds, the
    /// moments without a pick as `moments`, the source's Tighter–Looser setting, finds them. Nothing runs
    /// on the caller's thread.
    func completions(
        _ typed: String, field: LibraryQuery.Field?, limit: Int = 8, in source: PhotoSource = .allPhotographs,
        moments: MomentSetting = MomentSetting(),
    ) async -> [QueryCompletion] {
        await completions(
            typed, fields: field.map { [$0] } ?? QueryCompletion.fields, limit: limit, in: source, moments: moments,
        )
    }

    /// The values of `fields` best first, ties going to the field listed first: as the palette lists
    /// the library's names (LIB-19).
    func completions(
        _ typed: String, fields: [LibraryQuery.Field], limit: Int = 8, in source: PhotoSource = .allPhotographs,
        moments: MomentSetting = MomentSetting(),
    ) async -> [QueryCompletion] {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, limit > 0, let (store, vocabulary, generation) = await loadedSnapshot() else {
            return []
        }
        let completions = await Task.detached(priority: .userInitiated) { [self] in
            vocabulary.completions(typed, fields: fields, limit: limit, storeNames: storeNames(of: store))
        }.value
        return await counted(
            completions, in: source, moments: moments, store: store, vocabulary: vocabulary, generation: generation,
        )
    }

    /// Every value of `field` completion offers without its text: the traits, the orientations or the colour
    /// labels, in that order, each trait and orientation with the photos of `source` it finds, as `completions`
    /// counts them; none for another field, whose values are the library's names (LIB-19).
    func values(
        of field: LibraryQuery.Field, in source: PhotoSource = .allPhotographs,
        moments: MomentSetting = MomentSetting(),
    ) async -> [QueryCompletion] {
        let values: [QueryCompletion] = switch field {
        case .trait: LibraryQuery.Trait.allCases.map { QueryCompletion(field: .trait, value: $0.rawValue) }
        case .orientation: PhotoOrientation.allCases.map { QueryCompletion(field: .orientation, value: $0.rawValue) }
        case .label: ColorLabel.allCases.map { QueryCompletion(field: .label, value: $0.rawValue) }
        default: []
        }
        guard !values.isEmpty, let (store, vocabulary, generation) = await loadedSnapshot() else { return values }
        return await counted(
            values, in: source, moments: moments, store: store, vocabulary: vocabulary, generation: generation,
        )
    }

    /// `completions` with each trait's and orientation's count of the photos of `source` it finds.
    private func counted(
        _ completions: [QueryCompletion], in source: PhotoSource, moments: MomentSetting, store: ColumnStore,
        vocabulary: QueryVocabulary, generation: Int,
    ) async -> [QueryCompletion] {
        guard completions.contains(where: { $0.counted != nil }),
              let photos = try? await rows(of: source, in: store, vocabulary: vocabulary, generation: generation)
        else { return completions }
        var completions = completions
        for (place, completion) in completions.enumerated() {
            guard let query = completion.counted,
                  var found = try? await matches(
                      for: query.searchable, in: store, vocabulary: vocabulary, generation: generation,
                      moments: MomentScope(source: source, setting: moments),
                  )
            else { continue }
            found.formIntersection(photos)
            completions[place].count = found.count
        }
        return completions
    }
}

extension QueryVocabulary {
    /// The names of `fields` ranked for `typed` (`NameRanking`): the small tables', the colour
    /// labels, traits and orientations, and `storeNames`, the names the store's columns hold.
    func completions(
        _ typed: String, fields: [LibraryQuery.Field], limit: Int, storeNames: NameTable? = nil,
    ) -> [QueryCompletion] {
        let tables = [rankedNames(), NameTable.fixed] + (storeNames.map { [$0] } ?? [])
        return NameRanking.rank(typed, in: tables, fields: fields, limit: limit).map { match in
            QueryCompletion(field: match.field, value: match.value, typos: match.typos)
        }
    }

    /// The small tables' names ranked for completion: keywords with their synonyms, collections,
    /// folders, cameras and lenses.
    func rankedNames() -> NameTable {
        ranked.withLock { table in
            if let table {
                return table
            }
            var ranked: [RankedName] = []
            ranked.reserveCapacity(names.keywords.count + names.folders.count + names.collections.count + 64)
            for (_, path) in names.keywords.sorted(by: { $0.key < $1.key }) {
                ranked.append(.levels(.keyword, path: path, others: names.keywordSynonyms[path] ?? []))
            }
            for (_, path) in names.collections.sorted(by: { $0.key < $1.key }) {
                ranked.append(.levels(.collection, path: path))
            }
            for (_, path) in names.folders.sorted(by: { $0.key < $1.key }) {
                ranked.append(.folder(path))
            }
            for camera in Set(names.cameras.values).sorted() {
                ranked.append(RankedName(.camera, camera))
            }
            for lens in Set(names.lenses.values).sorted() {
                ranked.append(RankedName(.lens, lens))
            }
            let made = NameTable(ranked)
            table = made
            return made
        }
    }
}

extension NameTable {
    /// The colour labels, the traits by title, by word and by their synonyms, and the orientations.
    static let fixed = NameTable(
        ColorLabel.allCases.map { RankedName(.label, $0.rawValue) }
            + LibraryQuery.Trait.allCases.map(traitName)
            + PhotoOrientation.allCases.map { RankedName(.orientation, $0.rawValue) },
    )

    /// A trait's name: its title, and its word and synonyms beside it.
    private static func traitName(_ trait: LibraryQuery.Trait) -> RankedName {
        RankedName(.trait, trait.rawValue, name: trait.title, others: [trait.rawValue] + trait.synonyms)
    }

    /// The names `store`'s columns hold that completion offers: custom labels, and places' parts.
    init(storeNames store: ColumnStore) {
        var names = store.customLabelNames.names.dropFirst().map { RankedName(.label, $0) }
        for (part, field) in Self.placeFields {
            names += store.placeNames.parts[part.rawValue].names.dropFirst().map { RankedName(field, $0) }
        }
        self.init(names)
    }

    /// The lists of names `init(storeNames:)` makes a table of, to tell when they've changed.
    static func storeNameLists(_ store: ColumnStore) -> [ContiguousArray<String>] {
        [store.customLabelNames.names] + placeFields.map { store.placeNames.parts[$0.part.rawValue].names }
    }

    private static let placeFields: [(part: PlaceCodes.Part, field: LibraryQuery.Field)] = [
        (.city, .city), (.country, .country), (.state, .state), (.sublocation, .sublocation),
    ]
}
