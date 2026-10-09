import AppKit

/// Photos dragged within their open stack in the grid (LIB-28), as Lightroom Classic reorders an expanded stack: over
/// another photo of the same open burst or stack made by hand, that photo is outlined as a keyword's target is, and the
/// drop moves the photos dragged to its place (`EditorModel.movePhotos(_:inStackTo:)`). Anywhere else in the grid the
/// drag goes on, to the folders and collections it can reach. A keyword's drag is the grid's other drop.
extension LibraryGridView {
    /// What a drag over the grid would do there: move photos in their stack, or tag photos with a keyword.
    func dropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard LibraryDrags.photos(in: sender) != nil else { return keywordDragged(sender) }
        let operation = [NSDragOperation.move, .generic].first { sender.draggingSourceOperationMask.contains($0) }
        guard let operation, let target = stackMove(sender)?.target else {
            showKeywordTarget(nil)
            return []
        }
        showKeywordTarget(target)
        return operation
    }

    /// The drop: photos moved in their stack, or a keyword on photos.
    func dropped(_ sender: any NSDraggingInfo) -> Bool {
        guard LibraryDrags.photos(in: sender) != nil else { return keywordDropped(sender) }
        defer { showKeywordTarget(nil) }
        guard let (photos, target) = stackMove(sender), case let .photo(id, _) = target else { return false }
        return model.movePhotos(photos, inStackTo: id)
    }

    /// The photos a drag carries, by their IDs here, and the photo under it they'd take the place of, when they'd move
    /// in their open stack there.
    private func stackMove(_ sender: any NSDraggingInfo) -> (photos: [Int64], target: KeywordTarget)? {
        guard let dragged = LibraryDrags.photos(in: sender), dragged.fromLibrary else { return nil }
        let library = model.library
        let point = content.convert(sender.draggingLocation, from: nil)
        // The photos a drag of thousands carries are listed only over a stack that could hold them.
        guard let index = gridLayout.item(at: point), index < shownCount, let id = photoID(ofItem: index),
              let size = model.openStackSize(of: id), dragged.count < size, let url = library.url(ofPhoto: id)
        else { return nil }
        let photos: [Int64] = if dragged.count == 1 {
            dragged.listed?.urls.first.flatMap(library.photoID(of:)).map { [$0] } ?? []
        } else {
            Array(model.photoSelection.ids(in: library.photoList))
        }
        guard model.canMovePhotos(photos, inStackTo: id) else { return nil }
        return (photos, .photo(list: id, url: url))
    }
}
