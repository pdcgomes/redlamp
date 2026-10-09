import Foundation
import RedlampLibrary

/// The library's rows the search found (LIB-19), and whether it's still looking.
@_spi(Harness) public struct PaletteLibraryRows: Sendable {
    /// The text they were found for.
    public var text = ""
    public var items: [PaletteItem] = []
    public var isSearching = false
}

/// The library's names and photos beside the palette's own rows (LIB-19): looked up off the main
/// thread as the search is typed, the latest text winning, and listed under the commands once found,
/// so typing never waits for them. The search is also a term of the query language, completed as the
/// filter bar's text completes one: fields by name, and the values of the fields completion has values
/// for (`QueryCompletion.fields`), traits and orientations with the photos of the bar's source they find.
extension CommandPaletteModel {
    /// The fields whose names the palette lists, ties going to the first; then those whose values it lists as terms.
    static let libraryFields: [LibraryQuery.Field] = [
        .folder, .collection, .keyword, .camera, .lens, .city, .country, .state, .sublocation,
    ] + PaletteCatalog.termFields
    static let libraryNameLimit = 8
    static let libraryPhotoLimit = 5

    /// The catalogue's sections, then at the top level the library's.
    func showSections() {
        var shown = catalogSections
        if case let .list(nil, query, _) = level, scope == .all,
           !query.trimmingCharacters(in: .whitespaces).isEmpty, !library.items.isEmpty {
            shown.append(PaletteSection(title: "Library", items: library.items))
        }
        sections = shown
        rows = shown.flatMap(\.items)
        if case let .list(page, query, selection) = level, !rows.isEmpty, selection >= rows.count {
            replaceTop(.list(page: page, query: query, selection: rows.count - 1))
        }
    }

    /// Asks the library about the top level's text, once for each text: its names, ranked as
    /// completion ranks them, and the photos whose names hold it; or, for a term on a field (`is:dam`,
    /// `-kw:bir`), that field's values.
    func lookUpLibrary(page: PalettePage?, query: String) {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard page == nil, scope == .all, !text.isEmpty, let engine = editor.library.service?.engine else {
            libraryLookup?.cancel()
            libraryLookup = nil
            lookedUp = nil
            if !library.items.isEmpty || library.isSearching {
                library = PaletteLibraryRows()
            }
            return
        }
        guard text != lookedUp else { return }
        libraryLookup?.cancel()
        lookedUp = text
        library.isSearching = true
        let term = PaletteTerm(text)
        let (photos, moments) = editor.libraryFilters?.completionScope ?? (.allPhotographs, MomentSetting())
        libraryLookup = Task { [weak self] in
            let items: [PaletteItem]
            if let term, term.field != nil || term.negated {
                items = await Self.terms(term, engine: engine, in: photos, moments: moments)
            } else {
                let fields = term.map { PaletteTerm.fields(startingWith: $0.value) } ?? []
                items = await Self.names(text, fields: fields, engine: engine, in: photos, moments: moments)
            }
            guard !Task.isCancelled, let self, lookedUp == text else { return }
            library = PaletteLibraryRows(text: text, items: items)
            showSections()
        }
    }

    /// The values of `term`'s field, or of every field completion has values for, as terms with its `-`: those it
    /// starts, or with nothing typed after the field, every trait, orientation or colour label.
    private static func terms(
        _ term: PaletteTerm, engine: QueryEngine, in photos: PhotoSource, moments: MomentSetting,
    ) async -> [PaletteItem] {
        let values = if term.value.isEmpty, let field = term.field {
            await engine.values(of: field, in: photos, moments: moments)
        } else {
            await engine.completions(
                term.value, fields: term.field.map { [$0] } ?? QueryCompletion.fields, limit: libraryNameLimit,
                in: photos, moments: moments,
            )
        }
        return values.map { PaletteCatalog.termItem($0, negated: term.negated) }
    }

    /// The fields named `fields`, then the library's names `text` finds, ranked as completion ranks them, and the
    /// photos whose names hold it.
    private static func names(
        _ text: String, fields: [String], engine: QueryEngine, in photos: PhotoSource, moments: MomentSetting,
    ) async -> [PaletteItem] {
        async let names = engine.completions(
            text, fields: libraryFields, limit: libraryNameLimit, in: photos, moments: moments,
        )
        async let named = try? engine.photos(named: text, limit: libraryPhotoLimit)
        return await fields.map(PaletteCatalog.fieldItem) + PaletteCatalog.libraryItems(names: names, photos: named)
    }

    /// Makes `filter` the source's filter on its field, as the bar's columns do, with the bar's text
    /// showing it.
    func filterLibrary(by filter: LibraryQuery.Filter) {
        guard let filters = editor.libraryFilters else { return }
        filters.edit { $0.replacingFilters(on: filter.field, with: filter) }
        showFilterText(filters)
    }

    /// Makes `term`, as the language writes it, one of the source's filter's terms (`LibraryFilters.narrow`), with
    /// the bar's text showing it.
    func filterLibrary(adding term: String) {
        guard let filters = editor.libraryFilters, let query = try? LibraryQuery(parsing: term) else { return }
        filters.narrow(by: query)
        showFilterText(filters)
    }

    private func showFilterText(_ filters: LibraryFilters) {
        if !filters.filter.sections.contains(.text) {
            filters.show(.text, adding: true)
        }
        filters.setBarShown(true)
    }
}

/// The palette's search read as a term of the query language (LIB-19), as the filter bar's completion reads the
/// term it completes (`FilterTerm`): a `-` before it aside, a field completion has values for and its value
/// (`is:dam`), or text for every such field. Nil for a comparison, or a field completion has no values for.
struct PaletteTerm: Equatable {
    var negated: Bool
    var field: LibraryQuery.Field?
    var value: String

    init?(_ text: String) {
        var term = text.trimmingCharacters(in: .whitespaces)
        negated = term.count > 1 && term.hasPrefix("-")
        if negated {
            term.removeFirst()
        }
        if let colon = term.firstIndex(where: { ":=".contains($0) }) {
            guard let field = LibraryQuery.Field(name: String(term[..<colon])), QueryCompletion.fields.contains(field)
            else { return nil }
            self.field = field
            value = String(term[term.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        } else {
            guard !term.isEmpty, !term.contains(where: { "<>!".contains($0) }) else { return nil }
            field = nil
            value = term
        }
    }

    /// The fields whose values the palette completes, by name or alias, that start with `typed` and complete it, each
    /// with its `:`: at most three, as the bar offers fields.
    static func fields(startingWith typed: String) -> [String] {
        let typed = typed.lowercased()
        let names = LibraryQuery.Field.allCases.map(\.rawValue) + LibraryQuery.Field.aliases.keys.sorted()
        return names.filter { name in
            name.hasPrefix(typed) && name != typed
                && LibraryQuery.Field(name: name).map(QueryCompletion.fields.contains) == true
        }.prefix(3).map { $0 + ":" }
    }
}
