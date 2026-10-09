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
///   until it's released without a drag. While the painter is out, a press and a drag paint the photos they
///   reach rather than selecting them (`LibraryGridView+Painter`).
/// - The thumbnail size (= and -), the cell style (J) and a context menu on photos and between them;
///   each source's size, style, place and selection are remembered (`LibraryViewState`).
/// - Grouped (LIB-41, `LibraryGroups`), each group has a header across the grid, a click on it opening or
///   closing the group and an ⌥-click every group; the grid follows the groups' diffs, moving the cells
///   that stay and keeping the selection and the active photo, and its keys go through the photos on show
///   in its order.
/// - Stacks (LIB-28, `LibraryStacks`) are closed, each one cell with its count, or a raw and its JPEG one
///   photo marked with the other's extension, in groups too; a click on the badge opens or closes it, and the
///   grid follows the stacks' diffs as it follows the groups'. A closed stack's cell selects all its photos.
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
    private var stacksObservation: LibraryObservation?
    private var proposalsObservation: LibraryObservation?
    /// The proposals of the Library Health check shown, which its cells draw (LIB-40).
    lazy var proposals = model.healthProposals
    private var trackers: [Tracker] = []
    /// The cells on screen, by item (a row of the photos, or grouped, a header or a photo), and those out of
    /// sight waiting to be used again.
    private(set) var cells: [Int: LibraryGridCell] = [:]
    private var pool: [LibraryGridCell] = []
    /// The groups as last followed, and their sections; nil while ungrouped. Items are read from these.
    private(set) var shownGroups: GroupedList?
    private(set) var sections: GridSections?
    /// The stacks as last followed while ungrouped; nil while grouped, and for a source without stacks.
    private(set) var shownStacks: StackedList?
    /// Each item's photo, -1 for a header, so the items on and near the screen are read without the groups' or the
    /// stacks' tree.
    private var itemPhotos = ContiguousArray<Int64>()
    /// The headers on screen, by item, and those waiting to be used again.
    private(set) var headers: [Int: GroupHeaderCell] = [:]
    private var headerPool: [GroupHeaderCell] = []
    var prefetching: [URL: UInt64] = [:]
    /// The selection as last followed. Cells are drawn from these, not from the model, which can be a turn
    /// ahead.
    private var selected: URL?
    private var marked = PhotoSelection()
    /// The photos the grid has: the library's count when it last reloaded or changed.
    private(set) var shownCount = 0
    /// Photos came or went while the grid was hidden, or it hasn't loaded yet.
    var isStale = true
    /// Rows whose badges changed while the grid was hidden.
    var staleRows = IndexSet()
    /// The cells on screen when the grid last scrolled.
    private var visibleRows = 0 ..< 0
    /// Times every cell was reloaded: once the grid has been shown, a module switch reloads nothing.
    private(set) var reloads = 0
    /// Whether the grid was on screen when it last looked.
    var wasShown = false
    var texts: [GridText.Key: CGImage] = [:]
    var drawingTexts: Set<GridText.Key> = []
    private var headerTexts: [GroupHeaderText.Key: CGImage] = [:]
    private var drawingHeaderTexts: Set<GroupHeaderText.Key> = []
    /// The group whose header showed the focus when the selection was last followed.
    private var shownFocus: Int?
    /// The content's tooltip area is made.
    private var hasToolTip = false
    /// A rubber band being drawn: where it started, and the selection it adds to (with ⇧ or ⌘).
    var band: Band?
    /// A press on a photo, which a drag takes along, and where a keyword dragged over the grid would land
    /// (`LibraryGridView+Drag`).
    var photoPress: PhotoPress?
    var keywordTarget: KeywordTarget?
    /// Where the painter's stroke last reached (`LibraryGridView+Painter`).
    var lastPaint: CGPoint?
    /// The item whose context menu is open.
    var menuItem: Int?
    /// The frames of the focus stacks the app suggests merging (`EditorModel.stackSuggestions`), as last followed.
    var suggestedFrames: Set<URL> = []
    /// The cells' accessibility elements, by photo, and the headers', by group, as last asked for.
    var elements: [URL: GridCellElement] = [:]
    var headerElements: [Int: GridCellElement] = [:]

    struct Band {
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

    var isShown: Bool {
        isInShownModule(model)
    }

    var scale: CGFloat {
        window?.backingScaleFactor ?? 2
    }

    /// The long edge a cell's thumbnail is decoded at, for its image's size on this screen.
    var edge: Int {
        GridThumbnails.edge(forPixels: gridLayout.geometry.image.width * scale)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = nil
        editObservation = nil
        groupsObservation = nil
        stacksObservation = nil
        proposalsObservation = nil
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
        stacksObservation = model.gridStacks.observe { [weak self] change in self?.stacksChanged(change) }
        proposalsObservation = proposals.observe { [weak self] in self?.proposalsChanged() }
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
            // The painter's brush over the grid while it's out.
            Tracker { [weak self] in
                guard let self else { return }
                _ = model.keywordPainter.isOn
                self.window?.invalidateCursorRects(for: content)
            },
            // The focus stacks suggested, marked on their frames.
            Tracker { [weak self] in
                guard let self else { return }
                let frames = Set(model.stackSuggestions.flatMap(\.frames))
                guard frames != suggestedFrames else { return }
                suggestedFrames = frames
                guard isShown, wasShown, !isStale else { return }
                for (item, cell) in cells {
                    place(item, cell, refresh: false)
                }
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
}

extension LibraryGridView {
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
        followItems()
        recycleAll()
        relayout(force: true)
    }

    /// The groups, or ungrouped the stacks, as the model has them now, and the items' count with them. Stacks found
    /// for another source than the one shown are left out until it's stacked.
    private func followItems() {
        shownGroups = model.gridGroups.list
        sections = shownGroups.map(GridSections.init)
        let source = model.library.photoList.source
        shownStacks = shownGroups == nil ? model.gridStacks.list.flatMap { $0.list.source == source ? $0 : nil } : nil
        shownCount = shownGroups?.count ?? shownStacks?.count ?? model.items.count
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
        } else if let shownStacks {
            photos.reserveCapacity(shownStacks.count)
            for cell in shownStacks {
                photos.append(cell)
            }
        }
        itemPhotos = photos
    }

    /// The same source's photos in another order or another number (a filter, LIB-18), or grouped or stacked
    /// afresh: cells on screen keep their layers, and those whose item shows another photo now take it. Grouped or
    /// stacked, a photo still on show keeps its cell, which moves to its item.
    private func refill(keeping anchor: ScreenAnchor? = nil) {
        let photos = cells.compactMap { item, cell in cell.item.map { (item, cell, $0.url) } }
        followItems()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if shownGroups != nil || shownStacks != nil {
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

    /// Groups or stacks opened or closed: the cells and headers that stay move to their items after `diff`, those
    /// it removed go back to the pool, and the headers and cells it updated show their group or stack as it is now.
    private func follow(_ diff: PhotoListDiff, keeping anchor: ScreenAnchor?) {
        followItems()
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

    /// The stacks changed: ungrouped, the grid follows them as it follows the groups; grouped, the groups follow.
    private func stacksChanged(_ change: LibraryStacks.Change) {
        guard !isStale, shownGroups == nil, model.gridGroups.list == nil else { return }
        guard isShown else {
            isStale = true
            return
        }
        switch change {
        case .restacked: refill(keeping: screenAnchor())
        case let .items(diff): follow(diff, keeping: screenAnchor())
        }
        follow(model.selection, marking: model.photoSelection)
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
    enum Item {
        case photo(row: Int)
        case header(group: Int)
        /// A photo the list no longer has, until the groups follow it.
        case none
    }

    func content(ofItem index: Int) -> Item {
        guard sections != nil || shownStacks != nil else {
            return model.items.indices.contains(index) ? .photo(row: index) : .none
        }
        guard itemPhotos.indices.contains(index) else { return .none }
        let id = itemPhotos[index]
        guard id >= 0 else { return sections.map { .header(group: $0.group(ofItem: index)) } ?? .none }
        return model.library.photoList.index(of: id).map { .photo(row: $0) } ?? .none
    }

    /// The photo item `index` shows, by its ID; nil for a header.
    func photoID(ofItem index: Int) -> Int64? {
        guard sections != nil || shownStacks != nil else {
            let ids = model.library.photoIDs
            return ids.indices.contains(index) ? ids[index] : nil
        }
        return itemPhotos.indices.contains(index) && itemPhotos[index] >= 0 ? itemPhotos[index] : nil
    }

    /// The stacks the cells show, grouped or not.
    var cellStacks: StackedList? {
        shownGroups?.stacked ?? shownStacks
    }

    /// The photos item `index`'s cell stands for, by their IDs and URLs: every photo of a closed stack, else its
    /// own; none for a header.
    func photos(standingFor index: Int) -> [(id: Int64, url: URL)] {
        guard let id = photoID(ofItem: index) else { return [] }
        let library = model.library
        let stacked = cellStacks?.photos(of: id) ?? []
        return (stacked.isEmpty ? [id] : stacked)
            .compactMap { photo in library.url(ofPhoto: photo).map { (photo, $0) } }
    }

    /// The row of item `index`'s photo; nil for a header.
    func row(ofItem index: Int) -> Int? {
        if case let .photo(row) = content(ofItem: index) {
            return row
        }
        return nil
    }

    /// The item showing row `row`'s photo; nil when its group or its stack is closed.
    func item(ofRow row: Int) -> Int? {
        guard shownGroups != nil || shownStacks != nil else { return row }
        let ids = model.library.photoIDs
        guard ids.indices.contains(row) else { return nil }
        return shownGroups?.index(of: ids[row]) ?? shownStacks?.index(of: ids[row])
    }

    func item(of url: URL) -> Int? {
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
        case let .photo(row):
            return model.library.items.row(row).map { ScreenAnchor(target: .photo($0.url), offset: offset) }
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
        visibleRows = 0 ..< 0
        if let anchor, let item = item(of: anchor), item < shownCount {
            // A scroll tiles as the clip view reports it (`scrolled`).
            scroll(toTop: gridLayout.frame(forItem: item).minY - anchor.offset)
        }
        if visibleRows.isEmpty {
            tile()
        }
    }

    func scroll(toTop y: CGFloat) {
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
        thumbnails.protected = Set(rows.compactMap { items.row($0)?.url })
        for run in Self.runs(of: rows) {
            model.library.prioritize(run)
        }
        if let first = rows.min(), let last = rows.max() {
            model.editRenders.show(first ..< last + 1, in: .grid)
            model.library.showRows(first ..< last + 1, in: "grid")
        }
        if let first = shown.first(where: { item in
            row(ofItem: item) != nil && gridLayout.frame(forItem: item).minY >= visible.minY - 1
        }), let row = row(ofItem: first), let item = items.row(row) {
            model.libraryViews.topPhoto = item.url
        }
        prefetch(around: shown)
        if gridLayout.style == .expanded {
            requestDetails(for: wanted)
        }
    }

    /// `rows` as runs of rows one after another, for the library's probes, which are in rows' order.
    static func runs(of rows: [Int]) -> [Range<Int>] {
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
    func place(header: Int, _ cell: GroupHeaderCell) {
        guard case let .header(group) = content(ofItem: header), let shownGroups else { return }
        let groups = model.gridGroups
        let shown = shownGroups.groups
        let picks = groups.picks.indices.contains(group) ? groups.picks[group] : shown.picks(ofGroup: group)
        let frame = gridLayout.frame(forItem: header)
        let (title, detail) = (
            shown.name(ofGroup: group),
            GroupHeaderText.detail(count: shown.count(ofGroup: group), picks: picks),
        )
        cell.show(
            group: group, title: title, detail: detail, open: shownGroups.isOpen(group),
            focused: !shownGroups.isOpen(group) && focusedGroup == group, frame: frame, scale: scale,
        )
        let key = GroupHeaderText.Key(title: title, detail: detail, width: max(frame.width - 34, 1), scale: scale)
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
    func place(_ index: Int, _ cell: LibraryGridCell, refresh: Bool) {
        // A large source's row not read yet shows once it is; a closed stack's photos are read with its cell.
        if let id = photoID(ofItem: index), let stacked = cellStacks?.photos(of: id), !stacked.isEmpty {
            model.library.askForRows(ofPhotos: stacked)
        }
        guard let row = row(ofItem: index), let item = model.library.row(at: row) else {
            cell.root.isHidden = true
            return
        }
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
        } else if cell.item != item {
            cell.configure(item, row: row, image: nil, edge: cell.edge)
        }
        let ids = model.library.photoIDs
        cell.select(
            active: item.url == selected,
            inSelection: item.url != selected && ids.indices.contains(row) && marked.contains(ids[row]),
        )
        cell.stackBadges = cellStacks.flatMap { stacks in
            photoID(ofItem: index).map { model.stackBadges(of: $0, in: stacks) }
        } ?? (nil, nil)
        cell.isFocusSuggested = suggestedFrames.contains(item.url)
        cell.healthMark = proposals.mark(for: item.url)
        cell.isMenuTarget = index == menuItem
        cell.root.isHidden = false
        if cell.image == nil || cell.edge < edge || cell.shownEdit != edit {
            requestThumbnail(for: cell, item, edge: edge)
        }
        if refresh || cell.textKey == nil {
            showText(in: cell, item)
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
                staleRows.formUnion(diff.redrawn)
            }
            return
        }
        // Grouped or stacked, the groups or the stacks follow the photos that came, went or moved (`LibraryGroups`,
        // `LibraryStacks`), and the cells by their photos' IDs meanwhile.
        if shownGroups != nil || shownStacks != nil, !diff.reset {
            return update(diff.redrawn)
        }
        if diff.reset, shownGroups != nil || model.gridGroups.list != nil || shownStacks != nil {
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
        update(diff.redrawn)
    }

    /// Redraws the badges of these rows' cells, and their thumbnails if their files changed: for thousands of
    /// rows (culling a whole selection), only the cells on screen are looked at.
    private func update(_ rows: IndexSet) {
        let items = model.items
        let shown = rows.count > cells.count ? cells.keys.filter { row(ofItem: $0).map(rows.contains) == true }
            .sorted() : rows.compactMap(item(ofRow:))
        for index in shown {
            guard let cell = cells[index], let row = row(ofItem: index), items.indices.contains(row),
                  let item = items.row(row)
            else { continue }
            let rewritten = cell.item?.modified != item.modified
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
        } else if let id = model.library.photoID(of: selection), let stacks = cellStacks,
                  let cell = stacks.cell(for: id), let item = item(of: cell), item < shownCount {
            reveal(item)
        } else if let shownGroups, let id = model.library.photoID(of: selection),
                  let group = shownGroups.groups.index(of: id) {
            reveal(shownGroups.index(ofHeader: group))
        }
    }

    /// The item showing photo `id`'s cell; nil when it has none on show.
    func item(of id: Int64) -> Int? {
        model.library.photoList.index(of: id).flatMap(item(ofRow:))
    }

    /// Scrolls the least that brings item `index` into view.
    private func reveal(_ index: Int) {
        content.scrollToVisible(gridLayout.frame(forItem: index).insetBy(dx: 0, dy: -gridLayout.spacing))
    }

    /// Takes the keyboard, as the Library grid does when it's shown.
    func takeFocus() {
        window?.makeFirstResponder(content)
    }
}
