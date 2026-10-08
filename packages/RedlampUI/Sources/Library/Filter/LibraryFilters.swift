import Foundation
import Observation
import RedlampDocument
import RedlampLibrary

/// The Library filter bar (LIB-18), as Lightroom Classic's: Text, Attribute and Metadata over one
/// query in the library's language, the sort, saved filters, and a lock that keeps one filter across
/// sources. Each source keeps its own filter and sort, for the 25 latest sources and across launches,
/// so a folder's filter is there again when it's shown again; the Library panel's entries and the
/// collections are sources as folders are (LIB-23).
///
/// Typing never waits on the engine: the text is read as it's typed and handed to the library's list
/// of the source, which works out the photos off the main thread, the latest filter winning
/// (`LibraryFolderList`, `LibrarySourceList`). The metadata columns are counted once the list is
/// shown, each over the photos of the filter but its own choice and those of the columns after it, so
/// choosing in one narrows the next. A filter that finds none of the source's photos gets two offers,
/// each going with the query it was found for: the term whose removal brings back the most photos,
/// and a name a typo or two from a word of a term.
@MainActor
@Observable
public final class LibraryFilters {
    /// The bar is shown above the grid and the loupe (`\`).
    public internal(set) var isBarShown = false
    /// The source the bar shows and edits, by `key(_:includingSubfolders:)` for a folder, or the Library
    /// panel's entry's or the collection's `LibrarySource.key`.
    public private(set) var source: String?
    public private(set) var filter = LibraryFilter()
    public private(set) var sort = LibrarySort()
    /// The filter is kept as sources change.
    public private(set) var isLocked = false
    /// Redlamp's presets, then the user's, by name.
    public private(set) var presets: [FilterPreset] = FilterPreset.builtIn
    /// Why the text can't be read, while it can't: the photos stay filtered by what it last could.
    public private(set) var error: LibraryQueryError?
    /// The photos the filter found, of the source's, as the library last listed them.
    public private(set) var listed: (shown: Int, total: Int)?
    /// Each metadata column's counts, by its place.
    public private(set) var columns: [Int: FacetColumnCounts] = [:]
    /// What the term being typed could be, best first, and the characters it replaces.
    public private(set) var completions: [FilterCompletion] = []
    @ObservationIgnored public private(set) var completionRange: Range<Int>?
    /// While the filter finds none of the source's photos: the term whose removal brings back the
    /// most of them, which the bar offers to take out.
    public private(set) var removal: QueryRemoval?
    /// Meanwhile, a name of the library's a typo or two from a word of one of the terms, which the bar
    /// offers to put in the word's place ("Did you mean Lisbon?").
    public private(set) var suggestion: QuerySuggestion?
    /// How long the last suggestion took from the list that found nothing, for the harness.
    @ObservationIgnored @_spi(Harness) public private(set) var lastSuggesting: Duration?
    /// Counts the lists the library handed over, and the filter of the last, for the harness.
    @ObservationIgnored @_spi(Harness) public private(set) var listings = 0
    @ObservationIgnored @_spi(Harness) public private(set) var lastListed: LibraryListFilterSummary?
    /// How long the last list took off the main thread: the query engine finding its photos, then the list.
    @ObservationIgnored @_spi(Harness) public private(set) var lastListing: (query: Duration, list: Duration)?

    @ObservationIgnored weak var service: LibraryService?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let presetsURL: URL?
    @ObservationIgnored private var sources: [SourceFilter] = []
    /// The source's photos, as the query engine knows them.
    @ObservationIgnored private var photos: PhotoSource?
    /// The list of the Library panel's entry or the collection shown, which its filter is handed to.
    @ObservationIgnored weak var sourceList: LibrarySourceList?
    /// The query the photos are filtered by while the text has an error.
    @ObservationIgnored private var applied: LibraryQuery?
    @ObservationIgnored private var counting: Task<Void, Never>?
    @ObservationIgnored private var completing: Task<Void, Never>?
    @ObservationIgnored private var findingRemoval: Task<Void, Never>?
    @ObservationIgnored private var findingSuggestion: Task<Void, Never>?
    /// The search for a suggestion for the query last handed to the list, started with it (`suggest`).
    @ObservationIgnored private var suggesting: (
        query: LibraryQuery, photos: PhotoSource, task: Task<QuerySuggestion?, Never>,
    )?
    @ObservationIgnored private var countAgain = false
    @ObservationIgnored private var lastChange = ContinuousClock.now
    /// The text has the keyboard: the active photo stays as it is until it's given back.
    @ObservationIgnored public internal(set) var isTyping = false

    /// How long the columns wait after the filter or the photos change, so typing isn't held up by
    /// counts it would replace a key later.
    static let columnDelay = Duration.milliseconds(120)

    static let keptSources = 25
    private static let stateKey = "library.filters"

    /// A source's filter and sort as it was left.
    struct SourceFilter: Codable, Equatable {
        var source: String
        var filter: LibraryFilter
        var sort: LibrarySort
    }

    private struct Saved: Codable {
        var sources: [SourceFilter]
        var isLocked: Bool
        var isBarShown: Bool
        var locked: LibraryFilter?
    }

    /// `defaults` keeps each source's filter, the lock and the bar; `presetsURL` the user's presets, as
    /// a readable file beside the index.
    init(defaults: UserDefaults?, presetsURL: URL?) {
        self.defaults = defaults
        self.presetsURL = presetsURL
        if let data = defaults?.data(forKey: Self.stateKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            sources = saved.sources
            isLocked = saved.isLocked
            isBarShown = saved.isBarShown
            if isLocked, let locked = saved.locked {
                filter = locked
            }
        }
        if let presetsURL, let data = try? Data(contentsOf: presetsURL),
           let saved = try? JSONDecoder().decode([FilterPreset].self, from: data) {
            presets = FilterPreset.builtIn + saved.map { FilterPreset(name: $0.name, filter: $0.filter) }
        }
        applied = filter.query
    }

    /// The key a source's filter is kept under: the folder's path, `+` first with its subfolders.
    nonisolated static func key(_ folder: URL, includingSubfolders: Bool) -> String {
        (includingSubfolders ? "+" : "") + folder.path
    }

    // MARK: - Sources

    /// Shows `folder` in the bar: its own filter and sort, or with the lock on, the filter kept.
    public func follow(_ folder: URL?, includingSubfolders: Bool) {
        follow(
            folder.map { Self.key($0, includingSubfolders: includingSubfolders) },
            photos: folder.map { .folder($0, includingSubfolders: includingSubfolders) },
        )
    }

    /// Shows the Library panel's entry or the collection `source` in the bar, `photos` as the library lists
    /// them, as a folder is shown.
    func follow(_ source: LibrarySource, photos: PhotoSource) {
        follow(source.key, photos: photos)
    }

    private func follow(_ key: String?, photos: PhotoSource?) {
        self.photos = photos
        if isBarShown {
            service?.engine?.prepareNames()
        }
        guard key != source else { return }
        source = key
        let kept = key.flatMap { key in sources.last { $0.source == key } }
        if !isLocked {
            filter = kept?.filter ?? LibraryFilter(sections: filter.sections, columns: filter.columns)
        }
        sort = kept?.sort ?? LibrarySort()
        read()
        listed = nil
        columns = [:]
        completions = []
        withdrawOffers()
        remember()
    }

    /// What the library's list of a folder is filtered and sorted by.
    func request(for folder: URL, includingSubfolders: Bool) -> LibraryListFilter {
        request(for: Self.key(folder, includingSubfolders: includingSubfolders))
    }

    /// What the library's list of the source kept under `key` is filtered and sorted by.
    func request(for key: String) -> LibraryListFilter {
        if key == source {
            return LibraryListFilter(query: filter.isEnabled ? applied : nil, sort: sort)
        }
        let kept = sources.last { $0.source == key }
        let filter = isLocked ? filter : kept?.filter
        return LibraryListFilter(query: filter?.query, sort: kept?.sort ?? LibrarySort())
    }

    // MARK: - Changing the filter

    /// The text as it's typed: the photos follow what it reads as, and stay as they were while it has
    /// an error.
    public func setText(_ text: String) {
        guard text != filter.text else { return }
        filter.text = text
        if !filter.isEnabled, !text.isEmpty {
            filter.isEnabled = true
        }
        read()
        changed()
    }

    /// Another filter for the source: a preset's, or the bar's attributes and columns.
    public func setFilter(_ filter: LibraryFilter) {
        guard filter != self.filter else { return }
        self.filter = filter
        read()
        changed()
    }

    /// The rules the bar's attributes and columns change: the text becomes what they write.
    public func edit(_ change: (QueryRules) -> QueryRules) {
        setFilter(filter.with(change(rules)))
    }

    /// The query's rules as the bar's attributes and columns show them: while the text has an error,
    /// those of what it last read as.
    public var rules: QueryRules {
        error == nil ? filter.rules : applied.map(QueryRules.init) ?? QueryRules()
    }

    /// The filter on or off (⌘L), keeping it.
    public func setEnabled(_ enabled: Bool) {
        guard enabled != filter.isEnabled else { return }
        filter.isEnabled = enabled
        if enabled, filter.sections.isEmpty {
            filter.sections = [.text]
        }
        changed()
    }

    /// A section of the bar shown or hidden; `adding` (⇧-click) keeps the others. None hides them all
    /// and turns the filter off.
    public func show(_ section: FilterSection?, adding: Bool = false) {
        var next = filter
        if let section {
            if adding {
                next.sections.formSymmetricDifference([section])
            } else {
                next.sections = next.sections == [section] ? [] : [section]
            }
            next.isEnabled = !next.sections.isEmpty
        } else {
            next.sections = []
            next.isEnabled = false
        }
        setFilter(next)
    }

    public func setColumns(_ columns: [FacetColumn]) {
        var next = filter
        next.columns = Array(columns.prefix(LibraryFilter.maxColumns))
        setFilter(next)
    }

    public func setSort(_ sort: LibrarySort) {
        guard sort != self.sort else { return }
        self.sort = sort
        changed()
    }

    /// Keeps the filter as sources change, or lets each source have its own again.
    public func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        remember()
    }

    public func setBarShown(_ shown: Bool) {
        guard shown != isBarShown else { return }
        isBarShown = shown
        remember()
        if shown {
            service?.engine?.prepareNames()
            countColumns()
        }
    }

    /// Clears the query, keeping the sections and columns.
    public func clear() {
        var next = filter
        next.text = ""
        setFilter(next)
    }

    private func read() {
        switch filter.parsed {
        case let .success(query):
            error = nil
            applied = query == .all ? nil : query
        case let .failure(failure):
            error = failure
        }
    }

    private func changed() {
        withdrawOffers()
        remember()
        apply()
    }

    /// Hands the filter to the library's list of the source shown.
    private func apply() {
        guard let source, let photos else { return }
        suggest(filter.isEnabled ? applied : nil, in: photos)
        let request = request(for: source)
        if case let .folder(folder, subfolders) = photos {
            if service?.filter(folder, includingSubfolders: subfolders, by: request) == true {
                return
            }
        } else if let list = sourceList, list.source == photos {
            list.setFilter(request)
            return
        }
        countColumns()
    }

    private func remember() {
        if let source {
            sources.removeAll { $0.source == source }
            sources.append(SourceFilter(source: source, filter: filter, sort: sort))
            if sources.count > Self.keptSources {
                sources.removeFirst(sources.count - Self.keptSources)
            }
        }
        let saved = Saved(sources: sources, isLocked: isLocked, isBarShown: isBarShown, locked: isLocked ? filter : nil)
        if let defaults, let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: Self.stateKey)
        }
    }

    // MARK: - Presets

    /// The preset the filter is, if it's one.
    public var preset: FilterPreset? {
        presets.first { $0.matches(filter) }
    }

    public func choose(_ preset: FilterPreset) {
        setFilter(preset.filter)
    }

    /// Saves the filter as a preset called `name`, replacing the user's preset of that name.
    public func save(as name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !FilterPreset.builtIn.contains(where: { $0.name == name }) else { return }
        presets.removeAll { !$0.isBuiltIn && $0.name == name }
        presets.append(FilterPreset(name: name, filter: filter))
        savePresets()
    }

    public func delete(_ preset: FilterPreset) {
        guard !preset.isBuiltIn else { return }
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }

    private func savePresets() {
        guard let presetsURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(presets.filter { !$0.isBuiltIn }) else { return }
        try? FileManager.default.createDirectory(
            at: presetsURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try? data.write(to: presetsURL, options: .atomic)
    }

    // MARK: - What the library listed

    /// The library handed over the source's filtered or sorted list.
    func listed(_ listing: LibraryListing) {
        listings += 1
        lastListed = LibraryListFilterSummary(
            query: listing.filter.query, sort: listing.filter.sort, reversed: listing.filter.reversed,
        )
        lastListing = listing.took
        if listed?.shown != listing.shown || listed?.total != listing.total {
            listed = (listing.shown, listing.total)
        }
        countColumns()
        findOffers(after: listing)
    }

    // MARK: - A filter that finds nothing

    /// When the list the filter made is empty and the source isn't: the term to offer to take out, and a name
    /// to offer in a misspelt word's place, each found off the main thread. Any other list takes them back, and
    /// so does a list made for an earlier query, whose own list follows.
    private func findOffers(after listing: LibraryListing) {
        findingRemoval?.cancel()
        findingSuggestion?.cancel()
        (findingRemoval, findingSuggestion) = (nil, nil)
        guard listing.shown == 0, listing.total > 0, let query = listing.filter.query,
              query == (filter.isEnabled ? applied : nil), let photos, let engine = service?.engine
        else {
            withdrawOffers()
            return
        }
        findingRemoval = Task { [weak self] in
            let found = try? await engine.removal(from: query, in: photos)
            guard !Task.isCancelled, let self else { return }
            if removal != found {
                removal = found
            }
        }
        let started = ContinuousClock.now
        suggest(query, in: photos)
        guard let searching = suggesting?.task else { return }
        // A search answers one list: the next, made once the photos have changed, looks again.
        suggesting = nil
        findingSuggestion = Task { [weak self] in
            let found = await searching.value
            guard !Task.isCancelled, let self else { return }
            if suggestion != found {
                suggestion = found
            }
            lastSuggesting = .now - started
        }
    }

    /// Looks for a suggestion for `query` in `photos` off the main thread, unless that search is under way: from
    /// the moment the query is handed to the list, so a key that finds nothing has its offer about as soon as the
    /// list. A query that finds photos costs the engine a count before it gives none.
    private func suggest(_ query: LibraryQuery?, in photos: PhotoSource) {
        guard let query, let engine = service?.engine else {
            suggesting?.task.cancel()
            suggesting = nil
            return
        }
        if let suggesting, suggesting.query == query, suggesting.photos == photos {
            return
        }
        suggesting?.task.cancel()
        let task = Task.detached(priority: .userInitiated) { try? await engine.suggestion(for: query, in: photos) }
        suggesting = (query, photos, task)
    }

    /// The filter changed: the offers, and the search for them, go.
    private func withdrawOffers() {
        findingRemoval?.cancel()
        findingSuggestion?.cancel()
        (findingRemoval, findingSuggestion) = (nil, nil)
        if removal != nil {
            removal = nil
        }
        if suggestion != nil {
            suggestion = nil
        }
    }

    /// Puts the name the bar offers in the misspelt word's place.
    public func takeSuggestion() {
        guard let suggestion else { return }
        edit { rules in
            guard rules.rules.indices.contains(suggestion.index),
                  rules.rules[suggestion.index] == suggestion.rule else {
                return rules
            }
            var rules = rules
            rules.rules[suggestion.index] = suggestion.replacement
            return rules
        }
    }

    /// Takes the term the bar offers out of the filter.
    public func takeOutRemoval() {
        guard let removal else { return }
        edit { rules in
            guard rules.rules.indices.contains(removal.index), rules.rules[removal.index] == removal.rule else {
                return rules
            }
            var rules = rules
            rules.rules.remove(at: removal.index)
            return rules
        }
    }

    /// Counts the metadata columns again, once what's under way is done: when the source's photos
    /// change, or the columns are shown.
    public func countColumns() {
        guard isBarShown, filter.sections.contains(.metadata), let photos, let engine = service?.engine else { return }
        guard counting == nil else {
            countAgain = true
            lastChange = .now
            return
        }
        let key = source
        lastChange = .now
        counting = Task { [weak self] in
            while let self, ContinuousClock.now - lastChange < Self.columnDelay {
                try? await Task.sleep(for: lastChange + Self.columnDelay - ContinuousClock.now)
            }
            guard let requests = self?.columnRequests() else { return }
            do {
                for try await counts in engine.columns(requests, in: photos) {
                    guard let self, source == key else { break }
                    if columns[counts.index] != counts {
                        columns[counts.index] = counts
                    }
                }
            } catch {}
            self?.counted()
        }
    }

    private func counted() {
        counting = nil
        if countAgain {
            countAgain = false
            countColumns()
        }
    }

    /// Each column's request: the filter without the choices of this column and those after it.
    func columnRequests() -> [FacetColumnRequest] {
        let rules = filter.isEnabled ? rules : QueryRules()
        return filter.columns.indices.map { index in
            var narrowed = rules
            for column in filter.columns[index...] {
                narrowed = narrowed.replacingFilters(on: column.field, with: nil)
            }
            return FacetColumnRequest(filter.columns[index], query: LibraryQuery(narrowed))
        }
    }

    // MARK: - Completion

    /// Offers what the term ending at `cursor` in `text` could be: a field, or a value from the index.
    public func complete(_ text: String, cursor: Int) {
        completing?.cancel()
        guard let term = FilterTerm(text, cursor: cursor), let engine = service?.engine else {
            completions = []
            completionRange = nil
            return
        }
        let source = photos ?? .allPhotographs
        completing = Task { [weak self] in
            let values = await engine.completions(term.value, field: term.field, limit: 8, in: source)
            guard !Task.isCancelled, let self else { return }
            let fields = term.field == nil ? FilterTerm.fields(startingWith: term.value) : []
            completions = (fields + values.map(FilterCompletion.init)).map { $0.negated(term.negated) }
            completionRange = term.range
        }
    }

    public func endCompletion() {
        completing?.cancel()
        completions = []
        completionRange = nil
    }
}

/// What the bar offers while the filter finds none of the source's photos (LIB-18): a name of the library's in a
/// misspelt word's place, and the term whose removal brings back the most photos. Each is made from the query and
/// changes it, so it can be shown wherever the query's text is.
public struct FilterOffer: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case suggestion, removal
    }

    public let kind: Kind
    /// What its button says: `Did you mean Lisbon? 2 photos`, `Remove kw:zzzz: 12 photos`.
    public let title: String
    /// What it does, for its help.
    public let help: String
}

public extension LibraryFilters {
    /// The offers for the filter while it finds none of the source's photos, the suggestion first.
    var offers: [FilterOffer] {
        var offers: [FilterOffer] = []
        if let suggestion {
            let photos = Self.photos(suggestion.count)
            offers.append(FilterOffer(
                kind: .suggestion, title: "Did you mean \(suggestion.name)? \(photos)",
                help: "No photo matches every term of the filter; with \(suggestion.term) in place of "
                    + "\(LibraryQuery(suggestion.rule).description) it finds \(photos)",
            ))
        }
        if let removal {
            let photos = Self.photos(removal.count)
            offers.append(FilterOffer(
                kind: .removal, title: "Remove \(removal.term): \(photos)",
                help: "No photo matches every term of the filter; without \(removal.term) it finds \(photos)",
            ))
        }
        return offers
    }

    /// Takes the offer of `kind`: the name in the misspelt word's place, or the term out of the filter.
    func take(_ kind: FilterOffer.Kind) {
        switch kind {
        case .suggestion: takeSuggestion()
        case .removal: takeOutRemoval()
        }
    }

    private static func photos(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count.formatted()) photos"
    }
}

/// A list the library handed over for the source the bar shows, made by its filter or sort.
struct LibraryListing {
    /// The photos the filter found, of the source's.
    var shown: Int
    var total: Int
    var filter: LibraryListFilter
    /// How long the query engine took to find its photos, and the list to be made of them.
    var took: (query: Duration, list: Duration)
}

/// The filter of a list the library handed over, for the harness.
@_spi(Harness) public struct LibraryListFilterSummary: Sendable, Hashable {
    public let query: LibraryQuery?
    public let sort: QuerySort?
    /// The folder's own order, the other way round.
    public let reversed: Bool
}

/// A row of the text's completions: a field to type a value for, or a value of one.
public struct FilterCompletion: Sendable, Hashable {
    /// What the row shows: `Places › Portugal`, `Fujifilm X-T5`, `rating:`, `Long Exposure`.
    public var title: String
    /// What it is: `Keyword`, `Camera`, `Field`, `Trait`, `City`.
    public var kind: String
    /// What replaces the term: a term of the language, then a space, or a field's name and `:`.
    public var text: String
    /// For a trait, the source's photos it finds.
    public var count: Int?

    init(title: String, kind: String, text: String, count: Int? = nil) {
        self.title = title
        self.kind = kind
        self.text = text
        self.count = count
    }

    init(_ completion: QueryCompletion) {
        let title = switch completion.field {
        case .keyword, .collection: KeywordPath(completion.value)?.displayName ?? completion.value
        case .folder: URL(fileURLWithPath: completion.value).pathComponents.suffix(2).joined(separator: "/")
        case .label: ColorLabel(rawValue: completion.value) == nil ? completion.value : completion.value.capitalized
        case .trait: LibraryQuery.Trait(rawValue: completion.value)?.title ?? completion.value
        case .orientation: PhotoOrientation(rawValue: completion.value)?.title ?? completion.value
        default: completion.value
        }
        let kind = switch completion.field {
        case .keyword: "Keyword"
        case .camera: "Camera"
        case .lens: "Lens"
        case .folder: "Folder"
        case .label: ColorLabel(rawValue: completion.value) == nil ? "Custom Label" : "Label"
        case .collection: "Collection"
        case .trait: "Trait"
        case .orientation: "Orientation"
        case .sublocation: "Sublocation"
        case .city: "City"
        case .state: "State or Province"
        case .country: "Country"
        default: completion.field.rawValue
        }
        self.init(title: title, kind: kind, text: completion.term + " ", count: completion.count)
    }

    func negated(_ negated: Bool) -> FilterCompletion {
        negated ? FilterCompletion(title: title, kind: kind, text: "-" + text, count: count) : self
    }

    /// What the row shows of what it is: its kind, and a trait's count.
    var detail: String {
        count.map { "\(kind) · \($0.formatted())" } ?? kind
    }
}

/// The term of the text that ends at the cursor, as completion reads it: from after the last space
/// outside quotes, a `-` before it aside, and split at its field's `:`.
struct FilterTerm: Equatable {
    var range: Range<Int>
    var negated: Bool
    var field: LibraryQuery.Field?
    var value: String

    init?(_ text: String, cursor: Int) {
        let characters = Array(text)
        let end = min(max(cursor, 0), characters.count)
        var start = 0
        var quoted = false
        for (index, character) in characters[..<end].enumerated() {
            if character == "\"" {
                quoted.toggle()
            } else if !quoted, character.isWhitespace || character == "(" || character == ")" {
                start = index + 1
            }
        }
        var term = String(characters[start ..< end])
        guard !term.isEmpty else { return nil }
        negated = term.hasPrefix("-")
        if negated {
            term.removeFirst()
        }
        range = start ..< end
        if let colon = term.firstIndex(where: { ":=".contains($0) }),
           let field = LibraryQuery.Field(name: String(term[..<colon])),
           QueryCompletion.fields.contains(field) {
            self.field = field
            value = String(term[term.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        } else if term.contains(where: { ":=<>!".contains($0) }) {
            return nil
        } else {
            field = nil
            value = term
        }
        guard !value.isEmpty else { return nil }
    }

    /// Fields whose names start with `typed`, as completions that type the field and its `:`.
    static func fields(startingWith typed: String) -> [FilterCompletion] {
        let typed = typed.lowercased()
        let names = LibraryQuery.Field.allCases.map(\.rawValue) + LibraryQuery.Field.aliases.keys.sorted()
        return names.filter { $0.hasPrefix(typed) && $0 != typed }.prefix(3).map { name in
            FilterCompletion(title: name + ":", kind: "Field", text: name + ":")
        }
    }

    /// `text` with the term at `range` replaced by `completion`, and where the cursor goes.
    static func inserting(_ completion: FilterCompletion, in text: String, at range: Range<Int>) -> (String, Int) {
        var characters = Array(text)
        let range = min(range.lowerBound, characters.count) ..< min(range.upperBound, characters.count)
        characters.replaceSubrange(range, with: Array(completion.text))
        return (String(characters), range.lowerBound + completion.text.count)
    }
}
