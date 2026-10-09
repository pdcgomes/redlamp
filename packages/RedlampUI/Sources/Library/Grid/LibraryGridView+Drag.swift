import AppKit
import RedlampLibrary

/// A press on a photo in the grid, which a drag takes along.
struct PhotoPress {
    let point: CGPoint
    let url: URL
    /// The item pressed, for its thumbnail.
    let item: Int
    /// Released without a drag, it selects the photo alone.
    var selectsOnRelease: Bool
}

/// Where a keyword dragged over the grid lands: the photo under it, or the selection when that photo is in it.
enum KeywordTarget: Equatable {
    case photo(list: Int64, url: URL)
    case selection
}

/// The grid's drags (LIB-21, LIB-23, LIB-26): a press on a photo that moves a few points drags the selection when the
/// photo is in it, else the photo alone, as a dragging session (`LibraryDrags`), onto a folder or a collection in the
/// left panel; the drag shows the pressed photo's thumbnail, badged with how many photos it carries. A keyword
/// dragged from the Keyword List onto a photo tags it, or the selection when the photo is in it, the cells it would
/// tag outlined as it passes.
extension LibraryGridView {
    /// How far a press moves before it drags.
    static let dragDistance: CGFloat = 4

    /// A press on a photo moved: past `dragDistance`, its drag begins. True while the press is a photo's.
    func dragsPhotos(_ event: NSEvent) -> Bool {
        guard let press = photoPress else { return false }
        let point = content.convert(event.locationInWindow, from: nil)
        guard hypot(point.x - press.point.x, point.y - press.point.y) >= Self.dragDistance else { return true }
        photoPress = nil
        beginDrag(press, event: event)
        return true
    }

    /// The press ended without a drag.
    func releasePhotoPress() {
        guard let press = photoPress else { return }
        photoPress = nil
        if press.selectsOnRelease {
            model.clickInGrid(press.url)
        }
    }

    private func beginDrag(_ press: PhotoPress, event: NSEvent) {
        let library = model.library
        let selection = model.photoSelection
        let fromLibrary = library.service?.isReady == true && !library.showsRecentlyTrashed
        let photos = selection.count > 1 && library.photoID(of: press.url).map(selection.contains) == true
            ? DraggedPhotos(
                selection: selection, items: library.items, ids: library.photoIDs, source: library.rowSource,
                fromLibrary: fromLibrary,
            )
            : DraggedPhotos(photo: press.url, fromLibrary: fromLibrary)
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(photos.token, forType: LibraryDrags.photos)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let cell = gridLayout.frame(forItem: press.item)
        let frame = gridLayout.geometry.image.offsetBy(dx: cell.minX, dy: cell.minY)
        item.setDraggingFrame(
            frame, contents: LibraryDrags.image(cells[press.item]?.image, size: frame.size, count: photos.count),
        )
        LibraryDrags.begin(
            item,
            event: event,
            from: content,
            mask: LibraryGridContentView.photoOperations,
            photos: photos,
        )
    }

    // MARK: - A keyword dropped (LIB-21)

    func keywordDragged(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = [NSDragOperation.copy, .generic].first { sender.draggingSourceOperationMask.contains($0) }
        guard let operation, LibraryDrags.keyword(in: sender) != nil,
              let target = keywordTarget(at: sender.draggingLocation)
        else {
            showKeywordTarget(nil)
            return []
        }
        showKeywordTarget(target)
        return operation
    }

    func keywordDropped(_ sender: any NSDraggingInfo) -> Bool {
        defer { showKeywordTarget(nil) }
        guard let keyword = LibraryDrags.keyword(in: sender), let target = keywordTarget(at: sender.draggingLocation)
        else { return false }
        let panels = model.libraryPanels
        switch target {
        case .selection where model.library.items.readsOnRequest:
            // A large source's photos have the index's IDs: their rows aren't read for it.
            panels.change([keyword], ids: model.selectedIDs)
        case .selection:
            let photos = model.selectedPhotos
            Task { await panels.change([keyword], on: photos) }
        case let .photo(_, url):
            let photos = model.photos(standingFor: url)
            Task { await panels.change([keyword], on: photos) }
        }
        return true
    }

    /// The photo under `location` (window points), or the selection when it's among several selected; nil between
    /// cells, and while the photos shown aren't the library's.
    private func keywordTarget(at location: NSPoint) -> KeywordTarget? {
        let library = model.library
        guard library.service?.isReady == true, library.isShownFromLibrary || model.librarySources.shown != nil,
              !library.showsRecentlyTrashed
        else { return nil }
        let point = content.convert(location, from: nil)
        guard let index = gridLayout.item(at: point), index < shownCount, let row = row(ofItem: index),
              library.photoIDs.indices.contains(row)
        else { return nil }
        let id = library.photoIDs[row]
        if model.isMultiSelecting, model.photoSelection.contains(id) {
            return .selection
        }
        return library.row(at: row).map { .photo(list: id, url: $0.url) }
    }

    /// Outlines the cells on screen that `target` would tag.
    func showKeywordTarget(_ target: KeywordTarget?) {
        guard target != keywordTarget else { return }
        keywordTarget = target
        if target != nil {
            LibraryDrags.outlined += 1
        }
        let ids = model.library.photoIDs
        let selection = model.photoSelection
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for cell in cells.values {
            cell.isDropTarget = switch target {
            case let .photo(list, _): ids.indices.contains(cell.row) && ids[cell.row] == list
            case .selection: ids.indices.contains(cell.row) && selection.contains(ids[cell.row])
            case nil: false
            }
        }
        CATransaction.commit()
    }
}

extension LibraryGridContentView: NSDraggingSource, LibraryDragSource {
    /// What a drag of photos offers: moving them to a folder, copying, and putting them in a collection.
    static let photoOperations: NSDragOperation = [.move, .copy, .generic]

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? Self.photoOperations : []
    }

    func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
        libraryDragEnded()
        LibraryDrags.ended()
    }

    func libraryDragEnded() {
        grid?.photoPress = nil
    }
}
