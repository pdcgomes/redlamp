import AppKit
import QuartzCore
import RedlampDesign
import RedlampDocument
import RedlampLibrary

extension LibraryGridView {
    // MARK: - Thumbnails

    func requestThumbnail(for cell: LibraryGridCell, _ item: LibraryItem, edge: Int) {
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

    /// The Library Health check's proposals changed: the cells on screen draw them, or once the grid is shown again.
    func proposalsChanged() {
        guard isShown, wasShown, !isStale else {
            staleRows.formUnion(IndexSet(cells.values.lazy.map(\.row).filter { $0 >= 0 }))
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (item, cell) in cells {
            place(item, cell, refresh: false)
        }
        CATransaction.commit()
    }

    /// The thumbnails of these photos show another edit: their cells ask for them, or once the grid is
    /// shown again.
    func editsShown(_ urls: [URL]) {
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
    func prefetch(around shown: Range<Int>) {
        let screen = shown.count
        let near = max(shown.lowerBound - screen, 0) ..< min(shown.upperBound + screen, shownCount)
        model.library.askForRows(at: near.lazy.compactMap(row(ofItem:)))
        let items = model.items
        let edge = edge
        var wanted = Set<URL>()
        for index in near where !shown.contains(index) {
            guard let row = row(ofItem: index), let item = items.row(row) else { continue }
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

    func showText(in cell: LibraryGridCell, _ item: LibraryItem) {
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

    func drew(_ key: GridText.Key, _ image: CGImage?) {
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

    func requestDetails(for shown: Range<Int>) {
        let items = model.items
        details.request(shown.compactMap { row(ofItem: $0).flatMap(items.row) }) { [weak self] urls in
            guard let self, gridLayout.style == .expanded else { return }
            let arrived = Set(urls)
            for cell in cells.values {
                if let item = cell.item, arrived.contains(item.url) {
                    showText(in: cell, item)
                }
            }
        }
    }
}
