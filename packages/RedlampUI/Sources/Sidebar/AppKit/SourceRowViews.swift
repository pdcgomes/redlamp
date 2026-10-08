import AppKit
import RedlampDesign
import RedlampLibrary

/// A row of the Library or Collections section (LIB-23): a Library entry, a check of Library Health, or a
/// place in the collection list.
struct SourceRow: Equatable {
    let source: LibrarySource
    /// For a place in the collection list, what it is.
    var kind: CollectionKind?
    /// Its photos; nil for a set.
    var count: Int?
    /// It's the source shown.
    var isShown = false
    /// It's the target collection, which Add to Target Collection puts photos in.
    var isTarget = false
    /// A set with places inside it.
    var hasChildren = false

    var title: String {
        source.title
    }

    /// The row's identifier, for VoiceOver and the regression suite: `sources.marked`, `collections.Clients/Acme`.
    var identifier: String {
        Self.identifier(of: source)
    }

    static func identifier(of source: LibrarySource) -> String {
        switch source {
        case let .collection(path): "collections." + path.text
        case .allPhotographs: "sources.all-photographs"
        case .previousImport: "sources.previous-import"
        case .marked: "sources.marked"
        case .rejected: "sources.rejected"
        case let .health(kind): "sources.health." + kind.rawValue
        case .unreadable: "sources.unreadable"
        case .keptAnyway: "sources.kept-anyway"
        }
    }
}

/// What the Library and Collections sections say when they have nothing to list.
@_spi(Harness) public enum LibrarySourcesText {
    public static let off = "The library is off, so Folders lists folders itself"
    public static let opening = "Opening the library…"
    public static let empty = "Photos show here once the library has indexed a folder"
    public static let noCollections = "Collections you make show here: + in this panel's header makes one"
    public static let targetHelp = "The target collection (+): Photo › Add to Target Collection puts photos in it"
}

extension SidebarCellView {
    /// A source's icon, name and count; the target collection's name ends with +, as in Lightroom Classic.
    static func sourceDecoration(_ row: SourceRow) -> FolderDecoration {
        let symbol = switch row.kind {
        case .set: "square.stack.3d.up"
        case .smart: "gearshape"
        case .collection: "rectangle.stack"
        case nil: row.source.symbol
        }
        var help = row.source.help
        if row.isTarget {
            help += "\n" + LibrarySourcesText.targetHelp
        }
        let count = row.count.map { ", " + photos($0) } ?? ""
        return FolderDecoration(
            name: row.title + (row.isTarget ? " +" : ""),
            nameColor: row.isShown ? Palette.labelHover : Palette.label,
            help: help,
            accessibilityLabel: row.title + count + (row.isTarget ? ", target collection" : "")
                + (row.isShown ? ", shown" : ""),
            symbol: symbol,
            color: Palette.secondaryLabel,
            count: row.count?.formatted(),
        )
    }

    /// Library Health's group: its checks are inside it.
    static let healthDecoration = FolderDecoration(
        name: "Library Health", nameColor: Palette.secondaryLabel,
        help: "Checks that each list the photos needing a decision; each shows only while it finds something",
        accessibilityLabel: "Library Health", symbol: "stethoscope", color: Palette.secondaryLabel,
    )

    /// A source's menu: choosing it as the target, and for the collection list's places, renaming, moving and
    /// deleting them, and making places inside a set.
    static func sourceMenu(_ row: SourceRow, model: EditorModel) -> NSMenu {
        let sources = model.librarySources
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show") { sources.show(row.source) })
        if row.source == .marked || row.kind == .collection {
            let target: CollectionPath? = if case let .collection(path) = row.source {
                path
            } else {
                nil
            }
            let item = NSMenuItem(title: "Set as Target Collection") { sources.setTarget(target) }
            item.state = row.isTarget ? .on : .off
            menu.addItem(item)
        }
        guard case let .collection(path) = row.source, let kind = row.kind else { return menu }
        menu.addItem(.separator())
        if kind == .set {
            menu.addItem(NSMenuItem(title: "New Collection Inside…") {
                CollectionSheets.create(.collection, inside: path, model: model)
            })
            menu.addItem(NSMenuItem(title: "New Collection Set Inside…") {
                CollectionSheets.create(.set, inside: path, model: model)
            })
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: "Rename…") { CollectionSheets.rename(path, model: model) })
        let move = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
        let places = NSMenu()
        for set in [nil] + sources.sets.map(Optional.some) where set != path.parent && !(set?.isWithin(path) ?? false) {
            places.addItem(NSMenuItem(title: set?.displayName ?? "Top Level") { sources.move(path, into: set) })
        }
        move.submenu = places
        move.isEnabled = !places.items.isEmpty
        menu.addItem(move)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Delete") { sources.delete(path) })
        return menu
    }

    /// Library Health's menu: the rule for raw and JPEG pairs.
    static func healthMenu(model: EditorModel) -> NSMenu {
        let sources = model.librarySources
        let menu = NSMenu()
        let title = NSMenuItem(title: "Raw and JPEG Pairs", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for (rule, name) in [
            (PairRule.keepBoth, "Keep Both"),
            (.keepRaw, "Keep the Raw"),
            (.keepJPEG, "Keep the JPEG"),
        ] {
            let item = NSMenuItem(title: name) { sources.setPairRule(rule) }
            item.state = sources.pairRule == rule ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }
        return menu
    }
}
