import AppKit
import RedlampDesign
import RedlampDocument

/// The Folders panel's tree: the roots, and the subfolders of each folder that's open.
///
/// Its rows come straight from the library's tree as the outline view asks for them, one node per
/// folder kept for the list's life, so a folder with thousands of subfolders costs a screenful:
/// only rows on screen get views, and only folders on screen are listed. A listing that changes a
/// folder's subfolders reloads that row and its children, and a count that changes (from a listing,
/// or the library's counts) that row alone; only the roots changing reloads the list.
///
/// Recently Trashed follows the folders while the library is open (LIB-26), with its count, and shown
/// empty, a line under it saying what it holds.
final class FolderOutlineView: SidebarOutlineView {
    private var rootNodes: [SidebarNode] = []
    private var nodes: [String: SidebarNode] = [:]
    private var placeholder = SidebarNode(.placeholder("Add a folder of photos with +"))
    private let trashNode = SidebarNode(.recentlyTrashed(TrashRow(count: nil, isOpen: false)))
    private let emptyTrashNode = SidebarNode(.placeholder(RecentlyTrashedText.empty))
    /// Recently Trashed's rows after the folders: none with the library closed.
    private var trashRows: [SidebarNode] = []
    private var structure: Tracker?
    private var openTracker: Tracker?
    private var trashTracker: Tracker?
    private var treeObservation: LibraryObservation?
    private var countsObservation: LibraryObservation?
    private var openPath: String?

    /// The rows at the top: the roots, or a line saying how to add one, then Recently Trashed's.
    private var topNodes: [SidebarNode] {
        (rootNodes.isEmpty ? [placeholder] : rootNodes) + trashRows
    }

    private var library: FolderLibrary {
        model.library
    }

    override init(model: EditorModel) {
        super.init(model: model)
        expansionChanged = { [weak self] node, expanded in
            guard let self, !isReloading, case let .folder(row) = node.kind else { return }
            library.setExpanded(row.url, expanded)
        }
    }

    override func track() {
        structure = Tracker { [weak self] in
            guard let self else { return }
            let roots = library.roots
            let missing = library.missing
            // Which folders can be opened depends on Show Photos in Subfolders.
            _ = library.includesSubfolders
            showRoots(roots, missing: missing)
        }
        openTracker = Tracker { [weak self] in
            guard let self else { return }
            setOpen(library.openFolder)
        }
        trashTracker = Tracker { [weak self] in
            guard let self else { return }
            showTrash(
                TrashRow(count: library.trashedCount, isOpen: library.showsRecentlyTrashed),
                available: library.canShowRecentlyTrashed,
            )
        }
        treeObservation = library.observeTree { [weak self] paths in self?.treeChanged(paths) }
        countsObservation = library.observeCounts { [weak self] paths in self?.countsChanged(paths) }
    }

    override func stopTracking() {
        structure?.cancel()
        openTracker?.cancel()
        trashTracker?.cancel()
        structure = nil
        openTracker = nil
        trashTracker = nil
        treeObservation = nil
        countsObservation = nil
    }

    // MARK: - Rows

    private func row(for url: URL, root: WorkingFolder, missing: Bool) -> FolderRow {
        let listed = missing ? nil : library.node(for: url)
        let path = url.standardizedFileURL.path
        let hasSubfolders = !(listed?.subfolders.isEmpty ?? true)
        let count = missing ? nil : library.photoCount(of: url)
        let selectable = !missing
            && (count.map { $0 > 0 } ?? listed.map { _ in library.includesSubfolders && hasSubfolders } ?? true)
        return FolderRow(
            url: url, name: path == root.path ? root.name : url.lastPathComponent, root: root, count: count,
            hasSubfolders: hasSubfolders, isMissing: missing, isOpen: path == openPath, isSelectable: selectable,
            includesSubfolders: library.includesSubfolders,
        )
    }

    /// The folder's node, kept across reloads so the outline view keeps its place and expansion.
    private func node(for url: URL, root: WorkingFolder, missing: Bool = false) -> SidebarNode {
        let path = url.standardizedFileURL.path
        let row = row(for: url, root: root, missing: missing)
        if let node = nodes[path] {
            node.kind = .folder(row)
            return node
        }
        let node = SidebarNode(.folder(row))
        nodes[path] = node
        return node
    }

    private func showRoots(_ roots: [WorkingFolder], missing: Set<UUID>) {
        rootNodes = roots.map { node(for: $0.url, root: $0, missing: missing.contains($0.id)) }
        reloadTop()
    }

    private func reloadTop() {
        isReloading = true
        reloadData()
        expandRemembered(rootNodes)
        isReloading = false
        invalidateColumnLayout()
    }

    /// Recently Trashed's row as `row` has it, and the line under it while it's shown empty; no row while
    /// the library isn't open. Only a row coming or going reloads the list.
    private func showTrash(_ row: TrashRow, available: Bool) {
        trashNode.kind = .recentlyTrashed(row)
        let rows = !available ? [] : row.isOpen && row.count == 0 ? [trashNode, emptyTrashNode] : [trashNode]
        guard rows.map(ObjectIdentifier.init) == trashRows.map(ObjectIdentifier.init) else {
            trashRows = rows
            return reloadTop()
        }
        let index = self.row(forItem: trashNode)
        if index >= 0, let cell = view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarCellView {
            cell.refreshTrash(row)
        }
        refreshHighlights()
    }

    /// Opens the rows that were open, as their subfolders become known.
    private func expandRemembered(_ items: [SidebarNode]) {
        for item in items {
            guard case let .folder(row) = item.kind, row.hasSubfolders, library.isExpanded(row.url) else { continue }
            if !isItemExpanded(item) {
                expandItem(item)
            }
            expandRemembered(children(of: item))
        }
    }

    private func children(of item: SidebarNode) -> [SidebarNode] {
        (0 ..< outlineView(self, numberOfChildrenOfItem: item)).compactMap {
            outlineView(self, child: $0, ofItem: item) as? SidebarNode
        }
    }

    /// Folders listed again: their rows (and, when open, their subfolders) reload, nothing else.
    private func treeChanged(_ paths: Set<String>) {
        isReloading = true
        for path in paths {
            guard let item = nodes[path], case let .folder(old) = item.kind, row(forItem: item) >= 0 else { continue }
            let updated = row(for: old.url, root: old.root, missing: old.isMissing)
            item.kind = .folder(updated)
            if isItemExpanded(item) {
                reloadItem(item, reloadChildren: true)
                expandRemembered(children(of: item))
            } else {
                reloadItem(item)
                expandRemembered([item])
            }
        }
        refreshHighlights()
        isReloading = false
        invalidateColumnLayout()
    }

    /// The library counted folders again: the rows on screen whose counts changed show them in place,
    /// without being made again; the others show them when they're next made.
    private func countsChanged(_ paths: Set<String>) {
        let changed = paths.count <= nodes.count ? paths.compactMap { nodes[$0] }
            : nodes.compactMap { paths.contains($0.key) ? $0.value : nil }
        for item in changed {
            guard case let .folder(old) = item.kind else { continue }
            let updated = row(for: old.url, root: old.root, missing: old.isMissing)
            guard updated != old else { continue }
            item.kind = .folder(updated)
            let index = row(forItem: item)
            if index >= 0, let cell = view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarCellView {
                cell.refreshFolder(updated)
            }
        }
    }

    private func setOpen(_ folder: URL?) {
        let previous = openPath
        openPath = folder?.standardizedFileURL.path
        for path in [previous, openPath].compactMap(\.self) {
            guard let item = nodes[path], case let .folder(row) = item.kind else { continue }
            item.kind = .folder(self.row(for: row.url, root: row.root, missing: row.isMissing))
            if self.row(forItem: item) >= 0 {
                reloadItem(item)
            }
        }
        refreshHighlights()
    }

    // MARK: - Data source

    override func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? SidebarNode else { return topNodes.count }
        guard case let .folder(row) = item.kind, !row.isMissing else { return 0 }
        return library.node(for: row.url)?.subfolders.count ?? 0
    }

    override func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? SidebarNode else { return topNodes[index] }
        guard case let .folder(row) = item.kind, let subfolders = library.node(for: row.url)?.subfolders,
              subfolders.indices.contains(index) else { return placeholder }
        return node(for: subfolders[index], root: row.root)
    }

    override func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? SidebarNode, case let .folder(row) = item.kind else { return false }
        return row.hasSubfolders
    }
}
