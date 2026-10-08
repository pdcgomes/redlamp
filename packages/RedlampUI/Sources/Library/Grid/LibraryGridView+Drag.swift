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

/// The grid's drags (LIB-23, LIB-26): a press on a photo that moves a few points drags the selection when the photo
/// is in it, else the photo alone, as a dragging session (`LibraryDrags`), onto a folder or a collection in the left
/// panel. The drag shows the pressed photo's thumbnail, badged with how many photos it carries.
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
            ? DraggedPhotos(selection: selection, items: library.items, ids: library.photoIDs, fromLibrary: fromLibrary)
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
