import Foundation
import RedlampDesign
import RedlampLibrary

/// Reading ahead of held arrow keys in the Library loupe and in Develop (LIB-16). As the active photo steps to
/// the next or the previous in the grid's order, the thumbnails of the photos ahead are decoded into memory, and
/// the previews of the next two, so each photo shows its thumbnail the moment it's reached, never a blank frame,
/// and its preview once that lands. Each step replaces what the one before asked for (latest wins). As the loupe
/// or Develop is shown, and when a photo is reached by a jump, a click elsewhere, the thumbnails on either side
/// are read, those in memory left alone, so the first step finds its photo's; previews are read only ahead of
/// steps.
@MainActor
final class NavigationPrefetch {
    /// How many photos ahead have their thumbnails read: at key-repeat speed, a third of a second's travel. The
    /// first few, reached within a frame or two at 120 Hz, are read on the on-screen lane; so is the next photo's
    /// preview, needed within a key repeat.
    static let thumbnailsAhead = 12
    static let thumbnailsSoon = 3
    /// As the loupe or Develop is shown, or after a jump, how many on either side.
    static let thumbnailsAround = 3
    /// The farthest a step goes in one turn, as a burst of steps applies at once.
    private static let longestStep = 4

    private let model: EditorModel
    private var tracker: Tracker?
    private var last: URL?
    private var wasShown = false

    init(model: EditorModel) {
        self.model = model
        tracker = Tracker { [weak self] in self?.follow() }
    }

    private func follow() {
        let selection = model.selection
        let shown = model.module == .develop || model.libraryView == .loupe
        let (previous, entered) = (last, shown && !wasShown)
        last = selection
        wasShown = shown
        guard shown, let selection, selection != previous || entered else { return }
        let library = model.library
        let order = model.gridOrder
        guard let id = library.photoID(of: selection), let current = library.item(for: selection) else { return }
        let step = entered ? 0 : previous.flatMap(library.photoID(of:)).flatMap(order.place(of:))
            .flatMap { from in order.place(of: id).map { $0 - from } } ?? 0
        // The photo reached stays among those read, so a decode of it still waiting isn't dropped as it's reached.
        if step != 0, abs(step) <= Self.longestStep {
            let ahead = photos(from: id, by: step.signum(), count: Self.thumbnailsAhead, in: order)
            model.thumbnailLoader.prefetch([current] + ahead, soon: 1 + Self.thumbnailsSoon)
            model.previews.prefetch([current] + ahead.prefix(PhotoPreviews.ahead), soon: 2)
        } else {
            model.thumbnailLoader.prefetch(
                [current] + photos(from: id, by: 1, count: Self.thumbnailsAround, in: order)
                    + photos(from: id, by: -1, count: Self.thumbnailsAround, in: order),
            )
            model.previews.prefetch([])
        }
    }

    /// The photos of the `count` cells after photo `id`'s in `direction` (1 or -1), in order, as far as their rows
    /// are read; the rest are asked for.
    private func photos(from id: Int64, by direction: Int, count: Int, in order: GridOrder) -> [LibraryItem] {
        let library = model.library
        var found: [LibraryItem] = []
        var unread: [Int64] = []
        var cell = id
        for _ in 0 ..< count {
            guard let next = order.cell(direction, from: cell) else { break }
            cell = next
            if let item = library.photoList.index(of: next).flatMap({ library.items.row($0) }) {
                found.append(item)
            } else {
                unread.append(next)
            }
        }
        if !unread.isEmpty {
            library.askForRows(ofPhotos: unread)
        }
        return found
    }
}
