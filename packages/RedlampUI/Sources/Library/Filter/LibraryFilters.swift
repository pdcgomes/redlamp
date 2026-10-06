import Foundation
import Observation
import RedlampLibrary

/// The Library filter bar (LIB-18), as Lightroom Classic's: Text, Attribute and Metadata over one
/// query in the library's language, the sort, saved filters, and a lock that keeps one filter across
/// sources. Each source keeps its own filter and sort, for the 25 latest sources and across launches,
/// so a folder's filter is there again when it's shown again.
///
/// Typing never waits on the engine: the text is read as it's typed and handed to the library's list
/// of the source, which works out the photos off the main thread, the latest filter winning
/// (`LibraryFolderList`). The metadata columns are counted once the list is shown, each over the
/// photos of the filter but its own choice and those of the columns after it, so choosing in one
/// narrows the next.
@MainActor
@Observable
public final class LibraryFilters {
    /// The bar is shown above the grid and the loupe (`\`).
    public internal(set) var isBarShown = false
    /// The source the bar shows and edits, by `key(_:includingSubfolders:)`.
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
    /// Counts the lists the library handed over, and the filter of the last, for the harness.
    @ObservationIgnored @_spi(Harness) public private(set) var listings = 0
    @ObservationIgnored @_spi(Harness) public private(set) var lastListed: LibraryListFilterSummary?

    @ObservationIgnored weak var service: LibraryService?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let presetsURL: URL?
    @ObservationIgnored private var sources: [SourceFilter] = []
    @ObservationIgnored private var folder: (url: URL, subfolders: Bool)?
    /// The query the photos are filtered by while the text has an error.
    @ObservationIgnored private var applied: LibraryQuery?
    @ObservationIgnored private var counting: Task<Void, Never>?
    @ObservationIgnored private var completing: Task<Void, Never>?
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
        let key = folder.map { Self.key($0, includingSubfolders: includingSubfolders) }
        guard key != source else { return }
        self.folder = folder.map { ($0, includingSubfolders) }
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
        remember()
    }

    /// What the library's list of a source is filtered and sorted by.
    func request(for folder: URL, includingSubfolders: Bool) -> LibraryListFilter {
        let key = Self.key(folder, includingSubfolders: includingSubfolders)
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
        remember()
        apply()
    }

    /// Hands the filter to the library's list of the source shown.
    private func apply() {
        guard let folder else { return }
        let request = request(for: folder.url, includingSubfolders: folder.subfolders)
        if service?.filter(folder.url, includingSubfolders: folder.subfolders, by: request) != true {
            countColumns()
        }
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
    func listed(_ ordered: LibraryFolderList.Ordered) {
        listings += 1
        lastListed = LibraryListFilterSummary(
            query: ordered.filter.query, sort: ordered.filter.sort, reversed: ordered.filter.reversed,
        )
        if listed?.shown != ordered.items.count || listed?.total != ordered.total {
            listed = (ordered.items.count, ordered.total)
        }
        countColumns()
    }

    /// Counts the metadata columns again, once what's under way is done: when the source's photos
    /// change, or the columns are shown.
    public func countColumns() {
        guard isBarShown, filter.sections.contains(.metadata), let folder, let engine = service?.engine else { return }
        guard counting == nil else {
            countAgain = true
            lastChange = .now
            return
        }
        let source = PhotoSource.folder(folder.url, includingSubfolders: folder.subfolders)
        let key = self.source
        lastChange = .now
        counting = Task { [weak self] in
            while let self, ContinuousClock.now - lastChange < Self.columnDelay {
                try? await Task.sleep(for: lastChange + Self.columnDelay - ContinuousClock.now)
            }
            guard let requests = self?.columnRequests() else { return }
            do {
                for try await counts in engine.columns(requests, in: source) {
                    guard let self, self.source == key else { break }
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
        completing = Task { [weak self] in
            let values = await engine.completions(term.value, field: term.field, limit: 8)
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

/// The filter of a list the library handed over, for the harness.
@_spi(Harness) public struct LibraryListFilterSummary: Sendable, Hashable {
    public let query: LibraryQuery?
    public let sort: QuerySort?
    /// The folder's own order, the other way round.
    public let reversed: Bool
}

/// A row of the text's completions: a field to type a value for, or a value of one.
public struct FilterCompletion: Sendable, Hashable {
    /// What the row shows: `Places › Portugal`, `Fujifilm X-T5`, `rating:`.
    public var title: String
    /// What it is: `Keyword`, `Camera`, `Field`.
    public var kind: String
    /// What replaces the term: a term of the language, then a space, or a field's name and `:`.
    public var text: String

    init(title: String, kind: String, text: String) {
        self.title = title
        self.kind = kind
        self.text = text
    }

    init(_ completion: QueryCompletion) {
        let title = switch completion.field {
        case .keyword: KeywordPath(completion.value)?.displayName ?? completion.value
        case .folder: URL(fileURLWithPath: completion.value).pathComponents.suffix(2).joined(separator: "/")
        case .label: completion.value.capitalized
        default: completion.value
        }
        let kind = switch completion.field {
        case .keyword: "Keyword"
        case .camera: "Camera"
        case .lens: "Lens"
        case .folder: "Folder"
        case .label: "Label"
        default: completion.field.rawValue
        }
        self.init(title: title, kind: kind, text: completion.term + " ")
    }

    func negated(_ negated: Bool) -> FilterCompletion {
        negated ? FilterCompletion(title: title, kind: kind, text: "-" + text) : self
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
