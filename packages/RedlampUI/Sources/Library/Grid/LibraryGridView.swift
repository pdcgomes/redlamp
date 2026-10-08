import AppKit
import QuartzCore
import RedlampDesign
import RedlampDocument
import RedlampLibrary

/// The Library module's grid (LIB-13's first grid, grown by LIB-14): the current source's photos, from
/// the library's photo list or the disk's listing as the filmstrip has them, as cells of layers in an
/// AppKit scroll view. Only the cells on screen exist, and a cell scrolling in is one recycled from a row
/// that scrolled out: its layers' frames and contents change, and AppKit has no view to add, lay out,
/// track or describe, so scrolling keeps within a frame at any size (`LibraryGridCell`). Thumbnails are
/// decoded off the main thread at the size the cells need (`GridThumbnails`), the next screen's ahead.
///
/// - The selection is the filmstrip's (`EditorModel.photoSelection` and its active photo): click,
///   ⌘-click and ⇧-click do what they do there, and a rubber band drawn from between the cells selects
///   what it covers, adding to the selection with ⇧ or ⌘. The arrow keys move the active photo, ⇧
///   extending the selection from the photo it started at; Home and End go to the ends, Page Up and
///   Page Down a screen; Return, Space or a double-click open the loupe, and Z the loupe at 1:1.
/// - A photo pressed and moved drags the selection when it's in it, else the photo alone, onto a folder or a
///   collection in the left panel (`LibraryGridView+Drag`); a press on a selected photo keeps the selection
///   until it's released without a drag.
/// - The thumbnail size (= and -), the cell style (J) and a context menu on photos and between them;
///   each source's size, style, place and selection are remembered (`LibraryViewState`).
/// - Grouped (LIB-41, `LibraryGroups`), each group has a header across the grid, a click on it opening or
///   closing the group and an ⌥-click every group; the grid follows the groups' diffs, moving the cells
///   that stay and keeping the selection and the active photo, and its keys go through the photos on show
///   in its order.
/// - Out of sight (Develop or the loupe is shown) it does nothing: changes to the photos wait, and it
///   reloads once shown.
final class LibraryGridView: NSView, NSViewToolTipOwner {
    let scrollView = NSScrollView()
    let content = LibraryGridContentView()
    private(set) var gridLayout = LibraryGridLayout()
    let model: EditorModel
    let thumbnails: GridThumbnails
    let details: PhotoDetailsCache
    private var observation: LibraryObservation?
    private var editObservation: LibraryObservation?
    private var groupsObservation: LibraryObservation?
    private var trackers: [Tracker] = []
    /// The cells on screen, by item (a row of the photos, or grouped, a header or a photo), and those out of
    /// sight waiting to be used again.
    private(set) var cells: [Int: LibraryGridCell] = [:]
    private var pool: [LibraryGridCell] = []
    /// The groups as last followed, and their sections; nil while ungrouped. Items are read from these.
    private(set) var shownGroups: GroupedList?
    private(set) var sections: GridSections?
    /// Each item's photo, -1 for a header, so the items on and near the screen are read without the groups' tree.
    private var itemPhotos = ContiguousArray<Int64>()
    /// The headers on screen, by item, and those waiting to be used again.
    private(set) var headers: [Int: GroupHeaderCell] = [:]
    private var headerPool: [GroupHeaderCell] = []
    private var prefetching: [URL: UInt64] = [:]
    /// The selection as last followed. Cells are drawn from these, not from the model, which can be a turn
    /// ahead.
    private var selected: URL?
    private var marked = PhotoSelection()
    /// The photos the grid has: the library's count when it last reloaded or changed.
    private(set) var shownCount = 0
    /// Photos came or went while the grid was hidden, or it hasn't loaded yet.
    private var isStale = true
    /// Rows whose badges changed while the grid was hidden.
    private var staleRows = IndexSet()
    /// The cells on screen when the grid last scrolled.
    private var visibleRows = 0 ..< 0
    /// Times every cell was reloaded: once the grid has been shown, a module switch reloads nothing.
    private(set) var reloads = 0
    /// Whether the grid was on screen when it last looked.
    private var wasShown = false
    private var texts: [GridText.Key: CGImage] = [:]
    private var drawingTexts: Set<GridText.Key> = []
    private var headerTexts: [GroupHeaderText.Key: CGImage] = [:]
    private var drawingHeaderTexts: Set<GroupHeaderText.Key> = []
    /// The group whose header showed the focus when the selection was last followed.
    private var shownFocus: Int?
    /// The content's tooltip area is made.
    private var hasToolTip = false
    /// A rubber band being drawn: where it started, and the selection it adds to (with ⇧ or ⌘).
    private var band: Band?
    /// A press on a photo, which a drag takes along, and where a keyword dragged over the grid would land
    /// (`LibraryGridView+Drag`).
    var photoPress: PhotoPress?
    var keywordTarget: KeywordTarget?
    /// The item whose context menu is open.
    private var menuItem: Int?
    /// The cells' accessibility elements, by photo, and the headers', by group, as last asked for.
    private var elements: [URL: GridCellElement] = [:]
    private var headerElements: [Int: GridCellElement] = [:]

    private struct Band {
        let start: CGPoint
        let base: PhotoSelection?
        var current: CGPoint
        var isDrawn = false
        let layer = CALayer()
        var timer: Timer?
    }

    init(model: EditorModel) {
        self.model = model
        thumbnails = GridThumbnails(
            scheduler: model.library.scheduler, packs: model.thumbnailLoader.packs,
            store: { [weak library = model.library] in library?.storeThumbnail(for: $0) }, renders: model.editRenders,
            decode: model.thumbnailLoader.decode,
        )
        details = PhotoDetailsCache(library: model.library)
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        content.grid = self
        content.frame = bounds
        content.autoresizingMask = [.width]
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = content
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
        isInShownModule(model)
    }

    private var scale: CGFloat {
        window?.backingScaleFactor ?? 2
    }

    /// The long edge a cell's thumbnail is decoded at, for its image's size on this screen.
    private var edge: Int {
        GridThumbnails.edge(forPixels: gridLayout.geometry.image.width * scale)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = nil
        editObservation = nil
        groupsObservation = nil
        trackers.forEach { $0.cancel() }
        trackers = []
        wasShown = false
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: window,
        )
        screenChanged()
        observation = model.library.observe { [weak self] diff in self?.apply(diff) }
        editObservation = model.editRenders.observe { [weak self] urls in self?.editsShown(urls) }
        groupsObservation = model.gridGroups.observe { [weak self] change in self?.groupsChanged(change) }
        trackers = [
            Tracker { [weak self] in
                guard let self else { return }
                let (selection, photos, _) = (model.selection, model.photoSelection, model.module)
                guard isShown else {
                    wasShown = false
                    return
                }
                guard wasShown, !isStale else {
                    return show()
                }
                follow(selection, marking: photos)
            },
            Tracker { [weak self] in
                guard let self else { return }
                let state = model.libraryViews
                _ = (state.thumbnailSize, state.cellStyle)
                relayout()
            },
            Tracker { [weak self] in
                guard let self, model.libraryViews.restoredTop != nil, isShown, wasShown, !isStale else { return }
                _ = restorePlace()
            },
        ]
    }

    @objc private func screenChanged() {
        thumbnails.colorSpace = window?.colorSpace?.cgColorSpace
        texts = [:]
        headerTexts = [:]
        GridBadges.prepare(scale: scale)
    }

    override func viewDidHide() {
        super.viewDidHide()
        wasShown = false
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if isShown, !wasShown {
            show()
        }
    }

    override func layout() {
        super.layout()
        relayout()
    }

    /// Shown: what changed while it was hidden, the thumbnails its cells lack, the selection, and the active
    /// photo, or the place the source was left at, scrolled into view.
    private func show() {
        wasShown = true
        if isStale {
            reload()
        } else if !staleRows.isEmpty {
            update(staleRows)
            staleRows = []
        }
        tile()
        follow(model.selection, marking: model.photoSelection, revealing: !restorePlace())
    }

    private func reload() {
        isStale = false
        staleRows = []
        reloads += 1
        prefetching.values.forEach(thumbnails.cancel)
        prefetching = [:]
        followGroups()
        recycleAll()
        relayout(force: true)
    }

    /// The groups as the model has them now, and the items' count with them.
    private func followGroups() {
        shownGroups = model.gridGroups.list
        sections = shownGroups.map(GridSections.init)
        shownCount = shownGroups?.count ?? model.items.count
        // Made apart and set once: appending to the view's own array checks its access at every item.
        var photos = ContiguousArray<Int64>()
        if let shownGroups {
            photos.reserveCapacity(shownGroups.count)
            for item in shownGroups {
                if case let .photo(id) = item {
                    photos.append(id)
                } else {
                    photos.append(-1)
                }
            }
        }
        itemPhotos = photos
    }

    /// The same source's photos in another order or another number (a filter, LIB-18), or grouped afresh:
    /// cells on screen keep their layers, and those whose item shows another photo now take it. Grouped, a
    /// photo still on show keeps its cell, which moves to its item.
    private func refill(keeping anchor: ScreenAnchor? = nil) {
        let photos = cells.compactMap { item, cell in cell.item.map { (item, cell, $0.url) } }
        followGroups()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if shownGroups != nil {
            var moved: [Int: LibraryGridCell] = [:]
            var left: [LibraryGridCell] = []
            for (_, cell, url) in photos {
                if let next = item(of: url), moved[next] == nil {
                    moved[next] = cell
                } else {
                    left.append(cell)
                }
            }
            for (item, cell) in cells where cell.item == nil {
                moved[item] = cell
            }
            left.forEach(release)
            cells = moved
        }
        for (item, cell) in cells where item >= shownCount || sections?.isHeader(item) == true {
            cells.removeValue(forKey: item)
            release(cell)
        }
        for (item, header) in headers where item >= shownCount || sections?.isHeader(item) != true {
            headers.removeValue(forKey: item)
            release(header)
        }
        CATransaction.commit()
        relayout(force: true, keeping: anchor)
    }

    /// Groups opened or closed: the cells and headers that stay move to their items after `diff`, those it
    /// removed go back to the pool, and the headers it updated show their group as it is now.
    private func follow(_ diff: PhotoListDiff, keeping anchor: ScreenAnchor?) {
        followGroups()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var moved: [Int: LibraryGridCell] = [:]
        for (item, cell) in cells {
            if let next = Self.index(after: diff, of: item) {
                moved[next] = cell
            } else {
                release(cell)
            }
        }
        cells = moved
        var movedHeaders: [Int: GroupHeaderCell] = [:]
        for (item, header) in headers {
            if let next = Self.index(after: diff, of: item) {
                movedHeaders[next] = header
            } else {
                release(header)
            }
        }
        headers = movedHeaders
        CATransaction.commit()
        relayout(force: true, keeping: anchor)
    }

    /// Where item `index` before `diff` is after it; nil for one it removed. The groups' diffs move nothing.
    static func index(after diff: PhotoListDiff, of index: Int) -> Int? {
        guard !diff.removed.contains(index) else { return nil }
        var position = index - diff.removed.count(in: 0 ..< index)
        for range in diff.inserted.rangeView {
            guard range.lowerBound <= position else { break }
            position += range.count
        }
        return position
    }

    private func groupsChanged(_ change: LibraryGroups.Change) {
        guard !isStale else { return }
        guard isShown else {
            isStale = true
            return
        }
        switch change {
        case .regrouped:
            refill(keeping: screenAnchor())
            follow(model.selection, marking: model.photoSelection)
        case let .items(diff):
            follow(diff, keeping: screenAnchor())
            follow(model.selection, marking: model.photoSelection)
        case let .headers(groups):
            for (item, header) in headers where groups.contains(header.group) {
                place(header: item, header)
            }
        }
    }

    /// Scrolls to where the source's grid was left, once, after its view is restored; false when there's
    /// no such place.
    private func restorePlace() -> Bool {
        let state = model.libraryViews
        guard let top = state.restoredTop else { return false }
        state.restoredTop = nil
        guard let item = item(of: top), item < shownCount else { return false }
        scroll(toTop: gridLayout.frame(forItem: item).minY - gridLayout.spacing)
        return true
    }

    // MARK: - Items

    /// What an item shows: a row of the photos, or grouped, a group's header or a photo.
    private enum Item {
        case photo(row: Int)
        case header(group: Int)
        /// A photo the list no longer has, until the groups follow it.
        case none
    }

    private func content(ofItem index: Int) -> Item {
        guard let sections else { return model.items.indices.contains(index) ? .photo(row: index) : .none }
        guard itemPhotos.indices.contains(index) else { return .none }
        let id = itemPhotos[index]
        guard id >= 0 else { return .header(group: sections.group(ofItem: index)) }
        return model.library.photoList.index(of: id).map { .photo(row: $0) } ?? .none
    }

    /// The row of item `index`'s photo; nil for a header.
    func row(ofItem index: Int) -> Int? {
        if case let .photo(row) = content(ofItem: index) {
            return row
        }
        return nil
    }

    /// The item showing row `row`'s photo; nil when its group is closed.
    private func item(ofRow row: Int) -> Int? {
        guard let shownGroups else { return row }
        let ids = model.library.photoIDs
        return ids.indices.contains(row) ? shownGroups.index(of: ids[row]) : nil
    }

    private func item(of url: URL) -> Int? {
        model.library.index(of: url).flatMap(item(ofRow:))
    }

    /// What stays where it is on screen as the grid lays out again: the active photo when it's on screen,
    /// else the first item on screen, and how far below the top it is.
    private struct ScreenAnchor {
        enum Target {
            case photo(URL)
            case header(Int)
        }

        var target: Target
        var offset: CGFloat
    }

    private func screenAnchor() -> ScreenAnchor? {
        let visible = scrollView.contentView.bounds
        if let selected, let item = item(of: selected), item < shownCount {
            let frame = gridLayout.frame(forItem: item)
            if frame.intersects(visible) {
                return ScreenAnchor(target: .photo(selected), offset: frame.minY - visible.minY)
            }
        }
        guard let first = visibleRows.first, first < shownCount else { return nil }
        let offset = gridLayout.frame(forItem: first).minY - visible.minY
        switch content(ofItem: first) {
        case let .photo(row): return ScreenAnchor(target: .photo(model.items[row].url), offset: offset)
        case let .header(group): return ScreenAnchor(target: .header(group), offset: offset)
        case .none: return nil
        }
    }

    private func item(of anchor: ScreenAnchor) -> Int? {
        switch anchor.target {
        case let .photo(url): item(of: url)
        case let .header(group): shownGroups
            .flatMap { $0.groups.indices.contains(group) ? $0.index(ofHeader: group) : nil }
        }
    }

    // MARK: - Layout and cells

    /// Lays the cells out again for the grid's width, the photos' count, the thumbnail size and the cell
    /// style, keeping `anchor`, or the active photo (or the first on screen), where it was.
    private func relayout(force: Bool = false, keeping given: ScreenAnchor? = nil) {
        let state = model.libraryViews
        var next = gridLayout
        next.width = scrollView.contentView.bounds.width
        next.count = shownCount
        next.size = CGFloat(state.thumbnailSize)
        next.style = state.cellStyle
        next.sections = sections
        next.prepare()
        let height = max(next.contentHeight, scrollView.contentView.bounds.height)
        guard force || next != gridLayout || content.frame.height != height else { return }
        let anchor = given ?? screenAnchor()
        let styled = next.style != gridLayout.style || next.size != gridLayout.size
        gridLayout = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = CGSize(width: next.width, height: height)
        if content.frame.size != size {
            content.frame.size = size
        }
        // One area for any content: one made again as the content's height changes has AppKit update its
        // tracking areas in the next display cycle, milliseconds for each grouping.
        if !hasToolTip {
            content.addToolTip(CGRect(x: 0, y: 0, width: 1e5, height: 1e9), owner: self, userData: nil)
            hasToolTip = true
        }
        if styled {
            texts = [:]
        }
        for (item, cell) in cells where item < shownCount {
            place(item, cell, refresh: styled)
        }
        for (item, header) in headers where item < shownCount {
            place(header: item, header)
        }
        CATransaction.commit()
        if let anchor, let item = item(of: anchor), item < shownCount {
            scroll(toTop: gridLayout.frame(forItem: item).minY - anchor.offset)
        }
        visibleRows = 0 ..< 0
        tile()
    }

    private func scroll(toTop y: CGFloat) {
        let clip = scrollView.contentView
        let top = min(max(y, 0), max(content.frame.height - clip.bounds.height, 0))
        guard abs(clip.bounds.minY - top) >= 0.5 else { return }
        clip.scroll(to: CGPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The cells on screen, half a row above and below them included: those that scrolled out go back to
    /// the pool, and those that scrolled in are cells from it, set to their rows.
    private func tile() {
        guard isShown, !isStale else { return }
        let visible = scrollView.contentView.bounds
        let wanted = gridLayout.items(in: visible.insetBy(dx: 0, dy: -gridLayout.cellSize.height / 2))
            .clamped(to: 0 ..< shownCount)
        let leaving = cells.keys.filter { !wanted.contains($0) }
        let leavingHeaders = headers.keys.filter { !wanted.contains($0) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in leaving {
            if let cell = cells.removeValue(forKey: item) {
                release(cell)
            }
        }
        for item in leavingHeaders {
            if let header = headers.removeValue(forKey: item) {
                release(header)
            }
        }
        for item in wanted where cells[item] == nil && headers[item] == nil {
            if sections?.isHeader(item) == true {
                let header = headerPool.popLast() ?? makeHeader()
                headers[item] = header
                place(header: item, header)
            } else {
                let cell = pool.popLast() ?? makeCell()
                cells[item] = cell
                place(item, cell, refresh: true)
            }
        }
        CATransaction.commit()
        let shown = gridLayout.items(in: visible).clamped(to: 0 ..< shownCount)
        guard shown != visibleRows, !shown.isEmpty else { return }
        visibleRows = shown
        let items = model.items
        let rows = shown.compactMap(row(ofItem:))
        thumbnails.protected = Set(rows.map { items[$0].url })
        for run in Self.runs(of: rows) {
            model.library.prioritize(run)
        }
        if let first = rows.min(), let last = rows.max() {
            model.editRenders.show(first ..< last + 1, in: .grid)
        }
        if let first = shown.first(where: { item in
            row(ofItem: item) != nil && gridLayout.frame(forItem: item).minY >= visible.minY - 1
        }), let row = row(ofItem: first) {
            model.libraryViews.topPhoto = items[row].url
        }
        prefetch(around: shown)
        if gridLayout.style == .expanded {
            requestDetails(for: wanted)
        }
    }

    /// `rows` as runs of rows one after another, for the library's probes, which are in rows' order.
    private static func runs(of rows: [Int]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        for row in rows.sorted() {
            if let last = runs.last, last.upperBound == row {
                runs[runs.count - 1] = last.lowerBound ..< row + 1
            } else if runs.last?.contains(row) != true {
                runs.append(row ..< row + 1)
            }
        }
        return runs
    }

    private func makeCell() -> LibraryGridCell {
        let cell = LibraryGridCell()
        content.layer?.addSublayer(cell.root)
        return cell
    }

    private func makeHeader() -> GroupHeaderCell {
        let header = GroupHeaderCell()
        content.layer?.addSublayer(header.root)
        return header
    }

    private func release(_ cell: LibraryGridCell) {
        if let id = cell.request {
            cell.request = nil
            thumbnails.cancel(id)
        }
        cell.recycle()
        pool.append(cell)
    }

    private func release(_ header: GroupHeaderCell) {
        header.recycle()
        headerPool.append(header)
    }

    private func recycleAll() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for cell in cells.values {
            release(cell)
        }
        cells = [:]
        for header in headers.values {
            release(header)
        }
        headers = [:]
        CATransaction.commit()
        visibleRows = 0 ..< 0
    }

    /// Sets `header` to item `index`, its group's header, where the layout puts it.
    private func place(header: Int, _ cell: GroupHeaderCell) {
        guard case let .header(group) = content(ofItem: header), let shownGroups else { return }
        let groups = model.gridGroups
        let shown = shownGroups.groups[group]
        let picks = groups.picks.indices.contains(group) ? groups.picks[group] : shown.picks
        let frame = gridLayout.frame(forItem: header)
        let detail = GroupHeaderText.detail(count: shown.count, picks: picks)
        cell.show(
            group: group, title: shown.name, detail: detail, open: shownGroups.isOpen(group),
            focused: !shownGroups.isOpen(group) && focusedGroup == group, frame: frame, scale: scale,
        )
        let key = GroupHeaderText.Key(title: shown.name, detail: detail, width: max(frame.width - 34, 1), scale: scale)
        guard cell.textKey != key else { return }
        if let image = headerTexts[key] {
            return cell.setText(image, for: key)
        }
        cell.setText(nil, for: key)
        guard drawingHeaderTexts.insert(key).inserted else { return }
        let space = thumbnails.colorSpace
        model.library.scheduler.submit(.onScreen) {
            let image = GroupHeaderText.render(key, in: space)
            Task { @MainActor [weak self] in self?.drewHeader(key, image) }
        }
    }

    private func drewHeader(_ key: GroupHeaderText.Key, _ image: CGImage?) {
        drawingHeaderTexts.remove(key)
        guard let image else { return }
        if headerTexts.count > 400 {
            let shown = Set(headers.values.compactMap(\.textKey))
            headerTexts = headerTexts.filter { shown.contains($0.key) }
        }
        headerTexts[key] = image
        for header in headers.values where header.textKey == key {
            header.setText(image, for: key)
        }
    }

    /// The group of the active photo when it's in a closed group: its header shows the focus.
    private var focusedGroup: Int? {
        guard let shownGroups, let id = selected.flatMap(model.library.photoID(of:)),
              let group = shownGroups.groups.index(of: id), !shownGroups.isOpen(group)
        else { return nil }
        return group
    }

    /// Sets `cell` to item `index` where the layout puts it: its photo, thumbnail, badges and selection, and,
    /// with `refresh`, its text.
    private func place(_ index: Int, _ cell: LibraryGridCell, refresh: Bool) {
        guard let row = row(ofItem: index) else {
            cell.root.isHidden = true
            return
        }
        let item = model.items[row]
        let edge = edge
        let edit = thumbnails.edit(for: item)
        cell.place(gridLayout.frame(forItem: index), geometry: gridLayout.geometry, scale: scale)
        cell.rendersEdit = model.editRenders.renders(item)
        if cell.item?.url != item.url || cell.row != row {
            if let exact = thumbnails.cached(item, edge: edge) {
                cell.configure(item, row: row, image: exact, edge: edge, edit: edit)
            } else {
                let standIn = thumbnails.standIn(item, below: edge)
                cell.configure(item, row: row, image: standIn?.image, edge: 0, edit: standIn?.edit)
            }
        } else if cell.shownEdit != edit, let exact = thumbnails.cached(item, edge: edge) {
            cell.configure(item, row: row, image: exact, edge: edge, edit: edit)
        } else {
            cell.configure(item, row: row, image: nil, edge: cell.edge)
        }
        let ids = model.library.photoIDs
        cell.select(
            active: item.url == selected,
            inSelection: item.url != selected && ids.indices.contains(row) && marked.contains(ids[row]),
        )
        cell.isMenuTarget = index == menuItem
        cell.root.isHidden = false
        if cell.image == nil || cell.edge < edge || cell.shownEdit != edit {
            requestThumbnail(for: cell, item, edge: edge)
        }
        if refresh || cell.textKey == nil {
            showText(in: cell, item)
        }
    }

    // MARK: - Thumbnails

    private func requestThumbnail(for cell: LibraryGridCell, _ item: LibraryItem, edge: Int) {
        if let id = cell.request {
            cell.request = nil
            thumbnails.cancel(id)
        }
        let edit = thumbnails.edit(for: item)
        let request = thumbnails.request(item, edge: edge, lane: .onScreen) { [weak cell] image in
            guard let cell, cell.item?.url == item.url else { return }
            cell.request = nil
            if let image {
                cell.setImage(image, edge: edge, edit: edit)
            }
        }
        if cell.image == nil || cell.edge < edge || cell.shownEdit != edit, cell.item?.url == item.url {
            cell.request = request
        }
    }

    /// The thumbnails of these photos show another edit: their cells ask for them, or once the grid is
    /// shown again.
    private func editsShown(_ urls: [URL]) {
        let rows = IndexSet(urls.compactMap(model.library.index(of:)))
        guard isShown, !isStale else {
            staleRows.formUnion(rows)
            return
        }
        for item in rows.compactMap(item(ofRow:)) {
            if let cell = cells[item] {
                place(item, cell, refresh: false)
            }
        }
    }

    /// The thumbnails of a screen above and below `shown`, the items on screen, at look-ahead priority; those
    /// further away are no longer asked for.
    private func prefetch(around shown: Range<Int>) {
        let screen = shown.count
        let near = max(shown.lowerBound - screen, 0) ..< min(shown.upperBound + screen, shownCount)
        let items = model.items
        let edge = edge
        var wanted = Set<URL>()
        for index in near where !shown.contains(index) {
            guard let row = row(ofItem: index) else { continue }
            let item = items[row]
            wanted.insert(item.url)
            guard prefetching[item.url] == nil, thumbnails.cached(item, edge: edge) == nil else { continue }
            prefetching[item.url] = thumbnails.request(item, edge: edge, lane: .lookAhead) { [weak self] _ in
                self?.prefetching.removeValue(forKey: item.url)
            }
        }
        for (url, id) in prefetching where !wanted.contains(url) {
            prefetching.removeValue(forKey: url)
            thumbnails.cancel(id)
        }
    }

    // MARK: - Expanded cells' text

    private func showText(in cell: LibraryGridCell, _ item: LibraryItem) {
        guard gridLayout.style == .expanded else { return }
        let details = details.details(for: item.url)
        let lines = GridText.Lines(name: item.name, date: details?.date ?? "", settings: details?.settings ?? "")
        let key = GridText.Key(lines: lines, width: gridLayout.geometry.text.width, scale: scale)
        guard cell.textKey != key || cell.textKey == nil else { return }
        if let image = texts[key] {
            return cell.setText(image, for: key)
        }
        cell.setText(nil, for: key)
        guard drawingTexts.insert(key).inserted else { return }
        let space = thumbnails.colorSpace
        model.library.scheduler.submit(.onScreen) {
            let image = GridText.render(key, in: space)
            Task { @MainActor [weak self] in self?.drew(key, image) }
        }
    }

    private func drew(_ key: GridText.Key, _ image: CGImage?) {
        drawingTexts.remove(key)
        guard let image else { return }
        if texts.count > 400 {
            let shown = Set(cells.values.compactMap(\.textKey))
            texts = texts.filter { shown.contains($0.key) }
        }
        texts[key] = image
        for cell in cells.values where cell.textKey == key {
            cell.setText(image, for: key)
        }
    }

    private func requestDetails(for shown: Range<Int>) {
        let items = model.items
        details.request(shown.compactMap(row(ofItem:)).map { items[$0] }) { [weak self] urls in
            guard let self, gridLayout.style == .expanded else { return }
            let arrived = Set(urls)
            for cell in cells.values {
                if let item = cell.item, arrived.contains(item.url) {
                    showText(in: cell, item)
                }
            }
        }
    }

    // MARK: - Scrolling

    /// What's on screen: its cells, kept in memory, its badges read first, and the next screen's
    /// thumbnails asked for.
    @objc private func scrolled() {
        tile()
        if let band {
            extendBand(to: band.current)
        }
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
        // Grouped, the groups follow the photos that came, went or moved (`LibraryGroups`), and the cells by
        // their photos' IDs meanwhile.
        if shownGroups != nil, !diff.reset {
            return update(diff.updated)
        }
        if diff.reset, shownGroups != nil || model.gridGroups.list != nil {
            refill()
            follow(model.selection, marking: model.photoSelection)
            return
        }
        if diff.reset, model.library.isFiltered {
            refill()
            follow(model.selection, marking: model.photoSelection)
            return
        }
        guard !diff.reset else {
            reload()
            follow(model.selection, marking: model.photoSelection, revealing: !restorePlace())
            return
        }
        if moves, model.library.isFiltered {
            refill()
        } else if moves {
            shownCount = model.items.count
            recycleAll()
            relayout(force: true)
        }
        update(diff.updated)
    }

    /// Redraws the badges of these rows' cells, and their thumbnails if their files changed: for thousands of
    /// rows (culling a whole selection), only the cells on screen are looked at.
    private func update(_ rows: IndexSet) {
        let items = model.items
        let shown = rows.count > cells.count ? cells.keys.filter { row(ofItem: $0).map(rows.contains) == true }
            .sorted() : rows.compactMap(item(ofRow:))
        for index in shown {
            guard let cell = cells[index], let row = row(ofItem: index), items.indices.contains(row) else { continue }
            let rewritten = cell.item?.modified != items[row].modified
            if rewritten {
                cell.setImage(nil, edge: 0)
            }
            place(index, cell, refresh: rewritten)
        }
    }

    // MARK: - Selection

    private func follow(_ selection: URL?, marking photos: PhotoSelection, revealing: Bool = false) {
        let ids = model.library.photoIDs
        for cell in cells.values where ids.indices.contains(cell.row) {
            let url = cell.item?.url
            cell.select(active: url == selection, inSelection: url != selection && photos.contains(ids[cell.row]))
        }
        marked = photos
        let moved = selected != selection
        selected = selection
        let focus = focusedGroup
        if focus != shownFocus {
            shownFocus = focus
            for (item, header) in headers {
                place(header: item, header)
            }
        }
        guard moved || revealing, let selection else { return }
        if let item = item(of: selection), item < shownCount {
            reveal(item)
        } else if let shownGroups, let id = model.library.photoID(of: selection),
                  let group = shownGroups.groups.index(of: id) {
            reveal(shownGroups.index(ofHeader: group))
        }
    }

    /// Scrolls the least that brings item `index` into view.
    private func reveal(_ index: Int) {
        content.scrollToVisible(gridLayout.frame(forItem: index).insetBy(dx: 0, dy: -gridLayout.spacing))
    }

    /// Takes the keyboard, as the Library grid does when it's shown.
    func takeFocus() {
        window?.makeFirstResponder(content)
    }

    // MARK: - Mouse

    fileprivate func pressed(_ event: NSEvent) {
        let point = content.convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(content)
        photoPress = nil
        if event.modifierFlags.contains(.control) {
            if let menu = menu(at: point) {
                NSMenu.popUpContextMenu(menu, with: event, for: content)
            }
            return
        }
        guard let index = gridLayout.item(at: point), index < shownCount else {
            let flags = event.modifierFlags
            band = Band(
                start: point,
                base: flags.contains(.shift) || flags.contains(.command) ? model.photoSelection : nil,
                current: point,
            )
            return
        }
        let row: Int
        switch content(ofItem: index) {
        case let .header(group):
            return model.toggleGroup(group, all: event.modifierFlags.contains(.option))
        case .none: return
        case let .photo(found): row = found
        }
        let url = model.items[row].url
        let frame = gridLayout.frame(forItem: index)
        let plain = event.modifierFlags.isDisjoint(with: [.command, .shift])
        if event.clickCount == 1, plain,
           let target = gridLayout.geometry.target(at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)) {
            cull(target, item: index, row: row, event: event)
        } else if event.clickCount >= 2 {
            model.openInLoupe(url)
        } else if plain, model.isMultiSelecting,
                  model.library.photoID(of: url).map(model.photoSelection.contains) == true {
            // The selection stays for a drag; a click without one selects the photo alone as it ends.
            photoPress = PhotoPress(point: point, url: url, item: index, selectsOnRelease: true)
        } else {
            model.clickInGrid(
                url,
                toggling: event.modifierFlags.contains(.command),
                extending: event.modifierFlags.contains(.shift),
            )
            photoPress = PhotoPress(point: point, url: url, item: index, selectsOnRelease: false)
        }
    }

    /// A click on an expanded cell's stars, flag, mark or label: on the photo, or on the selection when the
    /// photo is in it. A star the photo's rating already ends at clears it, as does the flag of a pick; the
    /// label chip offers the labels.
    private func cull(_ target: GridCellGeometry.Target, item index: Int, row: Int, event: NSEvent) {
        let item = model.items[row]
        let metadata = item.metadata
        switch target {
        case let .star(stars): model.cull(.rating(metadata.rating == stars ? 0 : stars), from: item.url)
        case .flag: model.cull(.flag(metadata.flag == .pick ? nil : .pick), from: item.url)
        case .mark: model.cull(.mark(!metadata.mark), from: item.url)
        case .label:
            menuItem = index
            cells[index]?.isMenuTarget = true
            NSMenu.popUpContextMenu(LibraryGridMenu.labels(for: item.url, model: model), with: event, for: content)
        }
    }

    fileprivate func dragged(_ event: NSEvent) {
        guard !LibraryDrags.follow(event), !dragsPhotos(event), band != nil else { return }
        content.autoscroll(with: event)
        extendBand(to: content.convert(event.locationInWindow, from: nil))
        startAutoscroll()
    }

    fileprivate func released(_ event: NSEvent) {
        guard !LibraryDrags.follow(event) else { return }
        releasePhotoPress()
        guard let band else { return }
        band.timer?.invalidate()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.layer.removeFromSuperlayer()
        CATransaction.commit()
        self.band = nil
    }

    /// The rubber band to `point`: drawn once it has moved a few points, and selecting the cells it meets.
    private func extendBand(to point: CGPoint) {
        guard var band else { return }
        band.current = point
        let rect = CGRect(
            x: min(band.start.x, point.x), y: min(band.start.y, point.y),
            width: abs(point.x - band.start.x), height: abs(point.y - band.start.y),
        )
        if !band.isDrawn, max(rect.width, rect.height) >= 3 {
            band.isDrawn = true
            band.layer.actions = LibraryGridCell.noActions
            band.layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            band.layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            band.layer.borderWidth = 1
            band.layer.zPosition = 10
            content.layer?.addSublayer(band.layer)
        }
        self.band = band
        guard band.isDrawn else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.layer.frame = rect
        CATransaction.commit()
        model.selectInBand(
            gridLayout.items(meeting: rect).filter { $0 < shownCount }.compactMap(row(ofItem:)), adding: band.base,
        )
    }

    /// Scrolls on while the pointer is held above or below the grid.
    private func startAutoscroll() {
        guard band?.timer == nil else { return }
        band?.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollStep() }
        }
    }

    private func autoscrollStep() {
        guard band != nil, let window else { return }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let visible = scrollView.contentView.bounds
        let step: CGFloat = point.y < visible.minY ? point.y - visible.minY : point.y > visible.maxY
            ? point.y - visible.maxY : 0
        guard step != 0 else { return }
        scroll(toTop: visible.minY + max(min(step, 40), -40))
        extendBand(to: CGPoint(x: point.x, y: min(max(point.y, 0), content.frame.height)))
    }

    // MARK: - Context menus

    fileprivate func menu(at point: CGPoint) -> NSMenu? {
        if let index = gridLayout.item(at: point), index < shownCount {
            switch content(ofItem: index) {
            case let .photo(row):
                let menu = LibraryGridMenu.menu(for: model.items[row].url, model: model)
                menuItem = index
                cells[index]?.isMenuTarget = true
                return menu
            case let .header(group): return LibraryGridMenu.menu(forGroup: group, model: model)
            case .none: break
            }
        }
        return LibraryGridMenu.menu(model: model)
    }

    fileprivate func menuClosed() {
        if let index = menuItem {
            cells[index]?.isMenuTarget = false
        }
        menuItem = nil
    }

    func view(_: NSView, stringForToolTip _: NSView.ToolTipTag, point: NSPoint, userData _: UnsafeMutableRawPointer?)
        -> String {
        guard let index = gridLayout.item(at: point), index < shownCount else { return "" }
        switch content(ofItem: index) {
        case let .photo(row): return model.items[row].name
        case .header: return headers[index].map { "\($0.title) (click to open or close, ⌥-click for every group)" } ?? ""
        case .none: return ""
        }
    }

    // MARK: - Accessibility

    /// The cells and headers on screen, for VoiceOver and the regression suite: each a button named for its
    /// photo or its group (`grid.group.<index>`), the same element for a photo or a group while it stays on
    /// screen, so VoiceOver keeps its place.
    fileprivate func accessibleCells() -> [Any] {
        guard let window else { return [] }
        func frame(_ index: Int) -> CGRect {
            window.convertToScreen(content.convert(gridLayout.frame(forItem: index), to: nil))
        }
        var elements: [URL: GridCellElement] = [:]
        var headerElements: [Int: GridCellElement] = [:]
        var children: [(Int, Any)] = cells.compactMap { index, cell -> (Int, Any)? in
            guard let item = cell.item else { return nil }
            let element = self.elements[item.url] ?? GridCellElement(grid: self)
            element.item = index
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(content)
            element.setAccessibilityFrame(frame(index))
            element.setAccessibilityLabel(item.name)
            element.setAccessibilityValue(cell.showsUneditedPreview ? "Unedited preview" : nil)
            element.setAccessibilityIdentifier("grid.\(item.url.lastPathComponent)")
            element.setAccessibilitySelected(cell.isActive || cell.isInSelection)
            elements[item.url] = element
            return (index, element)
        }
        for (index, header) in headers where header.group >= 0 {
            let element = self.headerElements[header.group] ?? GridCellElement(grid: self)
            element.item = index
            element.setAccessibilityRole(.disclosureTriangle)
            element.setAccessibilityParent(content)
            element.setAccessibilityFrame(frame(index))
            element.setAccessibilityLabel(header.accessibilityText)
            element.setAccessibilityValue(header.isOpen ? 1 : 0)
            element.setAccessibilityExpanded(header.isOpen)
            element.setAccessibilityIdentifier("grid.group.\(header.group)")
            headerElements[header.group] = element
            children.append((index, element))
        }
        self.elements = elements
        self.headerElements = headerElements
        return children.sorted { $0.0 < $1.0 }.map(\.1)
    }

    fileprivate func press(item index: Int) {
        guard index < shownCount else { return }
        switch content(ofItem: index) {
        case let .photo(row): model.click(model.items[row].url)
        case let .header(group): model.toggleGroup(group)
        case .none: break
        }
    }
}

/// A cell or a header for VoiceOver: pressing it selects its photo, or opens or closes its group.
private final class GridCellElement: NSAccessibilityElement {
    var item = 0
    weak var grid: LibraryGridView?

    init(grid: LibraryGridView) {
        self.grid = grid
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        let (grid, item) = (grid, item)
        MainActor.assumeIsolated { grid?.press(item: item) }
        return true
    }
}

// MARK: - Keys

/// The keys the grid handles itself, by key code.
private enum GridKey: UInt16 {
    case left = 123, right = 124, down = 125, up = 126, home = 115, end = 119, pageUp = 116, pageDown = 121
    case returnKey = 36, enter = 76, space = 49, zoom = 6

    var opensLoupe: Bool {
        [.returnKey, .enter, .space, .zoom].contains(self)
    }
}

extension LibraryGridView {
    /// The grid's own keys (the key monitor has the shortcuts first); true when the grid took the key.
    fileprivate func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]), shownCount > 0,
              let key = GridKey(rawValue: event.keyCode) else { return false }
        let extending = flags.contains(.shift)
        if key.opensLoupe {
            guard !extending, let selection = model.selection else { return false }
            model.openInLoupe(selection, zoomed: key == .zoom)
            return true
        }
        if let sections {
            let current = model.selection.flatMap(item(of:))
            if let target = target(of: key, from: current, in: sections), target != current,
               let row = row(ofItem: target) {
                model.clickInGrid(model.items[row].url, extending: extending)
            }
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

    /// The photo `key` moves to from item `current`, grouped: ↑ and ↓ to the cell above or below, into the
    /// last or first row of the open group before or after; ← and → the photo before or after, across
    /// headers; Home and End the first and last; Page Up and Page Down a screen's rows. From no photo on
    /// show, the first.
    private func target(of key: GridKey, from current: Int?, in sections: GridSections) -> Int? {
        guard let current, current < shownCount, !sections.isHeader(current) else { return photoItem(from: 0, by: 1) }
        let columns = gridLayout.columns
        func vertical(_ from: Int, by offset: Int) -> Int {
            let group = sections.group(ofItem: from)
            let (first, count) = (sections.firsts[group] + 1, sections.cells[group])
            let cell = from - first
            let column = cell % columns
            if offset < 0, cell >= columns {
                return from - columns
            }
            // From a row above the last, down reaches the last row, even where it's short.
            if offset > 0, cell / columns < (count - 1) / columns {
                return min(from + columns, first + count - 1)
            }
            var next = group + offset
            while next >= 0, next < sections.groups, sections.cells[next] == 0 {
                next += offset
            }
            guard next >= 0, next < sections.groups else { return from }
            let cells = sections.cells[next]
            let start = offset < 0 ? (cells - 1) / columns * columns : 0
            return sections.firsts[next] + 1 + min(start + column, cells - 1)
        }
        let page = max(gridLayout.rows(in: scrollView.contentView.bounds.height) - 1, 1)
        switch key {
        case .left: return photoItem(from: current - 1, by: -1)
        case .right: return photoItem(from: current + 1, by: 1)
        case .up: return vertical(current, by: -1)
        case .down: return vertical(current, by: 1)
        case .home: return photoItem(from: 0, by: 1)
        case .end: return photoItem(from: shownCount - 1, by: -1)
        case .pageUp, .pageDown:
            var target = current
            for _ in 0 ..< page {
                target = vertical(target, by: key == .pageUp ? -1 : 1)
            }
            return target
        case .returnKey, .enter, .space, .zoom: return current
        }
    }

    /// The first photo's item from `start` on, going `step` (1 or -1), past headers.
    private func photoItem(from start: Int, by step: Int) -> Int? {
        var index = start
        while index >= 0, index < shownCount {
            if case .photo = content(ofItem: index) {
                return index
            }
            index += step
        }
        return nil
    }

    /// The cell `key` moves to from cell `current`, of `last + 1`.
    private func target(of key: GridKey, from current: Int, last: Int) -> Int {
        let columns = gridLayout.columns
        let page = max(gridLayout.rows(in: scrollView.contentView.bounds.height) - 1, 1) * columns
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
        case .returnKey, .enter, .space, .zoom: return current
        }
    }
}

extension LibraryGridLayout {
    var geometry: GridCellGeometry {
        GridCellGeometry(size: size, style: style)
    }
}

/// The grid's document view: the cells' layers' host. It takes the keyboard in the Library module and
/// hands its keys, clicks and drags to the grid.
final class LibraryGridContentView: NSView {
    weak var grid: LibraryGridView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(true)
        setAccessibilityRole(.grid)
        setAccessibilityLabel("Grid")
        setAccessibilityIdentifier("library.grid")
        registerForDraggedTypes([LibraryDrags.keyword])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {}

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if grid?.handle(event) != true {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        grid?.pressed(event)
    }

    override func mouseDragged(with event: NSEvent) {
        grid?.dragged(event)
    }

    override func mouseUp(with event: NSEvent) {
        grid?.released(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        grid?.menu(at: convert(event.locationInWindow, from: nil))
    }

    override func didCloseMenu(_: NSMenu, with _: NSEvent?) {
        grid?.menuClosed()
    }

    override func accessibilityChildren() -> [Any]? {
        grid?.accessibleCells()
    }

    // MARK: - A keyword dropped (`LibraryGridView+Drag`)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        grid?.keywordDragged(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        grid?.keywordDragged(sender) ?? []
    }

    override func draggingExited(_: (any NSDraggingInfo)?) {
        grid?.showKeywordTarget(nil)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        grid?.keywordDropped(sender) ?? false
    }

    override func concludeDragOperation(_: (any NSDraggingInfo)?) {
        grid?.showKeywordTarget(nil)
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
        let height = max(grid.content.frame.height - clip.bounds.height, 0)
        clip.scroll(to: CGPoint(x: 0, y: height * fraction))
        grid.scrollView.reflectScrolledClipView(clip)
    }

    /// The grid's thumbnails in memory, in bytes.
    @MainActor public static func memoryUsed(_ view: NSView) -> Int {
        (view as? LibraryGridView)?.thumbnails.memoryUsed ?? 0
    }

    /// How many times the grid in `window` has reloaded every cell.
    @MainActor public static func reloads(in window: NSWindow) -> Int? {
        func find(_ view: NSView) -> LibraryGridView? {
            (view as? LibraryGridView) ?? view.subviews.lazy.compactMap(find).first
        }
        return (window.contentView?.superview ?? window.contentView).flatMap(find)?.reloads
    }

    /// What a click sets in an expanded cell.
    public enum CellPart: Sendable {
        case star(Int), flag, mark
    }

    /// Where `part` of an expanded cell `size` points wide is, 0 ... 1 across and down the cell.
    public static func point(of part: CellPart, size: Double) -> CGPoint {
        let geometry = GridCellGeometry(size: CGFloat(size), style: .expanded)
        let cell = geometry.cellSize
        let point = switch part {
        case let .star(stars):
            CGPoint(
                x: geometry.rating.x + 4 + 7 * CGFloat(stars - 1) + 3.5,
                y: cell.height - GridCellGeometry.footerHeight / 2,
            )
        case .flag: geometry.flag
        case .mark: geometry.mark
        }
        return CGPoint(x: point.x / cell.width, y: point.y / cell.height)
    }
}
