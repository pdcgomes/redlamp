import Foundation
import RedlampDocument
import RedlampLibrary

/// A rename or a move the library is about to make (LIB-26), shown in the open folder's photos at once, before
/// its batch runs: each photo at its new URL keeps its ID, so the selection, the grid and the filmstrip follow it
/// without a reload or a jump. Unfiltered, the photos take their places in Folders' order and those moved out of
/// the folders shown leave; filtered or sorted, they change in place and the library's list puts them in order
/// (`FolderLibrary+Filter`). The library's own change for them then finds each where it already is. The order is
/// worked out off the main thread, from the photos as they're shown then.
struct LibraryMoves: Sendable {
    struct Move: Sendable {
        var from: URL
        /// Nil for a photo going where the folders shown don't reach.
        var to: URL?
        /// The photo's ID in the index, for a move a batch is about to make (`MovesAhead`).
        var id: Int64?
    }

    var moves: [Move]
    /// Photos to show again that the folder no longer lists, a move's Undo, with their content keys and their IDs in
    /// the index.
    var restoring: [LibraryItem] = []
    var keys: [URL: ContentKey] = [:]
    var ids: [URL: Int64] = [:]
}

/// The photos a batch moves, shown where it puts them before the open folder's list from the library has them there
/// (`LibraryMoves`), by their IDs in the index. The list's changes to them, made from the index before the batch wrote
/// it, are made where the photos are shown, so none is shown twice or back where it was; each leaves once the list has
/// it where it's shown, and the others once the list has handed over the batch's own change (`FolderLibrary.caughtUp`).
struct MovesAhead {
    struct Photo {
        /// Where the list has it; nil while it has it in none of the folders shown.
        var listed: URL?
        /// Where it's shown; nil for a photo moved out of the folders shown.
        var shown: URL?
        /// Its row and content key as the list last handed them over.
        var item: LibraryItem?
        var key: ContentKey?
    }

    private(set) var photos: [Int64: Photo] = [:]
    /// The photos' IDs, by the URL the list has each at.
    private var listed: [URL: Int64] = [:]

    var isEmpty: Bool {
        photos.isEmpty
    }

    /// Photo `id`, at `from` in the list unless it's ahead already, is shown at `to`.
    mutating func show(_ id: Int64, from: URL?, at to: URL?) {
        if photos[id] != nil {
            photos[id]?.shown = to
            return
        }
        photos[id] = Photo(listed: from, shown: to)
        if let from {
            listed[from] = id
        }
    }

    /// `change` as it changes the photos shown: the rows of photos ahead go where they're shown, or nowhere; one the
    /// list no longer has stays shown until the batch's change is in (`FolderLibrary.caughtUp`), and one the list has
    /// where it's shown is no longer ahead.
    mutating func translate(_ change: LibraryFolderList.Change) -> LibraryFolderList.Change {
        var translated = change
        translated.removed = []
        translated.inserted = []
        translated.updated = []
        var arrived: [Int64: (item: LibraryItem, inserted: Bool)] = [:]
        for (items, inserted) in [(change.inserted, true), (change.updated, false)] {
            for item in items {
                if let id = change.ids[item.url], photos[id] != nil {
                    arrived[id] = (item, inserted)
                } else if inserted {
                    translated.inserted.append(item)
                } else {
                    translated.updated.append(item)
                }
            }
        }
        for url in change.removed {
            guard let id = listed.removeValue(forKey: url), var photo = photos[id] else {
                translated.removed.append(url)
                continue
            }
            photo.listed = nil
            photos[id] = photo
            // Moved out of the folders shown, as it's shown.
            if arrived[id] == nil, photo.shown == nil {
                photos[id] = nil
            }
        }
        for (id, arrival) in arrived {
            guard var photo = photos[id] else { continue }
            let url = arrival.item.url
            let key = translated.keys.removeValue(forKey: url)
            translated.ids[url] = nil
            if let before = photo.listed, listed[before] == id {
                listed[before] = nil
            }
            guard photo.shown != url else {
                photos[id] = nil
                if arrival.inserted {
                    translated.inserted.append(arrival.item)
                } else {
                    translated.updated.append(arrival.item)
                }
                translated.ids[url] = id
                translated.keys[url] = key
                continue
            }
            photo.listed = url
            photo.item = arrival.item
            photo.key = key ?? photo.key
            listed[url] = id
            photos[id] = photo
            if let shown = photo.shown {
                translated.updated.append(FolderLibrary.item(arrival.item, at: shown))
                translated.ids[shown] = id
                translated.keys[shown] = key
            }
        }
        return translated
    }

    /// Takes every photo out, returning those the list has elsewhere than they're shown.
    mutating func takeAll() -> [Photo] {
        defer { self = MovesAhead() }
        return photos.values.filter { $0.listed != $0.shown }
    }
}

/// The URLs the open folder's list gives photos by their paths, as `LibraryFolderList` makes them, its folder's own
/// path worked out once.
struct ListedURLs: Sendable, Equatable {
    let folder: URL?
    let includesSubfolders: Bool
    private let top: String
    private let below: String

    init(folder: URL?, includesSubfolders: Bool) {
        self.folder = folder
        self.includesSubfolders = includesSubfolders
        top = folder.map(LibraryService.path) ?? ""
        below = top == "/" ? "/" : top + "/"
    }

    /// The URL of the photo at `path` (a folder's path, a slash and a name); nil for a photo outside the folders.
    func url(ofPath path: String) -> URL? {
        guard let folder else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if directory == top {
            return folder.appending(path: name, directoryHint: .notDirectory)
        }
        guard includesSubfolders, directory.hasPrefix(below) else { return nil }
        return folder.appending(
            path: String(directory.dropFirst(below.count)) + "/" + name,
            directoryHint: .notDirectory,
        )
    }
}

extension FolderLibrary {
    /// What showing `LibraryMoves` changes, made off the main thread from the photos at `revision`.
    struct Moved: Sendable {
        let revision: Int
        var items: [LibraryItem]
        var photoIDs: ContiguousArray<Int64>
        var positions: [URL: Int]
        var diff: LibraryDiff
        /// The rows' order changed, or rows came or went.
        var reordered: Bool
        /// The photos changed in place, the library's filtered list putting them in order.
        var filtered = false
    }

    /// The URL the open folder's list gives a photo at `path` (a folder's path, a slash and a name), as
    /// `LibraryFolderList` makes them; nil for a photo outside the folders shown.
    func listedURL(ofPath path: String) -> URL? {
        listedURLs.url(ofPath: path)
    }

    /// What gives the photos of the folders shown now their URLs, for many at once, off the main thread.
    var listedURLs: ListedURLs {
        ListedURLs(folder: openFolder, includesSubfolders: includesSubfolders)
    }

    /// Shows `moves` at once: works out the photos' places off the main thread, then, once the photos shown
    /// haven't changed meanwhile, puts them there. `before` runs between the two, before anyone hears of it:
    /// where the active photo goes. Returns the IDs the photos shown again were given, by their URLs.
    @discardableResult
    func show(_ moves: LibraryMoves, before: () -> Void = {}) async -> [URL: Int64] {
        // Nothing moves in the photos shown: a Library entry's, a collection's or a large folder's, whose list follows
        // the batch.
        if moves.moves.isEmpty && moves.restoring.isEmpty || items.readsOnRequest {
            before()
            publish(LibraryDiff())
            return [:]
        }
        while true {
            let restoredIDs = moves.restoring.isEmpty ? [] : Array(newPhotoIDs(moves.restoring.count))
            let shown = (
                items: items.allRows,
                ids: photoIDs,
                positions: positions,
                revision: revision,
                filtered: isFiltered,
            )
            let moved = await Task.detached(priority: .userInitiated) {
                Self.moving(
                    moves, items: shown.items, photoIDs: shown.ids, positions: shown.positions,
                    revision: shown.revision, filtered: shown.filtered, restoredIDs: restoredIDs,
                )
            }.value
            guard moved.revision == revision else { continue }
            apply(moved, moves)
            before()
            publish(moved.diff)
            var restored: [URL: Int64] = [:]
            for (item, id) in zip(moves.restoring, restoredIDs) where positions[item.url] != nil {
                restored[item.url] = id
            }
            return restored
        }
    }

    private func apply(_ moved: Moved, _ moves: LibraryMoves) {
        let replaced = (items, positions)
        if !moves.restoring.isEmpty {
            fromLibrary.indexIDs = false
        }
        if fromLibrary.list != nil, !moved.filtered {
            for move in moves.moves {
                if let id = move.id {
                    fromLibrary.ahead.show(id, from: move.from, at: move.to)
                }
            }
            for item in moves.restoring {
                if let id = moves.ids[item.url] {
                    fromLibrary.ahead.show(id, from: nil, at: item.url)
                }
            }
        }
        items = LibraryItems(moved.items)
        photoIDs = moved.photoIDs
        positions = moved.positions
        var keys: [(URL, ContentKey)] = []
        for move in moves.moves {
            if let key = fromLibrary.keys.removeValue(forKey: move.from), let to = move.to {
                keys.append((to, key))
            }
        }
        for (url, key) in keys {
            fromLibrary.keys[url] = key
        }
        fromLibrary.keys.merge(moves.keys) { _, restored in restored }
        if moved.reordered {
            photosMoved()
        }
        scheduler.submit(.background) { withExtendedLifetime(replaced) {} }
    }

    nonisolated static func moving(
        _ moves: LibraryMoves, items: [LibraryItem], photoIDs: ContiguousArray<Int64>, positions: [URL: Int],
        revision: Int, filtered: Bool, restoredIDs: [Int64],
    ) -> Moved {
        var target: [Int: URL?] = [:]
        for move in moves.moves {
            if let row = positions[move.from] {
                target[row] = move.to
            }
        }
        guard !filtered else {
            // In place, so the library's filtered list puts them in order and takes out those moved away.
            var items = items
            var positions = positions
            let renamed = target.compactMap { row, url in url.map { (row, $0) } }
            for (row, _) in renamed {
                positions[items[row].url] = nil
            }
            for (row, url) in renamed {
                items[row] = item(items[row], at: url)
                positions[url] = row
            }
            return Moved(
                revision: revision, items: items, photoIDs: photoIDs, positions: positions,
                diff: LibraryDiff(updated: IndexSet(renamed.map(\.0))), reordered: false, filtered: true,
            )
        }
        typealias Row = (item: LibraryItem, id: Int64, old: Int)
        var kept: [Row] = []
        kept.reserveCapacity(items.count)
        var arriving: [Row] = []
        var leaving = IndexSet()
        for row in items.indices {
            guard let destination = target[row] else {
                kept.append((items[row], photoIDs[row], row))
                continue
            }
            if let url = destination {
                arriving.append((item(items[row], at: url), photoIDs[row], row))
            } else {
                leaving.insert(row)
            }
        }
        for (item, id) in zip(moves.restoring, restoredIDs) {
            arriving.append((item, id, -1))
        }
        arriving.sort { LibraryItem.walkPrecedes($0.item, $1.item) }
        var merged: [Row] = []
        merged.reserveCapacity(kept.count + arriving.count)
        var (left, right) = (0, 0)
        while left < kept.count || right < arriving.count {
            if right == arriving.count || left < kept.count
                && !LibraryItem.walkPrecedes(arriving[right].item, kept[left].item) {
                merged.append(kept[left])
                left += 1
            } else {
                merged.append(arriving[right])
                right += 1
            }
        }
        var inOrder = true
        var last = -1
        for row in merged where row.old >= 0 {
            inOrder = inOrder && row.old > last
            last = row.old
        }
        let moving = Set(arriving.map(\.id))
        var diff = LibraryDiff(removed: leaving)
        for (index, row) in merged.enumerated() where moving.contains(row.id) {
            if row.old < 0 {
                diff.inserted.insert(index)
            } else if inOrder {
                diff.updated.insert(index)
            } else {
                diff.removed.insert(row.old)
                diff.inserted.insert(index)
            }
        }
        let shown = merged.map(\.item)
        return Moved(
            revision: revision, items: shown, photoIDs: ContiguousArray(merged.map(\.id)),
            positions: Dictionary(shown.enumerated().map { ($1.url, $0) }) { first, _ in first }, diff: diff,
            reordered: !leaving.isEmpty || !inOrder || !restoredIDs.isEmpty,
        )
    }

    /// The content key of the photo shown at `url`, when it's shown from the library.
    func contentKey(of url: URL) -> ContentKey? {
        guard let paths = fromLibrary.sourcePaths else { return fromLibrary.keys[url] }
        return paths.id(of: url).flatMap { fromLibrary.sourceKeys[$0] }
    }

    /// Returns once the open folder's list from the library has handed over every change the library had for its
    /// photos, however long that takes; a batch's own among them, once it has run. The photos a batch moved that are
    /// still ahead of the list are then shown where the list has them: a batch that stopped, or a photo another app
    /// moved meanwhile.
    func caughtUp() async {
        guard let list = fromLibrary.list else { return }
        await list.caughtUp()
        while fromLibrary.adopting, fromLibrary.list === list {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard fromLibrary.list === list, !fromLibrary.ahead.isEmpty, !isFiltered else {
            fromLibrary.ahead = MovesAhead()
            return
        }
        var moves: [LibraryMoves.Move] = []
        var restoring: [LibraryItem] = []
        var keys: [URL: ContentKey] = [:]
        for photo in fromLibrary.ahead.takeAll() {
            if let shown = photo.shown, positions[shown] != nil {
                moves.append(LibraryMoves.Move(from: shown, to: photo.listed))
            } else if let listed = photo.listed, positions[listed] == nil, let item = photo.item {
                restoring.append(item)
                keys[listed] = photo.key
            }
        }
        guard !moves.isEmpty || !restoring.isEmpty else { return }
        await show(LibraryMoves(moves: moves, restoring: restoring, keys: keys))
    }

    /// `item` at `url`, the same photo: its badges, its file's size and date, and its sidecar's.
    nonisolated static func item(_ item: LibraryItem, at url: URL) -> LibraryItem {
        var moved = LibraryItem(url: url, hasEdits: item.hasEdits, metadata: item.metadata)
        moved.size = item.size
        moved.modified = item.modified
        moved.hasSidecar = item.hasSidecar
        moved.sidecarIsLocal = item.sidecarIsLocal
        moved.sidecarModified = item.sidecarModified
        moved.isLocal = item.isLocal
        moved.isSettling = item.isSettling
        return moved
    }
}
