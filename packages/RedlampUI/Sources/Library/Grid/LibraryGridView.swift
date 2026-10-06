import AppKit
import RedlampDesign
import RedlampDocument

/// The Library module's grid (LIB-13's first grid; LIB-14 grows it): the current source's photos, from the
/// library's photo list or the disk's listing as the filmstrip has them, as thumbnails in an AppKit collection
/// view whose cells are reused as it scrolls. Thumbnails come from the filmstrip's loader, decoded off the main
/// thread, and are asked for as cells scroll into view.
///
/// - The selection is the filmstrip's (`EditorModel.selectedPhotos` and its active photo): click, ⌘-click and
///   ⇧-click do what they do there; the arrow keys move the active photo, ⇧ extending the selection from the
///   photo it started at; Home and End go to the ends, Page Up and Page Down a screen; Return, Space or a
///   double-click open the loupe.
/// - Hidden (Develop is shown) it does nothing: changes to the photos wait, and it reloads once shown.
final class LibraryGridView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSCollectionViewPrefetching {
    let collectionView = LibraryCollectionView()
    let scrollView = NSScrollView()
    let layout = LibraryGridLayout()
    private let model: EditorModel
    private var observation: LibraryObservation?
    private var tracker: Tracker?
    /// The selection as last followed. Cells are drawn from these, not from the model, which can be a turn
    /// ahead, so `follow` knows every cell it has to change.
    private var selected: URL?
    private var marked: Set<URL> = []
    private var prefetching: [URL: UInt64] = [:]
    /// The photos the collection view has: the library's count when it last reloaded or changed.
    private var shownCount = 0
    /// Photos came or went while the grid was hidden, or it hasn't loaded yet.
    private var isStale = true
    /// Rows whose badges changed while the grid was hidden.
    private var staleRows = IndexSet()
    /// Times every cell was reloaded: once the grid has been shown, a module switch reloads nothing.
    private(set) var reloads = 0

    init(model: EditorModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.register(LibraryGridItem.self, forItemWithIdentifier: LibraryGridItem.identifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.onKey = { [weak self] event in self?.handle(event) ?? false }
        collectionView.setAccessibilityLabel("Grid")
        collectionView.setAccessibilityIdentifier("library.grid")
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var isShown: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = nil
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        observation = model.library.observe { [weak self] diff in self?.apply(diff) }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            let (selection, photos) = (model.selection, model.selectedPhotos)
            guard isShown, !isStale else { return }
            follow(selection, marking: photos)
        }
        if isShown {
            show()
        }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if isShown {
            show()
        }
    }

    /// Shown: what changed while it was hidden, the thumbnails its cells lack, the selection, and the active
    /// photo scrolled into view.
    private func show() {
        if isStale {
            reload()
        } else if !staleRows.isEmpty {
            update(staleRows)
            staleRows = []
        }
        for path in collectionView.indexPathsForVisibleItems() where model.items.indices.contains(path.item) {
            guard let item = collectionView.item(at: path) as? LibraryGridItem, item.cell.image == nil else { continue }
            requestThumbnail(for: item, model.items[path.item])
        }
        follow(model.selection, marking: model.selectedPhotos, revealing: true)
    }

    private func reload() {
        isStale = false
        staleRows = []
        reloads += 1
        prefetching.values.forEach(model.thumbnailLoader.cancel)
        prefetching = [:]
        shownCount = model.items.count
        collectionView.reloadData()
        // A reload counts the photos at the next layout; a change before then would be counted twice.
        collectionView.layoutSubtreeIfNeeded()
    }

    // MARK: - Data source

    func collectionView(_: NSCollectionView, numberOfItemsInSection _: Int) -> Int {
        shownCount
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath,
    ) -> NSCollectionViewItem {
        let view = collectionView.makeItem(withIdentifier: LibraryGridItem.identifier, for: indexPath)
        guard let item = view as? LibraryGridItem, model.items.indices.contains(indexPath.item) else { return view }
        let photo = model.items[indexPath.item]
        item.cell.configure(photo, image: model.thumbnailLoader.cached(photo))
        item.cell.isSelected = photo.url == selected
        item.cell.isInSelection = marked.contains(photo.url)
        item.cell.onClick = { [weak self] modifiers in
            guard let self else { return }
            window?.makeFirstResponder(self.collectionView)
            model.click(photo.url, toggling: modifiers.contains(.command), extending: modifiers.contains(.shift))
        }
        item.cell.onOpen = { [weak self] in
            guard let self else { return }
            if model.selection != photo.url {
                model.click(photo.url)
            }
            model.showLibrary(.loupe)
        }
        return item
    }

    // MARK: - Thumbnails

    func collectionView(
        _: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath,
    ) {
        guard isShown, let item = item as? LibraryGridItem, model.items.indices.contains(indexPath.item) else {
            return
        }
        let photo = model.items[indexPath.item]
        if let id = prefetching.removeValue(forKey: photo.url) {
            model.thumbnailLoader.cancel(id)
        }
        requestThumbnail(for: item, photo)
    }

    func collectionView(
        _: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt _: IndexPath,
    ) {
        guard let item = item as? LibraryGridItem, let id = item.request else { return }
        item.request = nil
        model.thumbnailLoader.cancel(id)
    }

    private func requestThumbnail(for item: LibraryGridItem, _ photo: LibraryItem) {
        if let id = item.request {
            item.request = nil
            model.thumbnailLoader.cancel(id)
        }
        guard item.cell.image == nil || item.cell.item?.modified != photo.modified else { return }
        if let image = model.thumbnailLoader.cached(photo) {
            item.cell.setImage(image)
            return
        }
        item.request = model.thumbnailLoader.request(photo, lane: .onScreen) { [weak item] image in
            guard let item, item.cell.item?.url == photo.url else { return }
            item.request = nil
            if let image {
                item.cell.setImage(image)
            }
        }
    }

    func collectionView(_: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard isShown else { return }
        for indexPath in indexPaths where model.items.indices.contains(indexPath.item) {
            let photo = model.items[indexPath.item]
            guard prefetching[photo.url] == nil, model.thumbnailLoader.cached(photo) == nil else { continue }
            prefetching[photo.url] = model.thumbnailLoader.request(photo, lane: .lookAhead) { [weak self] _ in
                self?.prefetching.removeValue(forKey: photo.url)
            }
        }
    }

    func collectionView(_: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths where model.items.indices.contains(indexPath.item) {
            if let id = prefetching.removeValue(forKey: model.items[indexPath.item].url) {
                model.thumbnailLoader.cancel(id)
            }
        }
    }

    /// What's on screen: kept in memory, and its badges read first.
    @objc private func scrolled() {
        guard isShown else { return }
        let rows = collectionView.indexPathsForVisibleItems().map(\.item).filter(model.items.indices.contains)
        guard let first = rows.min(), let last = rows.max() else { return }
        model.thumbnailLoader.protected = Set(rows.map { model.items[$0].url })
        model.library.prioritize(first ..< last + 1)
    }

    // MARK: - Changes

    private func apply(_ diff: LibraryDiff) {
        guard !diff.isEmpty, !isStale else { return }
        let moves = diff.reset || !diff.removed.isEmpty || !diff.inserted.isEmpty
        guard isShown else {
            if moves {
                isStale = true
            } else {
                staleRows.formUnion(diff.updated)
            }
            return
        }
        guard !diff.reset else {
            reload()
            follow(model.selection, marking: model.selectedPhotos, revealing: true)
            return
        }
        if moves {
            collectionView.performBatchUpdates {
                shownCount = model.items.count
                collectionView.deleteItems(at: Set(diff.removed.map { IndexPath(item: $0, section: 0) }))
                collectionView.insertItems(at: Set(diff.inserted.map { IndexPath(item: $0, section: 0) }))
            }
        }
        update(diff.updated)
    }

    /// Redraws the badges of these rows' cells, and their thumbnails if their files changed.
    private func update(_ rows: IndexSet) {
        for row in rows where model.items.indices.contains(row) {
            guard let item = collectionView.item(at: IndexPath(item: row, section: 0)) as? LibraryGridItem else {
                continue
            }
            let photo = model.items[row]
            let rewritten = item.cell.item?.modified != photo.modified
            item.cell.configure(photo, image: nil)
            if rewritten {
                item.cell.setImage(nil)
            }
            if item.cell.image == nil {
                requestThumbnail(for: item, photo)
            }
        }
    }

    // MARK: - Selection

    private func follow(_ selection: URL?, marking photos: [URL], revealing: Bool = false) {
        let marking = Set(photos).subtracting([selection].compactMap(\.self))
        let changed = marked.symmetricDifference(marking).union([selected, selection].compactMap(\.self))
        for url in changed {
            guard let row = model.library.index(of: url),
                  let item = collectionView.item(at: IndexPath(item: row, section: 0)) as? LibraryGridItem else {
                continue
            }
            item.cell.isSelected = url == selection
            item.cell.isInSelection = marking.contains(url)
        }
        marked = marking
        let moved = selected != selection
        selected = selection
        guard moved || revealing, let selection, let row = model.library.index(of: selection), row < shownCount
        else { return }
        reveal(row)
    }

    /// Scrolls the least that brings cell `row` into view.
    private func reveal(_ row: Int) {
        let spacing = LibraryGridLayout.spacing
        collectionView.scrollToVisible(layout.frame(forItem: row).insetBy(dx: 0, dy: -spacing))
    }

    /// Takes the keyboard, as the Library grid does when it's shown.
    func takeFocus() {
        window?.makeFirstResponder(collectionView)
    }
}

// MARK: - Keys

/// The keys the grid handles itself, by key code.
private enum GridKey: UInt16 {
    case left = 123, right = 124, down = 125, up = 126, home = 115, end = 119, pageUp = 116, pageDown = 121
    case returnKey = 36, enter = 76, space = 49

    var opensLoupe: Bool {
        [.returnKey, .enter, .space].contains(self)
    }
}

extension LibraryGridView {
    /// The grid's own keys (the key monitor has the shortcuts first); true when the grid took the key.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]), shownCount > 0,
              let key = GridKey(rawValue: event.keyCode) else { return false }
        let extending = flags.contains(.shift)
        if key.opensLoupe {
            guard !extending, model.selection != nil else { return false }
            model.showLibrary(.loupe)
            return true
        }
        let last = shownCount - 1
        let current = model.selection.flatMap(model.library.index(of:))
        let target = current.map { self.target(of: key, from: $0, last: last) } ?? 0
        if (0 ... last).contains(target), target != current {
            model.click(model.items[target].url, extending: extending)
        }
        return true
    }

    /// The cell `key` moves to from cell `current`, of `last + 1`.
    private func target(of key: GridKey, from current: Int, last: Int) -> Int {
        let columns = layout.columns
        let page = max(layout.rows(in: scrollView.contentView.bounds.height) - 1, 1) * columns
        switch key {
        case .left: return current - 1
        case .right: return current + 1
        case .up: return current - columns
        // From a row above the last, down reaches the last row, even where it's short.
        case .down: return current / columns < last / columns ? min(current + columns, last) : current
        case .home: return 0
        case .end: return last
        case .pageUp: return max(current - page, 0)
        case .pageDown: return min(current + page, last)
        case .returnKey, .enter, .space: return current
        }
    }
}

/// The grid's collection view: it takes the keyboard in the Library module and gives its keys to the grid.
final class LibraryCollectionView: NSCollectionView {
    var onKey: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true {
            super.keyDown(with: event)
        }
    }
}

@_spi(Harness) public enum LibraryGridViews {
    /// The Library grid on its own, for measurements.
    @MainActor public static func make(model: EditorModel) -> NSView {
        LibraryGridView(model: model)
    }

    /// Scrolls a grid made by `make` to `fraction` (0 ... 1) of its height.
    @MainActor public static func scroll(_ view: NSView, to fraction: Double) {
        guard let grid = view as? LibraryGridView else { return }
        let clip = grid.scrollView.contentView
        let height = max(grid.collectionView.frame.height - clip.bounds.height, 0)
        clip.scroll(to: CGPoint(x: 0, y: height * fraction))
        grid.scrollView.reflectScrolledClipView(clip)
    }
}
