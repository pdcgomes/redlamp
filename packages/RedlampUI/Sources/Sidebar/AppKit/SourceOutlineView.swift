import AppKit
import RedlampDesign
import RedlampLibrary

/// A list of the left panel's sources (LIB-23): the Library section's, or the collection list. Its rows are made
/// again when they change (an entry offered or no longer, a collection made, renamed or deleted, the source shown);
/// a count that changes alone is shown in its row in place, so counting never makes rows again. While it's in the
/// window, the library is counted (`LibrarySources.follow`).
class SourceOutlineView: SidebarOutlineView {
    private var countsObservation: LibraryObservation?
    private var isFollowing = false
    /// The rows made last, by source, for counts to reach those not on screen.
    private var nodes: [LibrarySource: SidebarNode] = [:]

    var sources: LibrarySources {
        model.librarySources
    }

    override init(model: EditorModel) {
        super.init(model: model)
        content = { [weak self] in self?.madeRows() ?? [] }
    }

    override func track() {
        super.track()
        countsObservation = sources.observeCounts { [weak self] changed in self?.countsChanged(changed) }
        if !isFollowing {
            isFollowing = true
            sources.follow()
        }
    }

    override func stopTracking() {
        super.stopTracking()
        countsObservation = nil
        if isFollowing {
            isFollowing = false
            sources.stopFollowing()
        }
    }

    /// The section's rows, reading what they show from `sources`.
    func rows() -> [SidebarNode] {
        []
    }

    /// `source`'s row as `sources` has it now.
    final func row(_ source: LibrarySource, kind: CollectionKind? = nil, hasChildren: Bool = false) -> SourceRow {
        let isTarget = switch source {
        case .marked: sources.isCounted && sources.target == nil
        case let .collection(path): sources.target == path
        default: false
        }
        return SourceRow(
            source: source, kind: kind, count: sources.count(of: source), isShown: sources.shown == source,
            isTarget: isTarget, hasChildren: hasChildren,
        )
    }

    private func madeRows() -> [SidebarNode] {
        _ = sources.rows
        _ = sources.shown
        let made = rows()
        var nodes: [LibrarySource: SidebarNode] = [:]
        func index(_ node: SidebarNode) {
            if case let .source(row) = node.kind {
                nodes[row.source] = node
            }
            node.children.forEach(index)
        }
        made.forEach(index)
        self.nodes = nodes
        return made
    }

    /// The sources whose counts changed: their rows on screen show them in place, the others when they're next
    /// made.
    private func countsChanged(_ changed: Set<LibrarySource>) {
        for source in changed {
            guard let node = nodes[source], case let .source(old) = node.kind else { continue }
            var updated = old
            updated.count = sources.count(of: source)
            guard updated != old else { continue }
            node.kind = .source(updated)
            let index = row(forItem: node)
            if index >= 0, let cell = view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarCellView {
                cell.refreshSource(updated)
            }
        }
    }
}

/// The Library section's list: All Photographs, Previous Import, Marked and Rejected, each once it holds photos,
/// then Library Health's checks inside its group, each while it finds something.
final class LibraryOutlineView: SourceOutlineView {
    private var healthExpanded = true

    override init(model: EditorModel) {
        super.init(model: model)
        isExpanded = { [weak self] node in
            if case .libraryHealth = node.kind {
                return self?.healthExpanded ?? true
            }
            return false
        }
        expansionChanged = { [weak self] node, expanded in
            guard let self, !isReloading, case .libraryHealth = node.kind else { return }
            healthExpanded = expanded
        }
    }

    override func rows() -> [SidebarNode] {
        guard let service = model.library.service else { return [SidebarNode(.placeholder(LibrarySourcesText.off))] }
        guard service.isReady, sources.isCounted else {
            return [SidebarNode(.placeholder(
                service.state == .opening || !sources.isCounted ? LibrarySourcesText.opening : LibrarySourcesText.off,
            ))]
        }
        var nodes = sources.libraryEntries.map { SidebarNode(.source(row($0))) }
        let checks = sources.healthEntries
        if !checks.isEmpty {
            nodes.append(SidebarNode(.libraryHealth, children: checks.map { SidebarNode(.source(row($0))) }))
        }
        return nodes.isEmpty ? [SidebarNode(.placeholder(LibrarySourcesText.empty))] : nodes
    }
}

/// The Collections section's list: the collection list's sets, collections and smart collections, each level in
/// the Finder's order of names, sets open or closed as they were left, the target collection's name ending
/// with +. Photos dragged from the grid onto a collection go in it (`EditorModel+Drops`).
final class CollectionOutlineView: SourceOutlineView {
    override init(model: EditorModel) {
        super.init(model: model)
        isExpanded = { [weak self] node in
            guard let self, case let .source(row) = node.kind, case let .collection(path) = row.source else {
                return false
            }
            return sources.isOpen(path)
        }
        expansionChanged = { [weak self] node, expanded in
            guard let self, !isReloading, case let .source(row) = node.kind, case let .collection(path) = row.source
            else { return }
            sources.setOpen(path, expanded)
        }
        registerForDraggedTypes([LibraryDrags.photos])
    }

    override func photoDrop(onRow row: Int, _ photos: DraggedPhotos, operations: NSDragOperation) -> PhotoDrop? {
        guard let node = item(atRow: row) as? SidebarNode, case let .source(place) = node.kind,
              case let .collection(path) = place.source
        else { return nil }
        return sources.photoDrop(photos, onto: path, operations: operations)
    }

    override func rows() -> [SidebarNode] {
        guard model.library.service?.isReady == true, sources.isCounted else { return [] }
        func nodes(inside set: CollectionPath?) -> [SidebarNode] {
            sources.collections(inside: set).map { place in
                let children = place.kind == .set ? nodes(inside: place.path) : []
                let row = row(.collection(place.path), kind: place.kind, hasChildren: !children.isEmpty)
                return SidebarNode(.source(row), children: children)
            }
        }
        let top = nodes(inside: nil)
        return top.isEmpty ? [SidebarNode(.placeholder(LibrarySourcesText.noCollections))] : top
    }
}
