import AppKit
import RedlampDesign
import RedlampDocument
import RedlampRecipes

/// Recipes, Snapshots and History in AppKit: panels with the inspector's headers and dividers,
/// scrolling together under the Navigator as the inspector's panels do.
///
/// Each panel's list is an outline view as tall as its rows. It reloads only when what it shows
/// changes (once per finished edit), never while a slider moves, and the column keeps its scroll
/// position when it does. The recipe search field is a row of its own, so the recipes reload
/// as you type without taking its focus.
final class SidebarListView: PanelColumnScrollView, NSSearchFieldDelegate {
    private let model: EditorModel
    private let searchField: NSSearchField
    let recipes: SidebarOutlineView
    let snapshots: SidebarOutlineView
    let history: SidebarOutlineView
    private let panels: [SidebarSection: PanelSectionView]
    private let createSnapshot: SymbolImageView
    private let clearHistory: SymbolImageView
    private var tracker: Tracker?
    private var expandedGroups: Set<String> = ["Favorites", "My Recipes", "Essentials"]
    private var expandedSessions: Set<UUID> = []
    private var query = ""

    /// Lists pad their own rows, so a row's highlight can reach past its text.
    private static let listInsets = NSEdgeInsets(top: 0, left: 0, bottom: Metrics.panelBottomPadding, right: 0)

    init(model: EditorModel) {
        self.model = model
        let searchField = NSSearchField()
        let recipes = SidebarOutlineView(model: model)
        let snapshots = SidebarOutlineView(model: model)
        let history = SidebarOutlineView(model: model)
        let createSnapshot = Self.headerButton("plus", help: "Create Snapshot (⌘N)") { model.createSnapshot() }
        let clearHistory = Self.headerButton("xmark", help: "Clear History") { model.clearHistory() }
        let panels: [SidebarSection: PanelSectionView] = [
            .recipes: PanelSectionView(
                section: .recipes, model: model, accessory: Self.recipesButton(model: model), insets: Self.listInsets,
                rows: [SearchFieldRow(field: searchField), recipes],
            ),
            .snapshots: PanelSectionView(
                section: .snapshots, model: model, accessory: createSnapshot, insets: Self.listInsets,
                rows: [snapshots],
            ),
            .history: PanelSectionView(
                section: .history, model: model, accessory: clearHistory, insets: Self.listInsets, rows: [history],
            ),
        ]
        self.searchField = searchField
        self.recipes = recipes
        self.snapshots = snapshots
        self.history = history
        self.createSnapshot = createSnapshot
        self.clearHistory = clearHistory
        self.panels = panels
        super.init(views: [SidebarSection.recipes, .snapshots, .history].compactMap { panels[$0] })

        searchField.placeholderString = "Search recipes"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.toolTip = "Search recipes by name or tag. Lightroom words work too: preset, profile, LUT."
        searchField.setAccessibilityLabel("Search recipes")

        recipes.content = { [weak self] in self?.recipeRows() ?? [] }
        snapshots.content = { [model] in
            model.snapshots.isEmpty
                ? [SidebarNode(.placeholder("No snapshots"))]
                : model.snapshots.map { SidebarNode(.snapshot($0)) }
        }
        history.content = { [weak self] in self?.historyRows() ?? [] }
        for list in [recipes, history] {
            list.isExpanded = { [weak self] node in self?.isExpanded(node) ?? false }
            list.expansionChanged = { [weak self] node, expanded in self?.setExpanded(node, expanded) }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            createSnapshot.isEnabled = model.info != nil
            clearHistory.isEnabled = model.history.count > 1 || !model.earlierSessions.isEmpty
        }
    }

    func controlTextDidChange(_: Notification) {
        query = searchField.stringValue
        recipes.refresh()
    }

    // MARK: - Rows

    private func recipeRows() -> [SidebarNode] {
        _ = model.recipes.revision
        _ = model.recipeApplication?.recipe.id
        var rows: [SidebarNode] = []
        if let amount = model.recipeAmount, let title = model.recipeAmountTitle {
            rows.append(SidebarNode(.recipeAmount(title, amount)))
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            rows += model.recipes.sections.map { section in
                SidebarNode(.group(section.name), children: section.recipes.map { SidebarNode(.recipe($0)) })
            }
        } else {
            let found = model.recipes.search(trimmed)
            rows += found.isEmpty
                ? [SidebarNode(.placeholder("No matching recipes"))]
                : found.map { SidebarNode(.recipe($0)) }
        }
        return rows
    }

    private func historyRows() -> [SidebarNode] {
        let current = model.historyIndex
        let steps = model.history.enumerated().reversed().map { index, step in
            SidebarNode(.history(step, index: index, current: index == current, future: index > current))
        }
        let sessions = model.earlierSessions.map { session in
            SidebarNode(
                .session(session),
                children: session.steps.reversed().map { SidebarNode(.earlierStep($0, session: session)) },
            )
        }
        return steps + sessions
    }

    private func isExpanded(_ node: SidebarNode) -> Bool {
        switch node.kind {
        case let .group(name): expandedGroups.contains(name)
        case let .session(session): expandedSessions.contains(session.id)
        default: false
        }
    }

    private func setExpanded(_ node: SidebarNode, _ expanded: Bool) {
        switch node.kind {
        case let .group(name):
            if expanded {
                expandedGroups.insert(name)
            } else {
                expandedGroups.remove(name)
            }
        case let .session(session):
            if expanded {
                expandedSessions.insert(session.id)
            } else {
                expandedSessions.remove(session.id)
            }
        default:
            break
        }
    }

    // MARK: - Headers

    private static func headerButton(_ symbol: String, help: String, action: @escaping @MainActor () -> Void)
        -> SymbolImageView {
        let control = SymbolImageView(symbol, pointSize: 11, color: Palette.secondaryLabel.nsColor)
        control.toolTip = help
        control.setAccessibilityRole(.button)
        control.setAccessibilityLabel(help)
        control.onClick = action
        return control
    }

    /// Importing works without a photo; creating a recipe is disabled in the menu instead.
    private static func recipesButton(model: EditorModel) -> SymbolImageView {
        let control = headerButton("plus", help: "Create or Import a Recipe") {}
        control.onClick = { [weak control] in
            guard let control else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            let create = NSMenuItem(title: "Create Recipe from Current Edit…") {
                RecipeActions.createRecipe(model: model)
            }
            create.isEnabled = model.info != nil
            menu.addItem(create)
            menu.addItem(NSMenuItem(title: "Import Recipe, .cube or HaldCLUT…") {
                RecipeActions.importRecipes(model: model)
            })
            menu.popUp(positioning: nil, at: CGPoint(x: 0, y: control.bounds.height + 4), in: control)
        }
        return control
    }

    // MARK: - Harness

    func expandEarlierSessions() {
        for row in (0 ..< history.numberOfRows).reversed() {
            if let node = history.item(atRow: row) as? SidebarNode, case .session = node.kind {
                history.expandItem(node)
            }
        }
    }

    /// Scrolls the column so a panel's header is at the top.
    func reveal(_ title: String) {
        guard let section = SidebarSection.allCases.first(where: { $0.title == title }), let panel = panels[section]
        else { return }
        layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: panel.frame.origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }
}

/// The recipe search field, padded as a panel's rows are.
private final class SearchFieldRow: NSView {
    private let field: NSSearchField

    init(field: NSSearchField) {
        self.field = field
        super.init(frame: .zero)
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: field.intrinsicContentSize.height + 6)
    }

    override func layout() {
        super.layout()
        let height = field.intrinsicContentSize.height
        field.frame = CGRect(
            x: Metrics.panelPadding, y: 0, width: max(bounds.width - Metrics.panelPadding * 2, 0), height: height,
        )
    }
}

@_spi(Harness) public enum SidebarListViews {
    @MainActor public static func make(model: EditorModel) -> NSView {
        SidebarListView(model: model)
    }

    /// Scrolls a list made by `make` so the panel ("History") is at the top.
    @MainActor public static func reveal(_ section: String, in view: NSView) {
        (view as? SidebarListView)?.reveal(section)
    }

    @MainActor public static func expandEarlierSessions(in view: NSView) {
        (view as? SidebarListView)?.expandEarlierSessions()
    }
}
