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
/// - The thumbnail size (= and -), the cell style (J) and a context menu on photos and between them;
///   each source's size, style, place and selection are remembered (`LibraryViewState`).
/// - Out of sight (Develop or the loupe is shown) it does nothing: changes to the photos wait, and it
///   reloads once shown.
final class LibraryGridView: NSView, NSViewToolTipOwner {
    let scrollView = NSScrollView()
    let content = LibraryGridContentView()
    private(set) var gridLayout = LibraryGridLayout()
    private let model: EditorModel
    let thumbnails: GridThumbnails
    let details: PhotoDetailsCache
    private var observation: LibraryObservation?
    private var editObservation: LibraryObservation?
    private var trackers: [Tracker] = []
    /// The cells on screen, by row, and those out of sight waiting to be used again.
    private(set) var cells: [Int: LibraryGridCell] = [:]
    private var pool: [LibraryGridCell] = []
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
    /// A rubber band being drawn: where it started, and the selection it adds to (with ⇧ or ⌘).
    private var band: Band?
    /// The row whose context menu is open.
    private var menuRow: Int?
    /// The cells' accessibility elements, by photo, as last asked for.
    private var elements: [URL: GridCellElement] = [:]

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
        shownCount = model.items.count
        recycleAll()
        relayout(force: true)
    }

    /// The same source's photos in another order or another number (a filter, LIB-18): cells on screen
    /// keep their layers, and those whose row shows another photo now take it.
    private func refill() {
        shownCount = model.items.count
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for row in cells.keys where row >= shownCount {
            if let cell = cells.removeValue(forKey: row) {
                release(cell)
            }
        }
        CATransaction.commit()
        relayout(force: true)
    }

    /// Scrolls to where the source's grid was left, once, after its view is restored; false when there's
    /// no such place.
    private func restorePlace() -> Bool {
        let state = model.libraryViews
        guard let top = state.restoredTop else { return false }
        state.restoredTop = nil
        guard let row = model.library.index(of: top), row < shownCount else { return false }
        scroll(toTop: gridLayout.frame(forItem: row).minY - gridLayout.spacing)
        return true
    }

    // MARK: - Layout and cells

    /// Lays the cells out again for the grid's width, the photos' count, the thumbnail size and the cell
    /// style, keeping the active photo (or the first on screen) where it was.
    private func relayout(force: Bool = false) {
        let state = model.libraryViews
        var next = gridLayout
        next.width = scrollView.contentView.bounds.width
        next.count = shownCount
        next.size = CGFloat(state.thumbnailSize)
        next.style = state.cellStyle
        let height = max(next.contentHeight, scrollView.contentView.bounds.height)
        guard force || next != gridLayout || content.frame.height != height else { return }
        let visible = scrollView.contentView.bounds
        let anchor = selected.flatMap(model.library.index(of:)).flatMap { row in
            gridLayout.frame(forItem: row).intersects(visible) ? row : nil
        } ?? visibleRows.first
        let offset = anchor.map { gridLayout.frame(forItem: $0).minY - visible.minY }
        let styled = next.style != gridLayout.style || next.size != gridLayout.size
        gridLayout = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame.size = CGSize(width: next.width, height: height)
        content.removeAllToolTips()
        content.addToolTip(content.bounds, owner: self, userData: nil)
        if styled {
            texts = [:]
        }
        for (row, cell) in cells where row < shownCount {
            place(row, cell, refresh: styled)
        }
        CATransaction.commit()
        if let anchor, let offset, anchor < shownCount {
            scroll(toTop: gridLayout.frame(forItem: anchor).minY - offset)
        }
        visibleRows = 0 ..< 0
        tile()
    }

    private func scroll(toTop y: CGFloat) {
        let clip = scrollView.contentView
        let top = min(max(y, 0), max(content.frame.height - clip.bounds.height, 0))
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for row in leaving {
            if let cell = cells.removeValue(forKey: row) {
                release(cell)
            }
        }
        for row in wanted where cells[row] == nil {
            let cell = pool.popLast() ?? makeCell()
            cells[row] = cell
            place(row, cell, refresh: true)
        }
        CATransaction.commit()
        let rows = gridLayout.items(in: visible).clamped(to: 0 ..< shownCount)
        guard rows != visibleRows, !rows.isEmpty else { return }
        visibleRows = rows
        let items = model.items
        thumbnails.protected = Set(rows.map { items[$0].url })
        model.library.prioritize(rows)
        model.editRenders.show(rows, in: .grid)
        if let first = rows.first(where: { gridLayout.frame(forItem: $0).minY >= visible.minY - 1 }) {
            model.libraryViews.topPhoto = items[first].url
        }
        prefetch(around: rows)
        if gridLayout.style == .expanded {
            requestDetails(for: wanted)
        }
    }

    private func makeCell() -> LibraryGridCell {
        let cell = LibraryGridCell()
        content.layer?.addSublayer(cell.root)
        return cell
    }

    private func release(_ cell: LibraryGridCell) {
        if let id = cell.request {
            cell.request = nil
            thumbnails.cancel(id)
        }
        cell.recycle()
        pool.append(cell)
    }

    private func recycleAll() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for cell in cells.values {
            release(cell)
        }
        cells = [:]
        CATransaction.commit()
        visibleRows = 0 ..< 0
    }

    /// Sets `cell` to row `row` where the layout puts it: its photo, thumbnail, badges and selection, and,
    /// with `refresh`, its text.
    private func place(_ row: Int, _ cell: LibraryGridCell, refresh: Bool) {
        guard model.items.indices.contains(row) else { return }
        let item = model.items[row]
        let edge = edge
        let edit = thumbnails.edit(for: item)
        cell.place(gridLayout.frame(forItem: row), geometry: gridLayout.geometry, scale: scale)
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
        cell.isMenuTarget = row == menuRow
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
        for row in rows {
            if let cell = cells[row] {
                place(row, cell, refresh: false)
            }
        }
    }

    /// The thumbnails of a screen above and below `rows`, at look-ahead priority; those further away are
    /// no longer asked for.
    private func prefetch(around rows: Range<Int>) {
        let screen = rows.count
        let near = max(rows.lowerBound - screen, 0) ..< min(rows.upperBound + screen, shownCount)
        let items = model.items
        let edge = edge
        var wanted = Set<URL>()
        for row in near where !rows.contains(row) {
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

    private func requestDetails(for rows: Range<Int>) {
        let items = model.items
        details.request(rows.map { items[$0] }) { [weak self] urls in
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
        let shown = rows.count > cells.count ? cells.keys.filter(rows.contains).sorted() : Array(rows)
        for row in shown where items.indices.contains(row) {
            guard let cell = cells[row] else { continue }
            let rewritten = cell.item?.modified != items[row].modified
            if rewritten {
                cell.setImage(nil, edge: 0)
            }
            place(row, cell, refresh: rewritten)
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
        guard moved || revealing, let selection, let row = model.library.index(of: selection), row < shownCount
        else { return }
        reveal(row)
    }

    /// Scrolls the least that brings cell `row` into view.
    private func reveal(_ row: Int) {
        content.scrollToVisible(gridLayout.frame(forItem: row).insetBy(dx: 0, dy: -gridLayout.spacing))
    }

    /// Takes the keyboard, as the Library grid does when it's shown.
    func takeFocus() {
        window?.makeFirstResponder(content)
    }

    // MARK: - Mouse

    fileprivate func pressed(_ event: NSEvent) {
        let point = content.convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(content)
        if event.modifierFlags.contains(.control) {
            if let menu = menu(at: point) {
                NSMenu.popUpContextMenu(menu, with: event, for: content)
            }
            return
        }
        guard let row = gridLayout.item(at: point), row < shownCount else {
            let flags = event.modifierFlags
            band = Band(
                start: point,
                base: flags.contains(.shift) || flags.contains(.command) ? model.photoSelection : nil,
                current: point,
            )
            return
        }
        let url = model.items[row].url
        let frame = gridLayout.frame(forItem: row)
        if event.clickCount == 1, event.modifierFlags.isDisjoint(with: [.command, .shift]),
           let target = gridLayout.geometry.target(at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)) {
            cull(target, row: row, event: event)
        } else if event.clickCount >= 2 {
            model.openInLoupe(url)
        } else {
            model.click(
                url,
                toggling: event.modifierFlags.contains(.command),
                extending: event.modifierFlags.contains(.shift),
            )
        }
    }

    /// A click on an expanded cell's stars, flag, mark or label: on the photo, or on the selection when the
    /// photo is in it. A star the photo's rating already ends at clears it, as does the flag of a pick; the
    /// label chip offers the labels.
    private func cull(_ target: GridCellGeometry.Target, row: Int, event: NSEvent) {
        let item = model.items[row]
        let metadata = item.metadata
        switch target {
        case let .star(stars): model.cull(.rating(metadata.rating == stars ? 0 : stars), from: item.url)
        case .flag: model.cull(.flag(metadata.flag == .pick ? nil : .pick), from: item.url)
        case .mark: model.cull(.mark(!metadata.mark), from: item.url)
        case .label:
            menuRow = row
            cells[row]?.isMenuTarget = true
            NSMenu.popUpContextMenu(LibraryGridMenu.labels(for: item.url, model: model), with: event, for: content)
        }
    }

    fileprivate func dragged(_ event: NSEvent) {
        guard band != nil else { return }
        content.autoscroll(with: event)
        extendBand(to: content.convert(event.locationInWindow, from: nil))
        startAutoscroll()
    }

    fileprivate func released(_: NSEvent) {
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
        model.selectInBand(gridLayout.items(meeting: rect).filter { $0 < shownCount }, adding: band.base)
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
        if let row = gridLayout.item(at: point), row < shownCount {
            let menu = LibraryGridMenu.menu(for: model.items[row].url, model: model)
            menuRow = row
            cells[row]?.isMenuTarget = true
            return menu
        }
        return LibraryGridMenu.menu(model: model)
    }

    fileprivate func menuClosed() {
        if let row = menuRow {
            cells[row]?.isMenuTarget = false
        }
        menuRow = nil
    }

    func view(_: NSView, stringForToolTip _: NSView.ToolTipTag, point: NSPoint, userData _: UnsafeMutableRawPointer?)
        -> String {
        guard let row = gridLayout.item(at: point), row < shownCount else { return "" }
        return model.items[row].name
    }

    // MARK: - Accessibility

    /// The cells on screen, for VoiceOver and the regression suite: each a button named for its photo,
    /// the same element for a photo while it stays on screen, so VoiceOver keeps its place.
    fileprivate func accessibleCells() -> [Any] {
        guard let window else { return [] }
        var elements: [URL: GridCellElement] = [:]
        let children = cells.sorted { $0.key < $1.key }.compactMap { row, cell -> Any? in
            guard let item = cell.item else { return nil }
            let element = self.elements[item.url] ?? GridCellElement(grid: self)
            element.row = row
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(content)
            element.setAccessibilityFrame(window.convertToScreen(content.convert(
                gridLayout.frame(forItem: row),
                to: nil,
            )))
            element.setAccessibilityLabel(item.name)
            element.setAccessibilityValue(cell.showsUneditedPreview ? "Unedited preview" : nil)
            element.setAccessibilityIdentifier("grid.\(item.url.lastPathComponent)")
            element.setAccessibilitySelected(cell.isActive || cell.isInSelection)
            elements[item.url] = element
            return element
        }
        self.elements = elements
        return children
    }

    fileprivate func press(row: Int) {
        guard row < shownCount else { return }
        model.click(model.items[row].url)
    }
}

/// A cell for VoiceOver: pressing it selects its photo.
private final class GridCellElement: NSAccessibilityElement {
    var row = 0
    weak var grid: LibraryGridView?

    init(grid: LibraryGridView) {
        self.grid = grid
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        let (grid, row) = (grid, row)
        MainActor.assumeIsolated { grid?.press(row: row) }
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
