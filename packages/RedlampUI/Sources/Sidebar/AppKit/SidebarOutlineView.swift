import AppKit
import RedlampDesign
import RedlampDocument
import RedlampRecipes

/// A row of a sidebar list: a recipe group, a recipe or one of the other rows.
final class SidebarNode: NSObject {
    enum Kind {
        case group(String)
        case recipe(Recipe)
        /// The last applied recipe's Amount slider.
        case recipeAmount(String, Double)
        case placeholder(String)
        case snapshot(Snapshot)
        case history(HistoryStep, index: Int, current: Bool, future: Bool)
        /// An earlier session with the photo, its steps inside.
        case session(HistorySession)
        /// A step of an earlier session: choosing it brings its edit back as a new step.
        case earlierStep(HistoryStep, session: HistorySession)
    }

    let kind: Kind
    let children: [SidebarNode]

    init(_ kind: Kind, children: [SidebarNode] = []) {
        self.kind = kind
        self.children = children
    }
}

/// One of the sidebar's lists: an outline view as tall as its rows, with no scroll view of its
/// own, so the panels around it scroll together. Groups and earlier sessions expand in place.
final class SidebarOutlineView: NSOutlineView, HeightProviding, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// The rows, read while tracked: the list reloads when anything they read changes.
    var content: @MainActor () -> [SidebarNode] = { [] }
    /// Whether a group or session shows its rows when the list reloads.
    var isExpanded: @MainActor (SidebarNode) -> Bool = { _ in false }
    var expansionChanged: @MainActor (SidebarNode, Bool) -> Void = { _, _ in }

    private let model: EditorModel
    private var roots: [SidebarNode] = []
    private var tracker: Tracker?
    private var isReloading = false

    init(model: EditorModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: 250, height: 0))
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        addTableColumn(column)
        outlineTableColumn = column
        columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        headerView = nil
        style = .plain
        backgroundColor = .clear
        selectionHighlightStyle = .none
        intercellSpacing = .zero
        indentationPerLevel = SidebarCellView.Layout.indent
        rowHeight = SidebarCellView.Layout.rowHeight
        dataSource = self
        delegate = self
        target = self
        action = #selector(rowClicked)
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
            show(content())
        }
    }

    /// Shows the rows again, after something they read that isn't observed (a search) changed.
    func refresh() {
        show(content())
    }

    /// Reloading starts every row collapsed; the column is told the list's height once the
    /// rows that were open are open again, so it never shrinks (and scrolls) in between.
    private func show(_ nodes: [SidebarNode]) {
        roots = nodes
        isReloading = true
        reloadData()
        expand(roots)
        isReloading = false
        invalidateColumnLayout()
    }

    private func expand(_ nodes: [SidebarNode]) {
        for node in nodes where !node.children.isEmpty && isExpanded(node) {
            expandItem(node)
            expand(node.children)
        }
    }

    func height(forWidth _: CGFloat) -> CGFloat {
        numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : 0
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let column = tableColumns.first, column.width != newSize.width {
            column.width = newSize.width
        }
    }

    /// Rows start at the panel's padding, a level further in for each level down, with the
    /// first part of each for a group's chevron.
    override func frameOfCell(atColumn _: Int, row: Int) -> NSRect {
        let rowRect = rect(ofRow: row)
        let x = Metrics.panelPadding + CGFloat(level(forRow: row)) * indentationPerLevel
        return CGRect(
            x: x, y: rowRect.minY, width: max(rowRect.width - x - Metrics.panelPadding, 0), height: rowRect.height,
        )
    }

    override func frameOfOutlineCell(atRow _: Int) -> NSRect {
        .zero
    }

    /// A table view only passes clicks to controls in its rows: the Amount slider.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        responder is NSSlider || super.validateProposedFirstResponder(responder, for: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0,
              let view = view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView else { return nil }
        return view.contextMenu()
    }

    // MARK: - Data source

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarNode)?.children.isEmpty ?? true)
    }

    // MARK: - Delegate

    func outlineView(_: NSOutlineView, shouldSelectItem _: Any) -> Bool {
        false
    }

    func outlineView(_: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        return SidebarCellView(node: node, model: model, isExpanded: isItemExpanded(node))
    }

    func outlineView(_: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = SidebarRowView()
        if let node = item as? SidebarNode, case let .history(_, _, current, _) = node.kind {
            row.isCurrentStep = current
        }
        return row
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        expansionDidChange(notification, expanded: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        expansionDidChange(notification, expanded: false)
    }

    private func expansionDidChange(_ notification: Notification, expanded: Bool) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        expansionChanged(node, expanded)
        (view(atColumn: 0, row: row(forItem: node), makeIfNecessary: false) as? SidebarCellView)?.isExpanded = expanded
        if !isReloading {
            invalidateColumnLayout()
        }
    }

    @objc private func rowClicked() {
        guard let node = item(atRow: clickedRow) as? SidebarNode else { return }
        switch node.kind {
        case let .recipe(recipe):
            guard model.info != nil else { return }
            model.applyRecipe(recipe)
        case let .snapshot(snapshot):
            model.applySnapshot(snapshot)
        case let .history(_, index, _, _):
            model.goToHistory(index)
        case let .earlierStep(step, session):
            model.restoreHistory(step, from: session)
        case .group, .session:
            if isItemExpanded(node) {
                collapseItem(node)
            } else {
                expandItem(node)
            }
        default:
            break
        }
    }
}
