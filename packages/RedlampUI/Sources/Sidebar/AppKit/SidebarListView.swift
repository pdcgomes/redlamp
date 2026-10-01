import AppKit
import RedlampDesign
import RedlampDocument
import RedlampRecipes
import SwiftUI

/// Recipes, Snapshots and History in AppKit, on the same control as SwiftUI's sidebar
/// `List`: a source-list outline view, with rows drawn like the SwiftUI rows.
///
/// It reloads only when recipes, snapshots or history change (once per finished edit),
/// never while a slider moves. The recipe search field sits above the list so typing
/// never loses focus to a reload.
final class SidebarListView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    private let model: EditorModel
    private let scrollView = OverlayScrollView()
    private let outline = SidebarOutlineView()
    private let searchField = NSSearchField()
    private var tracker: Tracker?
    private var sections: [SidebarNode] = []
    private var expandedGroups: Set<String> = ["Favorites", "My Recipes", "Essentials"]
    private var query = ""

    static let searchHeight: CGFloat = 30

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .none
        outline.floatsGroupRows = false
        // The system's sidebar metrics (row height and font follow the sidebar size setting),
        // as SwiftUI's sidebar List uses them.
        outline.rowSizeStyle = .default
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        scrollView.documentView = outline
        addSubview(scrollView)

        searchField.placeholderString = "Search recipes"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.toolTip = "Search recipes by name or tag. Lightroom words work too: preset, profile, LUT."
        searchField.setAccessibilityLabel("Search recipes")
        addSubview(searchField)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        searchField.frame = CGRect(x: 10, y: 4, width: max(bounds.width - 20, 0), height: Self.searchHeight - 8)
        scrollView.frame = CGRect(
            x: 0,
            y: Self.searchHeight,
            width: bounds.width,
            height: max(bounds.height - Self.searchHeight, 0),
        )
        outline.sizeLastColumnToFit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            _ = model.recipes.revision
            _ = model.recipeApplication?.recipe.id
            reload(
                snapshots: model.snapshots,
                history: model.history,
                current: model.historyIndex,
                hasPhoto: model.info != nil,
            )
        }
    }

    func controlTextDidChange(_: Notification) {
        query = searchField.stringValue
        reload(
            snapshots: model.snapshots,
            history: model.history,
            current: model.historyIndex,
            hasPhoto: model.info != nil,
        )
    }

    private func recipeSection(hasPhoto: Bool) -> SidebarNode {
        var children: [SidebarNode] = []
        if let amount = model.recipeAmount, let title = model.recipeAmountTitle {
            children.append(SidebarNode(.recipeAmount(title, amount)))
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            children += model.recipes.sections.map { section in
                SidebarNode(.group(section.name), children: section.recipes.map { SidebarNode(.recipe($0)) })
            }
        } else {
            let found = model.recipes.search(trimmed)
            children += found.isEmpty
                ? [SidebarNode(.placeholder("No matching recipes"))]
                : found.map { SidebarNode(.recipe($0)) }
        }
        return SidebarNode(.header("Recipes", button: .recipes(enabled: hasPhoto)), children: children)
    }

    private func reload(snapshots: [Snapshot], history: [HistoryStep], current: Int, hasPhoto: Bool) {
        let recipes = recipeSection(hasPhoto: hasPhoto)
        let snapshotRows = snapshots.isEmpty
            ? [SidebarNode(.placeholder("No snapshots"))]
            : snapshots.map { SidebarNode(.snapshot($0)) }
        let snapshotSection = SidebarNode(
            .header("Snapshots", button: .createSnapshot(enabled: hasPhoto)),
            children: snapshotRows,
        )
        let historyRows = history.enumerated().reversed().map { index, step in
            SidebarNode(.history(step, index: index, current: index == current, future: index > current))
        }
        let historySection = SidebarNode(
            .header("History", button: .clearHistory(enabled: history.count > 1)),
            children: historyRows,
        )
        sections = [recipes, snapshotSection, historySection]
        outline.reloadData()
        for section in sections {
            outline.expandItem(section)
            for group in section.children {
                if case let .group(name) = group.kind, expandedGroups.contains(name) {
                    outline.expandItem(group)
                }
            }
        }
    }

    // MARK: - Data source

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? sections.count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? sections[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        switch node.kind {
        case .header, .group: return true
        default: return false
        }
    }

    // MARK: - Delegate

    func outlineView(_: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let node = item as? SidebarNode, case .header = node.kind else { return false }
        return true
    }

    func outlineView(_: NSOutlineView, shouldSelectItem _: Any) -> Bool {
        false
    }

    func outlineView(_: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        return SidebarCellView(node: node, model: model)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? SidebarNode, case let .group(name) = node.kind {
            expandedGroups.insert(name)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? SidebarNode, case let .group(name) = node.kind {
            expandedGroups.remove(name)
        }
    }

    @objc private func rowClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? SidebarNode else { return }
        switch node.kind {
        case let .recipe(recipe):
            guard model.info != nil else { return }
            model.applyRecipe(recipe)
        case let .snapshot(snapshot):
            model.applySnapshot(snapshot)
        case let .history(_, index, _, _):
            model.goToHistory(index)
        case .group:
            if outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else {
                outline.expandItem(node)
            }
        default:
            break
        }
    }
}

/// A row of the sidebar lists: a section header, a recipe group or one of their rows.
final class SidebarNode: NSObject {
    enum Kind {
        case header(String, button: HeaderButton?)
        case group(String)
        case recipe(Recipe)
        /// The last applied recipe's Amount slider.
        case recipeAmount(String, Double)
        case placeholder(String)
        case snapshot(Snapshot)
        case history(HistoryStep, index: Int, current: Bool, future: Bool)
    }

    enum HeaderButton {
        case recipes(enabled: Bool)
        case createSnapshot(enabled: Bool)
        case clearHistory(enabled: Bool)
    }

    let kind: Kind
    let children: [SidebarNode]

    init(_ kind: Kind, children: [SidebarNode] = []) {
        self.kind = kind
        self.children = children
    }
}

/// The outline view, with the context menus for recipe and snapshot rows.
final class SidebarOutlineView: NSOutlineView {
    /// A table view only passes clicks to controls in its rows; the header buttons aren't.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        responder is SymbolImageView || responder is NSSlider
            || super.validateProposedFirstResponder(responder, for: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0,
              let view = view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView else { return nil }
        return view.contextMenu()
    }
}

@_spi(Harness) public enum SidebarListViews {
    @MainActor public static func make(model: EditorModel) -> NSView {
        SidebarListView(model: model)
    }
}
