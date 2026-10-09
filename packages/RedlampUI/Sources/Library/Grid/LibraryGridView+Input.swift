import AppKit
import QuartzCore
import RedlampDesign
import RedlampDocument
import RedlampLibrary

extension LibraryGridView {
    // MARK: - Mouse

    func pressed(_ event: NSEvent) {
        let point = content.convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(content)
        photoPress = nil
        if event.modifierFlags.contains(.control) {
            if let menu = menu(at: point) {
                NSMenu.popUpContextMenu(menu, with: event, for: content)
            }
            return
        }
        if paints(event, at: point) {
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
        guard let url = model.library.items.row(row)?.url else { return }
        let frame = gridLayout.frame(forItem: index)
        let plain = event.modifierFlags.isDisjoint(with: [.command, .shift])
        let inCell = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        if event.clickCount == 1, plain, let pair = cells[index]?.stackBadge(at: inCell),
           let id = photoID(ofItem: index) {
            model.gridStacks.toggle(badgeOf: id, pair: pair)
        } else if event.clickCount == 1, plain, let target = gridLayout.geometry.target(at: inCell) {
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
    func cull(_ target: GridCellGeometry.Target, item index: Int, row: Int, event: NSEvent) {
        guard let item = model.library.items.row(row) else { return }
        let metadata = item.metadata
        switch target {
        case let .star(stars): model.cull(.rating(metadata.rating == stars ? 0 : stars), fromCell: item.url)
        case .flag: model.cull(.flag(metadata.flag == .pick ? nil : .pick), fromCell: item.url)
        case .mark: model.cull(.mark(!metadata.mark), fromCell: item.url)
        case .label:
            menuItem = index
            cells[index]?.isMenuTarget = true
            NSMenu.popUpContextMenu(LibraryGridMenu.labels(for: item.url, model: model), with: event, for: content)
        }
    }

    func dragged(_ event: NSEvent) {
        guard !LibraryDrags.follow(event), !paintsAlong(event), !dragsPhotos(event), band != nil else { return }
        content.autoscroll(with: event)
        extendBand(to: content.convert(event.locationInWindow, from: nil))
        startAutoscroll()
    }

    func released(_ event: NSEvent) {
        guard !LibraryDrags.follow(event), !endsStroke() else { return }
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
    func extendBand(to point: CGPoint) {
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
    func startAutoscroll() {
        guard band?.timer == nil else { return }
        band?.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollStep() }
        }
    }

    func autoscrollStep() {
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

    func menu(at point: CGPoint) -> NSMenu? {
        if let index = gridLayout.item(at: point), index < shownCount {
            switch content(ofItem: index) {
            case let .photo(row):
                guard let url = model.library.items.row(row)?.url else { break }
                let menu = LibraryGridMenu.menu(for: url, model: model)
                menuItem = index
                cells[index]?.isMenuTarget = true
                return menu
            case let .header(group): return LibraryGridMenu.menu(forGroup: group, model: model)
            case .none: break
            }
        }
        return LibraryGridMenu.menu(model: model)
    }

    func menuClosed() {
        if let index = menuItem {
            cells[index]?.isMenuTarget = false
        }
        menuItem = nil
    }

    func view(_: NSView, stringForToolTip _: NSView.ToolTipTag, point: NSPoint, userData _: UnsafeMutableRawPointer?)
        -> String {
        guard let index = gridLayout.item(at: point), index < shownCount else { return "" }
        switch content(ofItem: index) {
        case let .photo(row):
            guard let item = model.library.items.row(row) else { return "" }
            return item.name + (stackDescription(ofItem: index).map { ", \($0)" } ?? "")
                + (proposals.mark(for: item.url).map { ": \($0.sentence)" } ?? "")
        case .header: return headers[index].map { "\($0.title) (click to open or close, ⌥-click for every group)" } ?? ""
        case .none: return ""
        }
    }

    /// What item `index`'s cell says of the stacks it's the first cell of, and of a focus stack suggested:
    /// `a stack of 9, closed`.
    func stackDescription(ofItem index: Int) -> String? {
        var parts: [String] = []
        if let row = row(ofItem: index), let url = model.library.items.row(row)?.url, suggestedFrames.contains(url) {
            parts.append("suggested for a focus stack")
        }
        guard let stacks = cellStacks, let id = photoID(ofItem: index) else {
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        }
        let (stack, pair) = stacks.badges(of: id)
        if let stack {
            parts.append("a stack of \(stack.count), \(stack.isOpen ? "open" : "closed")")
        }
        if let pair {
            parts
                .append(
                    "\(pair.count == 2 ? "a pair" : "\(pair.count) files as one photo"), \(pair.isOpen ? "open" : "closed")",
                )
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    // MARK: - Accessibility

    /// The cells and headers on screen, for VoiceOver and the regression suite: each a button named for its
    /// photo or its group (`grid.group.<index>`), the same element for a photo or a group while it stays on
    /// screen, so VoiceOver keeps its place.
    func accessibleCells() -> [Any] {
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
            let value = [
                cell.showsUneditedPreview ? "Unedited preview" : nil, stackDescription(ofItem: index),
                cell.healthMark.map { "\($0.word): \($0.sentence)" },
            ].compactMap(\.self).joined(separator: "; ")
            element.setAccessibilityValue(value.isEmpty ? nil : value)
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

    func press(item index: Int) {
        guard index < shownCount else { return }
        switch content(ofItem: index) {
        case let .photo(row): clickRow(row, extending: false)
        case let .header(group): model.toggleGroup(group)
        case .none: break
        }
    }
}

/// A cell or a header for VoiceOver: pressing it selects its photo, or opens or closes its group.
final class GridCellElement: NSAccessibilityElement {
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
    func handle(_ event: NSEvent) -> Bool {
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
                clickRow(row, extending: extending)
            }
            return true
        }
        let last = shownCount - 1
        let current = model.selection.flatMap(item(of:))
        let target = current.map { self.target(of: key, from: $0, last: last) } ?? 0
        if (0 ... last).contains(target), target != current, let row = row(ofItem: target) {
            clickRow(row, extending: extending)
        }
        return true
    }

    /// Clicks row `row`'s photo, as a key that moves to it does: once it's read, for a large source's row.
    func clickRow(_ row: Int, extending: Bool) {
        let library = model.library
        guard library.photoIDs.indices.contains(row) else { return }
        if let item = library.items.row(row) {
            return model.clickInGrid(item.url, extending: extending)
        }
        let id = library.photoIDs[row]
        library.whenRead([id]) { [weak self] in
            guard let self, let url = library.url(ofPhoto: id) else { return }
            model.clickInGrid(url, extending: extending)
        }
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
    func photoItem(from start: Int, by step: Int) -> Int? {
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
