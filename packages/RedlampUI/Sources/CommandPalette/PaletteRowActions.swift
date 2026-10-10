import AppKit
import Foundation
import RedlampEngineAPI
import RedlampLibrary

/// What a row can do besides ↵'s own (LIB-19), listed by ⌘↵: a folder shown in Library or revealed in Finder, a
/// photo opened in Develop, the selection added to a collection or given a keyword, a name left out of the filter,
/// a slider reset. The list starts with what ↵ does.
@_spi(Harness) public enum PaletteRowAction: String, Hashable, Sendable {
    /// What ↵ does on the row.
    case primary
    case showInLibrary, openInDevelop, revealInFinder
    case addSelectionToCollection, addKeywordToSelection
    /// Leaves the name or term out of the filter, or for a term already left out, filters by it.
    case filterOut, filterBy
    case resetSlider

    var verb: String {
        switch self {
        case .primary: "Run"
        case .showInLibrary, .openInDevelop, .revealInFinder: "Show"
        case .addSelectionToCollection, .addKeywordToSelection: "Add"
        case .filterOut, .filterBy: "Filter"
        case .resetSlider: "Reset"
        }
    }

    var symbol: String {
        switch self {
        case .primary: "return"
        case .showInLibrary: "square.grid.3x3"
        case .openInDevelop: "slider.horizontal.3"
        case .revealInFinder: "folder"
        case .addSelectionToCollection: "rectangle.stack.badge.plus"
        case .addKeywordToSelection: "tag"
        case .filterOut: "line.3.horizontal.decrease.circle"
        case .filterBy: "line.3.horizontal.decrease.circle.fill"
        case .resetSlider: "arrow.counterclockwise"
        }
    }
}

@_spi(Harness) public extension CommandPaletteModel {
    /// What `item` can do, ↵'s own first; a row that can do nothing more lists only that.
    func rowActions(for item: PaletteItem) -> [PaletteRowAction] {
        let selected = editor.selectedCount > 0
        let inLibrary = editor.module == .library
        switch item.kind {
        case .libraryName(.folder, _):
            return [.primary] + (inLibrary ? [] : [.showInLibrary]) + [.revealInFinder]
        case .photo:
            return [.primary, .openInDevelop] + (inLibrary ? [] : [.showInLibrary]) + [.revealInFinder]
        case .libraryName(.collection, _):
            return [.primary] + (selected ? [.addSelectionToCollection] : [])
        case .libraryName(.keyword, _):
            // The keywording panels add a keyword to the photos they show the selection of.
            let keywording = selected && !editor.libraryPanels.selection.ids.isEmpty
            return [.primary, .filterOut] + (keywording ? [.addKeywordToSelection] : [])
        case .libraryName, .photosNamed:
            return [.primary, .filterOut]
        case let .queryTerm(term):
            return [.primary, term.hasPrefix("-") ? .filterBy : .filterOut]
        case let .slider(parameter):
            return [.primary] + (editor.module == .develop && isLive(parameter) ? [.resetSlider] : [])
        default:
            return [.primary]
        }
    }

    /// The rows of the Actions page for the `subject` row.
    internal func rowActionItems() -> [PaletteItem] {
        guard let subject else { return [] }
        return rowActions(for: subject).map { action in
            PaletteItem(
                kind: .rowAction(action), title: title(of: action, on: subject),
                context: action == .primary ? "↵" : subject.title,
                symbol: action == .primary ? subject.symbol : action.symbol,
            )
        }
    }

    private func title(of action: PaletteRowAction, on subject: PaletteItem) -> String {
        let count = editor.selectedCount
        let photos = count == 1 ? "the Selected Photo" : "the \(count.formatted()) Selected Photos"
        return switch action {
        case .primary: "\(subject.kind.verb) “\(subject.title)”"
        case .showInLibrary: "Show in Library"
        case .openInDevelop: "Open in Develop"
        case .revealInFinder: "Reveal in Finder"
        case .addSelectionToCollection: "Add \(photos) to It"
        case .addKeywordToSelection: "Add to \(photos)"
        case .filterOut: "Leave Out of the Filter"
        case .filterBy: "Filter by It"
        case .resetSlider: "Reset to Its Default"
        }
    }

    /// ⌘↵: what else the highlighted row can do, as a page of its own; a row that can do nothing more beeps.
    internal func showRowActions() {
        guard let item = selectedItem, page != .actions, rowActions(for: item).count > 1 else {
            if let item = selectedItem {
                report(.unavailable(item.kind))
            }
            if !isSpecimen {
                NSSound.beep()
            }
            return
        }
        subject = item
        push(.actions)
    }

    /// Does `action` to the `subject` row.
    internal func perform(_ action: PaletteRowAction) {
        guard let subject else { return }
        if action == .primary {
            levels.removeLast()
            self.subject = nil
            refresh()
            activate(subject)
            return
        }
        clearPreview()
        recordingStep { perform(action, on: subject.kind) }
        report(.applied(.rowAction(action)))
        close(.applied)
    }

    private func perform(_ action: PaletteRowAction, on kind: PaletteItemKind) {
        switch (action, kind) {
        case let (.showInLibrary, .libraryName(.folder, path)):
            editor.open([URL(fileURLWithPath: path, isDirectory: true)])
            editor.showLibrary(.grid)
        case let (.showInLibrary, .photo(path)):
            editor.open([URL(fileURLWithPath: path)])
            editor.showLibrary(.grid)
        case let (.openInDevelop, .photo(path)):
            editor.open([URL(fileURLWithPath: path)])
            editor.showModule(.develop)
        case let (.revealInFinder, .libraryName(.folder, path)):
            editor.libraryViews.revealInFinder([URL(fileURLWithPath: path, isDirectory: true)])
        case let (.revealInFinder, .photo(path)):
            editor.libraryViews.revealInFinder([URL(fileURLWithPath: path)])
        case let (.addSelectionToCollection, .libraryName(.collection, value)):
            if let path = CollectionPath(value) {
                editor.librarySources.add(to: path)
            }
        case let (.addKeywordToSelection, .libraryName(.keyword, value)):
            if let keyword = KeywordPath(value) {
                editor.libraryPanels.add([keyword])
            }
        case let (.filterOut, .libraryName(field, value)):
            filterLibrary(narrowingBy: .not(.filter(LibraryQuery.Filter(field, .equal, [.text(value)]))))
        case let (.filterOut, .photosNamed(text)):
            filterLibrary(narrowingBy: .not(.filter(LibraryQuery.Filter(.name, .equal, [.text(text)]))))
        case let (.filterOut, .queryTerm(term)):
            filterLibrary(adding: "-" + term)
        case let (.filterBy, .queryTerm(term)):
            filterLibrary(adding: String(term.dropFirst()))
        case let (.resetSlider, .slider(parameter)):
            editor.resetSlider(parameter)
        default:
            break
        }
    }
}
