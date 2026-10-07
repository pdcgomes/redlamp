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
/// so typing never waits for them.
extension CommandPaletteModel {
    /// The fields whose names the palette lists, ties going to the first.
    static let libraryFields: [LibraryQuery.Field] = [
        .folder, .collection, .keyword, .camera, .lens, .city, .country, .state, .sublocation,
    ]
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
    /// completion ranks them, and the photos whose names hold it.
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
        libraryLookup = Task { [weak self] in
            async let names = engine.completions(text, fields: Self.libraryFields, limit: Self.libraryNameLimit)
            async let photos = try? engine.photos(named: text, limit: Self.libraryPhotoLimit)
            let found = await names
            let named = await photos
            guard !Task.isCancelled, let self, lookedUp == text else { return }
            library = PaletteLibraryRows(text: text, items: PaletteCatalog.libraryItems(names: found, photos: named))
            showSections()
        }
    }

    /// Makes `filter` the source's filter on its field, as the bar's columns do, with the bar's text
    /// showing it.
    func filterLibrary(by filter: LibraryQuery.Filter) {
        guard let filters = editor.libraryFilters else { return }
        filters.edit { $0.replacingFilters(on: filter.field, with: filter) }
        if !filters.filter.sections.contains(.text) {
            filters.show(.text, adding: true)
        }
        filters.setBarShown(true)
    }
}
