import AppKit
import RedlampDesign
import RedlampDocument
import SwiftUI

/// The filmstrip's photos in AppKit: a horizontal collection view whose cells are reused as it
/// scrolls, so 50,000 photos cost what a screenful does.
///
/// - Thumbnails: a cell scrolling into view asks for its thumbnail on screen; the collection
///   view's prefetching asks for the next ones at look-ahead priority and cancels them when the
///   strip turns back. A thumbnail arriving sets only its own cell.
/// - Changes: the library's row diffs become inserts and deletes; a badge redraws its cell.
/// - The selection is followed: the active photo's cell is highlighted and scrolled to the middle,
///   and the others selected with it (⌘- and ⇧-click) are marked.
final class FilmstripStripView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSCollectionViewPrefetching {
    static let height: CGFloat = 82
    private static let spacing: CGFloat = 6
    /// A flow layout needs its items strictly shorter than the view minus these.
    private static let insets = NSEdgeInsets(top: 6, left: 10, bottom: 5, right: 10)

    let collectionView = NSCollectionView()
    let scrollView = FilmstripScrollView()
    private let model: EditorModel
    private var observation: LibraryObservation?
    private var tracker: Tracker?
    /// The selection and marks as last followed. Cells are drawn from these, not from the model,
    /// which can be a turn ahead, so `follow` knows every cell it has to change.
    private var selected: URL?
    private var marked: Set<URL> = []
    private var prefetching: [URL: UInt64] = [:]
    /// Shown again: it goes back to the filmstrip's place once laid out.
    private var needsPlace = false

    init(model: EditorModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: Self.height))
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = FilmstripCellView.size
        layout.minimumLineSpacing = Self.spacing
        layout.minimumInteritemSpacing = Self.spacing
        layout.sectionInset = Self.insets
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.register(FilmstripItem.self, forItemWithIdentifier: FilmstripItem.identifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.setAccessibilityLabel("Filmstrip")
        // Laid out at the strip's height from the start: a flow layout taller than its view logs.
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
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        collectionView.reloadData()
        observation = model.library.observe { [weak self] diff in self?.apply(diff) }
        selected = model.selection
        tracker = Tracker { [weak self] in
            guard let self else { return }
            follow(model.selection, marking: model.selectedPhotos)
        }
        needsPlace = true
        needsLayout = true
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        needsPlace = true
        needsLayout = true
    }

    /// Goes back to the filmstrip's place, in either module, once laid out at its width: the photo in its
    /// middle as it was last scrolled, else the active photo. A strip made again, as the filmstrip is when
    /// it's shown again after F6, Lights Out or presenting, would start at the first photo.
    private func restorePlace() {
        needsPlace = false
        guard let place = model.filmstripPlace ?? model.selection, let row = model.library.index(of: place) else {
            return
        }
        center(row: row, animated: false)
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
        model.items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath,
    ) -> NSCollectionViewItem {
        let view = collectionView.makeItem(withIdentifier: FilmstripItem.identifier, for: indexPath)
        guard let item = view as? FilmstripItem, model.items.indices.contains(indexPath.item) else { return view }
        let photo = model.items[indexPath.item]
        item.cell.configure(photo, image: model.thumbnailLoader.cached(photo))
        item.cell.isSelected = photo.url == selected
        item.cell.isInSelection = marked.contains(photo.url)
        item.cell.onClick = { [weak self] modifiers in
            self?.model.click(
                photo.url, toggling: modifiers.contains(.command), extending: modifiers.contains(.shift),
            )
        }
        item.cell.onMenu = { [weak self] in
            self.flatMap { FilmstripMenu.menu(for: photo.url, model: $0.model) }
        }
        return item
    }

    // MARK: - Thumbnails

    func collectionView(
        _: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath,
    ) {
        guard let item = item as? FilmstripItem, model.items.indices.contains(indexPath.item) else { return }
        let photo = model.items[indexPath.item]
        if let id = prefetching.removeValue(forKey: photo.url) {
            model.thumbnailLoader.cancel(id)
        }
        requestThumbnail(for: item, photo)
    }

    func collectionView(
        _: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt _: IndexPath,
    ) {
        guard let item = item as? FilmstripItem, let id = item.request else { return }
        item.request = nil
        model.thumbnailLoader.cancel(id)
    }

    private func requestThumbnail(for item: FilmstripItem, _ photo: LibraryItem) {
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
        let rows = collectionView.indexPathsForVisibleItems().map(\.item)
        guard let first = rows.min(), let last = rows.max() else { return }
        model.thumbnailLoader.protected = Set(rows.filter(model.items.indices.contains).map { model.items[$0].url })
        model.library.prioritize(first ..< last + 1)
        let middle = CGPoint(x: scrollView.contentView.bounds.midX, y: collectionView.bounds.midY)
        if let row = collectionView.indexPathForItem(at: middle)?.item, model.items.indices.contains(row) {
            model.filmstripPlace = model.items[row].url
        }
    }

    // MARK: - Changes

    private func apply(_ diff: LibraryDiff) {
        guard !diff.reset else {
            prefetching.values.forEach(model.thumbnailLoader.cancel)
            prefetching = [:]
            collectionView.reloadData()
            follow(model.selection, marking: model.selectedPhotos, animated: false)
            return
        }
        if !diff.removed.isEmpty || !diff.inserted.isEmpty {
            collectionView.performBatchUpdates {
                collectionView.deleteItems(at: Set(diff.removed.map { IndexPath(item: $0, section: 0) }))
                collectionView.insertItems(at: Set(diff.inserted.map { IndexPath(item: $0, section: 0) }))
            }
        }
        for row in diff.updated where model.items.indices.contains(row) {
            guard let item = collectionView.item(at: IndexPath(item: row, section: 0)) as? FilmstripItem else {
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

    private func follow(_ selection: URL?, marking photos: [URL], animated: Bool = true) {
        let marking = Set(photos).subtracting([selection].compactMap(\.self))
        let changed = marked.symmetricDifference(marking).union([selected, selection].compactMap(\.self))
        for url in changed {
            guard let row = model.library.index(of: url),
                  let item = collectionView.item(at: IndexPath(item: row, section: 0)) as? FilmstripItem else {
                continue
            }
            item.cell.isSelected = url == selection
            item.cell.isInSelection = marking.contains(url)
        }
        marked = marking
        let moved = selected != selection
        selected = selection
        // Scrolled to when it changes, and after a reload; not when only the marks do.
        guard moved || !animated, let selection, let row = model.library.index(of: selection) else { return }
        center(row: row, animated: animated)
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
