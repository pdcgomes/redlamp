import AppKit
import RedlampDesign
import RedlampLibrary

/// The filter bar's Metadata section: columns side by side, each counting the photos of the filter by
/// one field (dates by year, month and day, cameras, lenses, ISO, focal lengths, keywords, labels,
/// folders and more), with All at the top. Choosing values in a column (⌘-click for several) narrows
/// the columns after it; the counts come once the grid shows the photos.
final class FilterColumnsView: NSView {
    private let model: EditorModel
    private var trackers: [Tracker] = []
    private var columns: [FilterColumnView] = []

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Metadata")
        setAccessibilityIdentifier("library.filter.metadata")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackers.forEach { $0.cancel() }
        trackers = []
        guard window != nil else { return }
        trackers = [Tracker { [weak self] in self?.update() }]
    }

    private func update() {
        guard let filters = model.libraryFilters else { return }
        let kinds = filters.filter.columns
        while columns.count < kinds.count {
            let column = FilterColumnView(model: model, index: columns.count)
            columns.append(column)
            addSubview(column)
        }
        while columns.count > kinds.count {
            columns.removeLast().removeFromSuperview()
        }
        let rules = filters.rules
        let folder = model.folder.map { LibraryService.path($0) }
        for (index, column) in columns.enumerated() {
            column.show(
                kinds[index], counts: filters.columns[index].flatMap { $0.column == kinds[index] ? $0 : nil },
                choice: FilterColumnRow.choice(in: rules, column: kinds[index]), folder: folder,
                canRemove: kinds.count > 1, canAdd: kinds.count < LibraryFilter.maxColumns,
            )
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !columns.isEmpty else { return }
        let width = (bounds.width - 1) / CGFloat(columns.count)
        for (index, column) in columns.enumerated() {
            column.frame = CGRect(x: CGFloat(index) * width + 1, y: 1, width: width - 1, height: bounds.height - 2)
        }
    }
}

/// One metadata column: its header, which chooses what it counts by, and its rows.
final class FilterColumnView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let model: EditorModel
    let index: Int
    private let header: FilterPopUp
    private let scroll = NSScrollView()
    let outline = NSOutlineView()
    private let all = FilterColumnRow(key: "\u{0}all", title: "All", count: 0, value: nil)
    private(set) var rows: [FilterColumnRow] = []
    private var kind: FacetColumn?
    private var counts: FacetColumnCounts?
    private var choice: LibraryQuery.Filter?
    private var expanded: Set<String> = []
    private var isSettingSelection = false

    init(model: EditorModel, index: Int) {
        self.model = model
        self.index = index
        header = FilterPopUp(identifier: "library.filter.column.\(index)", tip: "Column \(index + 1)")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
        header.onChoose = { [weak self] tag in self?.headerChosen(tag) }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 18
        outline.indentationPerLevel = 12
        outline.allowsMultipleSelection = true
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityIdentifier("library.filter.column.\(index).rows")
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(header)
        addSubview(scroll)
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
        header.frame = CGRect(x: 4, y: 2, width: bounds.width - 8, height: 20)
        scroll.frame = CGRect(x: 0, y: 24, width: bounds.width, height: max(bounds.height - 24, 0))
        outline.tableColumns.first?.width = scroll.contentSize.width
    }

    /// The column as it counts `kind` now, the rows `choice` takes lit.
    func show(
        _ kind: FacetColumn, counts: FacetColumnCounts?, choice: LibraryQuery.Filter?, folder: String?,
        canRemove: Bool, canAdd: Bool,
    ) {
        var items: [(title: String?, tag: Int)] = FacetColumn.allCases.enumerated().map { ($1.title, $0) }
        items.append((nil, 0))
        if canAdd {
            items.append(("Add Column", -1))
        }
        if canRemove {
            items.append(("Remove This Column", -2))
        }
        header.set(items, chosen: FacetColumn.allCases.firstIndex(of: kind))
        if kind != self.kind || counts != self.counts {
            if kind != self.kind {
                expanded = []
            }
            self.kind = kind
            self.counts = counts
            rows = counts.map { FilterColumnRow.rows($0, folder: folder) } ?? []
            outline.reloadData()
            for key in expanded {
                if let row = row(for: key) {
                    outline.expandItem(row)
                }
            }
        }
        self.choice = choice
        select()
    }

    /// Lights the rows the column's choice takes, or All.
    private func select() {
        guard let kind else { return }
        var lit = IndexSet()
        if choice == nil {
            lit.insert(0)
        } else {
            for row in 0 ..< outline.numberOfRows {
                if let item = outline.item(atRow: row) as? FilterColumnRow, item !== all,
                   item.isChosen(by: choice, in: kind) {
                    lit.insert(row)
                }
            }
        }
        guard lit != outline.selectedRowIndexes else { return }
        isSettingSelection = true
        outline.selectRowIndexes(lit, byExtendingSelection: false)
        isSettingSelection = false
    }

    private func row(for key: String, in rows: [FilterColumnRow]? = nil) -> FilterColumnRow? {
        for row in rows ?? self.rows {
            if row.key == key {
                return row
            }
            if let found = self.row(for: key, in: row.children) {
                return found
            }
        }
        return nil
    }

    private func headerChosen(_ tag: Int) {
        guard let filters = model.libraryFilters else { return }
        switch tag {
        case -1: filters.addColumn(after: index)
        case -2: filters.removeColumn(index)
        case FacetColumn.allCases.indices: filters.setColumn(index, to: FacetColumn.allCases[tag])
        default: break
        }
    }

    // MARK: - Rows

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let row = item as? FilterColumnRow else { return rows.isEmpty && counts == nil ? 0 : rows.count + 1 }
        return row.children.count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let row = item as? FilterColumnRow else { return index == 0 ? all : rows[index - 1] }
        return row.children[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FilterColumnRow)?.children.isEmpty == false
    }

    func outlineView(_ outline: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? FilterColumnRow else { return nil }
        let cell = outline.makeView(withIdentifier: FilterColumnCell.identifier, owner: nil) as? FilterColumnCell
            ?? FilterColumnCell()
        let count = row === all ? counts?.total ?? 0 : row.count
        cell.show(row.title, count: count, isUnknown: row.value == nil && row !== all)
        cell.setAccessibilityIdentifier("library.filter.column.\(index).\(row === all ? "all" : "value." + row.key)")
        return cell
    }

    func outlineView(_: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let row = item as? FilterColumnRow else { return false }
        return row === all || row.value != nil
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let row = notification.userInfo?["NSObject"] as? FilterColumnRow {
            expanded.insert(row.key)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let row = notification.userInfo?["NSObject"] as? FilterColumnRow {
            expanded.remove(row.key)
        }
    }

    /// A click or a key changed the rows lit: the column's choice follows, All taking the photos of
    /// every value.
    func outlineViewSelectionDidChange(_: Notification) {
        guard !isSettingSelection, let filters = model.libraryFilters else { return }
        let chosen = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FilterColumnRow }
        let allIsNew = chosen.contains { $0 === all } && !(choice == nil)
        let values = allIsNew ? [] : chosen.filter { $0 !== all }.compactMap(\.value)
        filters.choose(values, inColumn: index)
    }
}

/// A row's name and count.
final class FilterColumnCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("filter.column.cell")
    private let name = filterLabel("", secondary: false)
    private let number = filterLabel("")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        number.alignment = .right
        addSubview(name)
        addSubview(number)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ title: String, count: Int, isUnknown: Bool) {
        name.stringValue = title
        name.textColor = (isUnknown ? Palette.tertiaryLabel : Palette.label).nsColor
        number.stringValue = count.formatted()
        setAccessibilityLabel("\(title), \(count)")
    }

    /// Clicks go on to the column, which chooses the row.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        let numberWidth: CGFloat = 54
        name.frame = CGRect(
            x: 2,
            y: (bounds.height - 15) / 2,
            width: max(bounds.width - numberWidth - 6, 0),
            height: 15,
        )
        number.frame = CGRect(
            x: bounds.width - numberWidth - 4,
            y: (bounds.height - 15) / 2,
            width: numberWidth,
            height: 15,
        )
    }
}
