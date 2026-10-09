import AppKit
import RedlampDesign
import RedlampDocument
import RedlampLibrary
import SwiftUI

/// The filmstrip's photos in AppKit: a horizontal collection view whose cells are reused as it
/// scrolls, so 50,000 photos cost what a screenful does.
///
/// - Thumbnails: a cell scrolling into view asks for its thumbnail on screen; the collection
///   view's prefetching asks for the next ones at look-ahead priority and cancels them when the
///   strip turns back. A thumbnail arriving sets only its own cell.
/// - Changes: the library's row diffs become inserts and deletes; a badge redraws its cell.
/// - The cells are the grid's, in its order (`GridOrder`): grouped (LIB-41, `LibraryGroups`), the groups' cells one
///   group after another without their headers, a closed group's left out; stacks (LIB-28, `LibraryStacks`)
///   closed, each one cell with its count. The strip shows them afresh as they change, and while it shows them,
///   the photos that come or go wait for the groups or the stacks.
/// - The selection is followed: the active photo's cell is highlighted and scrolled to the middle,
///   and the others selected with it (⌘- and ⇧-click, in the grid's order) are marked.
final class FilmstripStripView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSCollectionViewPrefetching {
    static let height: CGFloat = 82
    private static let spacing: CGFloat = 6
    private static let insets = NSEdgeInsets(top: 6, left: 10, bottom: 5, right: 10)

    let collectionView = NSCollectionView()
    let scrollView = FilmstripScrollView()
    private let model: EditorModel
    private var observation: LibraryObservation?
    private var editObservation: LibraryObservation?
    private var stacksObservation: LibraryObservation?
    private var groupsObservation: LibraryObservation?
    private var tracker: Tracker?
    /// The grid's groups or stacks as last followed; nil while it shows the list as it is, when the items are the
    /// photos' rows.
    private var shownOrder: GridOrder?
    /// Each cell's photo, while the groups or the stacks are followed.
    private var itemPhotos = ContiguousArray<Int64>()
    /// The selection and marks as last followed. Cells are drawn from these, not from the model,
    /// which can be a turn ahead, so `follow` knows every cell it has to change.
    private var selected: URL?
    private var marked = PhotoSelection()
    private var prefetching: [URL: UInt64] = [:]
    /// The items waiting for a large source's rows, by row (`showRead`).
    private var unread: [Int: FilmstripItem] = [:]
    /// Shown again: it goes back to the filmstrip's place once laid out.
    private var needsPlace = false
    /// The photos changed while the strip was out of sight (hidden, or in the module not shown): it reloads
    /// once shown.
    private var isStale = false
    /// Grouped afresh in a new order, which the strip shows a turn later.
    private var isRegrouping = false
    /// In sight when it last looked.
    private var wasInSight = false
    /// Times every cell was made again.
    private(set) var reloads = 0

    init(model: EditorModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: Self.height))
        collectionView.collectionViewLayout = FilmstripLayout(
            itemSize: FilmstripCellView.size, spacing: Self.spacing, insets: Self.insets,
        )
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.register(FilmstripItem.self, forItemWithIdentifier: FilmstripItem.identifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.setAccessibilityLabel("Filmstrip")
        scrollView.frame = bounds
        collectionView.frame = bounds
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
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

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        if needsPlace, bounds.width > 0 {
            restorePlace()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = nil
        editObservation = nil
        stacksObservation = nil
        groupsObservation = nil
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        reload()
        observation = model.library.observe { [weak self] diff in self?.apply(diff) }
        editObservation = model.editRenders.observe { [weak self] urls in self?.editsShown(urls) }
        stacksObservation = model.gridStacks.observe { [weak self] change in self?.stacksChanged(change) }
        groupsObservation = model.gridGroups.observe { [weak self] change in self?.groupsChanged(change) }
        selected = model.selection
        wasInSight = isInShownModule(model)
        tracker = Tracker { [weak self] in
            guard let self else { return }
            let (selection, photos) = (model.selection, model.photoSelection)
            let inSight = isInShownModule(model)
            defer { wasInSight = inSight }
            if inSight, !wasInSight {
                cameIntoSight()
            } else if inSight {
                follow(selection, marking: photos)
            }
        }
        needsPlace = true
        needsLayout = true
    }

    override func viewDidHide() {
        super.viewDidHide()
        wasInSight = false
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if isInShownModule(model), !wasInSight {
            wasInSight = true
            cameIntoSight()
        }
    }

    /// Shown again (in the other module, or unhidden): what changed meanwhile, the selection, and back to
    /// the filmstrip's place.
    private func cameIntoSight() {
        if isStale {
            isStale = false
            prefetching.values.forEach(model.thumbnailLoader.cancel)
            prefetching = [:]
            reload()
        }
        follow(model.selection, marking: model.photoSelection, scrolling: false)
        needsPlace = true
        needsLayout = true
    }

    /// Goes back to the filmstrip's place, in either module, once laid out at its width: the photo in its
    /// middle as it was last scrolled, else the active photo. A strip made again, as the filmstrip is when
    /// it's shown again after F6, Lights Out or presenting, would start at the first photo.
    private func restorePlace() {
        needsPlace = false
        guard let place = model.filmstripPlace ?? model.selection, let item = item(of: place) else { return }
        center(row: item, animated: false)
    }

    // MARK: - Items

    /// Shows the items afresh, counted at once: a reload counts them at the next layout, and a batch update before then
    /// would count its change twice, deleting rows the count no longer has.
    private func reload() {
        reloads += 1
        unread = [:]
        followItems()
        collectionView.reloadData()
        collectionView.layoutSubtreeIfNeeded()
    }

    /// The grid's order as the model has it now (`EditorModel.gridOrder`), and each cell's photo.
    private func followItems() {
        let order = model.gridOrder
        if case .listed = order {
            shownOrder = nil
            itemPhotos = []
        } else {
            shownOrder = order
            itemPhotos = order.cells
        }
    }

    /// The row of item `index`'s photo; nil for one the photos no longer have.
    func row(ofItem index: Int) -> Int? {
        guard shownOrder != nil else { return model.items.indices.contains(index) ? index : nil }
        return itemPhotos.indices.contains(index) ? model.library.photoList.index(of: itemPhotos[index]) : nil
    }

    /// The item showing row `row`'s photo; nil inside a closed stack or a closed group.
    private func item(ofRow row: Int) -> Int? {
        guard let shownOrder else { return row }
        let ids = model.library.photoIDs
        return ids.indices.contains(row) ? shownOrder.index(of: ids[row]) : nil
    }

    /// The item showing `url`'s photo, or the closed stack's it's in; nil in a closed group.
    private func item(of url: URL) -> Int? {
        guard let row = model.library.index(of: url) else { return nil }
        guard let shownOrder else { return row }
        return shownOrder.cell(for: model.library.photoIDs[row]).flatMap(shownOrder.index(of:))
    }

    /// The stacks changed: the strip shows them afresh, unless it shows the groups, which follow the stacks.
    private func stacksChanged(_ change: LibraryStacks.Change) {
        guard model.libraryViews.groups?.list == nil else { return }
        cellsChanged(afresh: change == .restacked)
    }

    /// The groups changed: grouped afresh, or opened and closed. Their headers aren't in the strip.
    private func groupsChanged(_ change: LibraryGroups.Change) {
        switch change {
        case .regrouped: regrouped()
        case .items: cellsChanged(afresh: false)
        case .headers: break
        }
    }

    /// Grouped afresh: the cells in the same order (moments, days and the moments' setting keep the photos' order)
    /// stay as they are; a new order is shown a turn later, so the grid's change goes on screen first.
    private func regrouped() {
        guard isInShownModule(model) else {
            isStale = true
            return
        }
        let order = model.gridOrder
        if shownOrder != nil, case .grouped = order, order.cells == itemPhotos {
            shownOrder = order
            return
        }
        guard !isRegrouping else { return }
        isRegrouping = true
        DispatchQueue.main.async { [weak self] in
            guard let self, isRegrouping else { return }
            isRegrouping = false
            cellsChanged(afresh: true)
        }
    }

    /// The strip shows the grid's cells afresh, or for groups and stacks opened or closed, its cells on screen again
    /// where they are, which its layout places a screenful at a time; a batch update's animations would cost more.
    private func cellsChanged(afresh: Bool) {
        guard isInShownModule(model) else {
            isStale = true
            return
        }
        reload()
        guard !afresh else {
            prefetching.values.forEach(model.thumbnailLoader.cancel)
            prefetching = [:]
            follow(model.selection, marking: model.photoSelection, animated: false)
            return
        }
        follow(model.selection, marking: model.photoSelection)
    }

    /// What item `index`'s cell shows of its stacks.
    private func stackBadges(ofItem index: Int) -> (count: GridBadges.Kind?, pair: GridBadges.Kind?) {
        guard let stacks = shownOrder?.stacks, itemPhotos.indices.contains(index) else { return (nil, nil) }
        return model.stackBadges(of: itemPhotos[index], in: stacks)
    }

    /// Scrolls the photo at `row` to the strip's middle, by its clip view: `scrollToItems` doesn't move a
    /// strip whose scroll view says it has no horizontal scroller (`FilmstripScrollView`).
    func center(row: Int, animated: Bool) {
        collectionView.layoutSubtreeIfNeeded()
        // The model's list can be ahead of the rows the strip has loaded, and asking for one it hasn't raises;
        // the reload that brings the row centres it.
        guard collectionView.numberOfSections > 0, row < collectionView.numberOfItems(inSection: 0),
              let item = collectionView.layoutAttributesForItem(at: IndexPath(item: row, section: 0))?.frame
        else { return }
        let clip = scrollView.contentView
        let end = max(collectionView.frame.width - clip.bounds.width, 0)
        let origin = CGPoint(x: min(max(item.midX - clip.bounds.width / 2, 0), end), y: 0)
        // An animation doesn't advance while the window is off screen or the display is asleep.
        if animated, window?.occlusionState.contains(.visible) == true {
            NSAnimationContext.runAnimationGroup { context in
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.scroll(to: origin)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Data source

    func collectionView(_: NSCollectionView, numberOfItemsInSection _: Int) -> Int {
        shownOrder == nil ? model.items.count : itemPhotos.count
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath,
    ) -> NSCollectionViewItem {
        let view = collectionView.makeItem(withIdentifier: FilmstripItem.identifier, for: indexPath)
        guard let item = view as? FilmstripItem, let row = row(ofItem: indexPath.item) else { return view }
        unread.removeValue(forKey: row)
        // A large source's row not read yet: the cell shows once it is (`showRead`).
        guard let photo = model.library.row(at: row) else {
            item.cell.isHidden = true
            unread[row] = item
            return item
        }
        show(photo, row: row, in: item, at: indexPath.item)
        return item
    }

    /// Sets `item`, item `index` of the strip, to row `row`'s photo.
    private func show(_ photo: LibraryItem, row: Int, in item: FilmstripItem, at index: Int) {
        item.cell.isHidden = false
        let shown = model.thumbnailLoader.cachedThumbnail(photo)
        item.cell.rendersEdit = model.editRenders.renders(photo)
        item.cell.configure(photo, image: shown?.image, edit: shown?.edit)
        item.cell.stackBadges = stackBadges(ofItem: index)
        item.cell.isSelected = photo.url == selected
        item.cell.isInSelection = photo.url != selected && marked.contains(model.library.photoIDs[row])
        item.cell.onClick = { [weak self] modifiers in
            self?.model.clickInGrid(
                photo.url, toggling: modifiers.contains(.command), extending: modifiers.contains(.shift),
            )
        }
        item.cell.onMenu = { [weak self] in
            self.flatMap { FilmstripMenu.menu(for: photo.url, model: $0.model, culling: true) }
        }
    }

    /// A large source's rows just read: the cells that waited for them show their photos.
    private func showRead(_ rows: IndexSet) {
        for (row, item) in unread where rows.contains(row) {
            unread[row] = nil
            guard let index = self.item(ofRow: row),
                  collectionView.item(at: IndexPath(item: index, section: 0)) === item,
                  let photo = model.library.items.row(row)
            else { continue }
            show(photo, row: row, in: item, at: index)
            requestThumbnail(for: item, photo)
        }
    }

    // MARK: - Thumbnails

    func collectionView(
        _: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath,
    ) {
        guard let item = item as? FilmstripItem, let row = row(ofItem: indexPath.item),
              let photo = model.library.items.row(row)
        else { return }
        item.cell.isSelected = photo.url == selected
        item.cell.isInSelection = photo.url != selected && marked.contains(model.library.photoIDs[row])
        if let id = prefetching.removeValue(forKey: photo.url) {
            model.thumbnailLoader.cancel(id)
        }
        requestThumbnail(for: item, photo)
    }

    func collectionView(
        _: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath,
    ) {
        if let row = row(ofItem: indexPath.item), unread[row] === item {
            unread[row] = nil
        }
        guard let item = item as? FilmstripItem, let id = item.request else { return }
        item.request = nil
        model.thumbnailLoader.cancel(id)
    }

    private func requestThumbnail(for item: FilmstripItem, _ photo: LibraryItem) {
        if let id = item.request {
            item.request = nil
            model.thumbnailLoader.cancel(id)
        }
        let edit = model.editRenders.shownEdit(for: photo)
        guard item.cell.image == nil || item.cell.item?.modified != photo.modified || item.cell.shownEdit != edit
        else { return }
        if let shown = model.thumbnailLoader.cachedThumbnail(photo), shown.edit == edit || item.cell.image == nil {
            item.cell.setImage(shown.image, edit: shown.edit)
            if shown.edit == edit {
                return
            }
        }
        item.request = model.thumbnailLoader.request(photo, lane: .onScreen) { [weak item] image in
            guard let item, item.cell.item?.url == photo.url else { return }
            item.request = nil
            if let image {
                item.cell.setImage(image, edit: edit)
            }
        }
    }

    func collectionView(_: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        model.library.askForRows(at: indexPaths.compactMap { row(ofItem: $0.item) })
        for indexPath in indexPaths {
            guard let row = row(ofItem: indexPath.item), let photo = model.library.items.row(row) else { continue }
            guard prefetching[photo.url] == nil, !model.thumbnailLoader.hasThumbnail(photo) else { continue }
            prefetching[photo.url] = model.thumbnailLoader.request(photo, lane: .lookAhead) { [weak self] _ in
                self?.prefetching.removeValue(forKey: photo.url)
            }
        }
    }

    func collectionView(_: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            if let row = row(ofItem: indexPath.item), let photo = model.library.items.row(row),
               let id = prefetching.removeValue(forKey: photo.url) {
                model.thumbnailLoader.cancel(id)
            }
        }
    }

    /// What's on screen: kept in memory, and its badges read first.
    @objc private func scrolled() {
        let rows = collectionView.indexPathsForVisibleItems().compactMap { row(ofItem: $0.item) }
        guard let first = rows.min(), let last = rows.max() else { return }
        model.library.showRows(first ..< last + 1, in: "filmstrip")
        model.thumbnailLoader.protected = Set(rows.compactMap { model.library.items.row($0)?.url })
        for run in LibraryGridView.runs(of: rows) {
            model.library.prioritize(run)
        }
        model.editRenders.show(first ..< last + 1, in: .filmstrip)
        let middle = CGPoint(x: scrollView.contentView.bounds.midX, y: collectionView.bounds.midY)
        // Until it has gone back to its place, the strip is where its layout left it, not where it was scrolled.
        if !needsPlace, let item = collectionView.indexPathForItem(at: middle)?.item, let row = row(ofItem: item),
           let photo = model.library.items.row(row) {
            model.filmstripPlace = photo.url
        }
    }

    // MARK: - Changes

    private func apply(_ diff: LibraryDiff) {
        guard isInShownModule(model) else {
            isStale = isStale || !diff.isEmpty
            return
        }
        guard !diff.reset else {
            prefetching.values.forEach(model.thumbnailLoader.cancel)
            prefetching = [:]
            reload()
            follow(model.selection, marking: model.photoSelection, animated: false)
            return
        }
        // While groups or stacks are shown, the photos that came or went wait for them (`cellsChanged`).
        if shownOrder == nil, !diff.removed.isEmpty || !diff.inserted.isEmpty {
            collectionView.performBatchUpdates {
                collectionView.deleteItems(at: Set(diff.removed.map { IndexPath(item: $0, section: 0) }))
                collectionView.insertItems(at: Set(diff.inserted.map { IndexPath(item: $0, section: 0) }))
            }
            unread = Dictionary(unread.values.compactMap { item in
                collectionView.indexPath(for: item).flatMap { row(ofItem: $0.item) }.map { ($0, item) }
            }) { first, _ in first }
        }
        showRead(diff.read)
        // Asking the strip for each of thousands of rows takes longer than a frame: a change to that many
        // reaches the cells it holds.
        let rows = diff.updated.count > 64 ? IndexSet(collectionView.subviews.compactMap { view in
            (view as? FilmstripCellView)?.item.flatMap { model.library.index(of: $0.url) }
        }).intersection(diff.updated) : diff.updated
        for row in rows where model.items.indices.contains(row) {
            guard let index = item(ofRow: row),
                  let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? FilmstripItem,
                  let photo = model.library.items.row(row)
            else { continue }
            let rewritten = item.cell.item?.modified != photo.modified
            item.cell.rendersEdit = model.editRenders.renders(photo)
            item.cell.configure(photo, image: nil)
            if rewritten {
                item.cell.setImage(nil)
            }
            if item.cell.image == nil || item.cell.shownEdit != model.editRenders.shownEdit(for: photo) {
                requestThumbnail(for: item, photo)
            }
        }
    }

    /// The thumbnails of these photos show another edit: their cells ask for them, or the strip reloads
    /// once it's in sight.
    private func editsShown(_ urls: [URL]) {
        guard isInShownModule(model) else {
            isStale = true
            return
        }
        for url in urls {
            guard let row = model.library.index(of: url), let index = item(ofRow: row),
                  let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? FilmstripItem,
                  let photo = model.library.items.row(row)
            else { continue }
            item.cell.rendersEdit = model.editRenders.renders(photo)
            requestThumbnail(for: item, photo)
        }
    }

    // MARK: - Selection

    private func follow(
        _ selection: URL?, marking photos: PhotoSelection, animated: Bool = true, scrolling: Bool = true,
    ) {
        // The cells the strip holds, without asking it to lay out as `visibleItems()` would.
        let ids = model.library.photoIDs
        for case let cell as FilmstripCellView in collectionView.subviews {
            guard let url = cell.item?.url, let row = model.library.index(of: url) else { continue }
            cell.isSelected = url == selection
            cell.isInSelection = url != selection && photos.contains(ids[row])
        }
        marked = photos
        let moved = selected != selection
        selected = selection
        // Scrolled to when it changes, and after a reload; not when only the marks do.
        guard scrolling, moved || !animated, let selection, let item = item(of: selection) else { return }
        center(row: item, animated: animated)
    }
}

/// One row of cells of one size, each one's place worked out from its row: a reload or a change to the
/// photos lays out the cells on screen, at any count, where a flow layout lays out every one.
final class FilmstripLayout: NSCollectionViewLayout {
    let itemSize: CGSize
    let spacing: CGFloat
    let insets: NSEdgeInsets

    /// The collection view's count as it has it now, which `prepare` can be a reload behind.
    private var count: Int {
        guard let collectionView, collectionView.numberOfSections > 0 else { return 0 }
        return collectionView.numberOfItems(inSection: 0)
    }

    init(itemSize: CGSize, spacing: CGFloat, insets: NSEdgeInsets) {
        self.itemSize = itemSize
        self.spacing = spacing
        self.insets = insets
        super.init()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var collectionViewContentSize: NSSize {
        let height = max(collectionView?.bounds.height ?? 0, insets.top + itemSize.height + insets.bottom)
        guard count > 0 else { return NSSize(width: 0, height: height) }
        return NSSize(
            width: insets.left + CGFloat(count) * itemSize.width + CGFloat(count - 1) * spacing + insets.right,
            height: height,
        )
    }

    func frame(ofItem item: Int) -> CGRect {
        CGRect(
            origin: CGPoint(x: insets.left + CGFloat(item) * (itemSize.width + spacing), y: insets.top),
            size: itemSize,
        )
    }

    /// The rows whose cells `rect` meets.
    func items(in rect: CGRect) -> Range<Int> {
        guard count > 0, rect.maxY > insets.top, rect.minY < insets.top + itemSize.height else { return 0 ..< 0 }
        let pitch = itemSize.width + spacing
        let first = max(Int(((rect.minX - insets.left - itemSize.width) / pitch).rounded(.down)) + 1, 0)
        let last = min(Int(((rect.maxX - insets.left) / pitch).rounded(.up)), count)
        return first < last ? first ..< last : 0 ..< 0
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        items(in: rect).compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, (0 ..< count).contains(indexPath.item) else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frame(ofItem: indexPath.item)
        return attributes
    }

    /// The collection view asks any layout for this, as a flow layout has it: without it, it keeps its
    /// width at the clip view's and scrolls nowhere.
    @objc var scrollDirection: NSCollectionView.ScrollDirection {
        .horizontal
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.height != collectionView?.bounds.height
    }
}

/// Scrolls horizontally with a mouse wheel too (trackpads already scroll sideways). It never shows
/// a scroller: with a mouse connected, AppKit's legacy style otherwise draws a track along the
/// strip's bottom, though `hasHorizontalScroller` was turned off.
final class FilmstripScrollView: NSScrollView {
    override var hasHorizontalScroller: Bool {
        get { false }
        set { super.hasHorizontalScroller = false }
    }

    override var hasVerticalScroller: Bool {
        get { false }
        set { super.hasVerticalScroller = false }
    }

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    override func scrollWheel(with event: NSEvent) {
        guard !event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let cgEvent = event.cgEvent?.copy() else {
            super.scrollWheel(with: event)
            return
        }
        cgEvent.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: Double(event.scrollingDeltaY))
        cgEvent.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: 0)
        cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(event.scrollingDeltaY))
        cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        super.scrollWheel(with: NSEvent(cgEvent: cgEvent) ?? event)
    }
}

@_spi(Harness) public enum FilmstripViews {
    /// The filmstrip's photos (the strip without its header), for the harness and measurements.
    @MainActor public static func make(model: EditorModel) -> NSView {
        FilmstripStripView(model: model)
    }

    @MainActor public static let height = FilmstripStripView.height

    /// Scrolls a strip made by `make` to `fraction` (0 ... 1) of its length.
    @MainActor public static func scroll(_ view: NSView, to fraction: Double) {
        guard let strip = view as? FilmstripStripView else { return }
        let clip = strip.scrollView.contentView
        let width = max(strip.collectionView.frame.width - clip.bounds.width, 0)
        clip.scroll(to: CGPoint(x: width * fraction, y: 0))
        strip.scrollView.reflectScrolledClipView(clip)
    }
}

/// Hosts the AppKit strip under the SwiftUI header.
struct FilmstripStripHost: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context _: Context) -> FilmstripStripView {
        FilmstripStripView(model: model)
    }

    func updateNSView(_: FilmstripStripView, context _: Context) {}
}
