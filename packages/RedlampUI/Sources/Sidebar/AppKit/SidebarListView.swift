import AppKit
import RedlampDesign
import RedlampDocument
import SwiftUI

/// Presets, Snapshots and History in AppKit, on the same control as SwiftUI's sidebar
/// `List`: a source-list outline view, with rows drawn like the SwiftUI rows.
///
/// It reloads only when presets, snapshots or history change (once per finished edit),
/// never while a slider moves.
final class SidebarListView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let model: EditorModel
    private let scrollView = NSScrollView()
    private let outline = SidebarOutlineView()
    private var tracker: Tracker?
    private var sections: [SidebarNode] = []
    private var expandedGroups: Set<String> = ["Essentials"]

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
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        outline.sizeLastColumnToFit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            reload(
                snapshots: model.snapshots,
                history: model.history,
                current: model.historyIndex,
                hasPhoto: model.info != nil,
            )
        }
    }

    private func reload(snapshots: [Snapshot], history: [HistoryStep], current: Int, hasPhoto: Bool) {
        let presets = SidebarNode(.header("Presets", button: nil), children: BuiltInPresets.groups.map { group in
            SidebarNode(.group(group.name), children: group.presets.map { SidebarNode(.preset($0)) })
        })
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
        sections = [presets, snapshotSection, historySection]
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
        case let .preset(preset):
            model.applyPreset(preset)
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

/// A row of the sidebar lists: a section header, a preset group or one of their rows.
final class SidebarNode: NSObject {
    enum Kind {
        case header(String, button: HeaderButton?)
        case group(String)
        case preset(Preset)
        case placeholder(String)
        case snapshot(Snapshot)
        case history(HistoryStep, index: Int, current: Bool, future: Bool)
    }

    enum HeaderButton {
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

/// The outline view, with the context menu for snapshot rows.
final class SidebarOutlineView: NSOutlineView {
    /// A table view only passes clicks to controls in its rows; the header buttons aren't.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        responder is SymbolImageView || super.validateProposedFirstResponder(responder, for: event)
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
