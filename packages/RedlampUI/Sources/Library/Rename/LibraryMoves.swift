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
    }

    var moves: [Move]
    /// Photos to show again that the folder no longer lists, a move's Undo, with their content keys.
    var restoring: [LibraryItem] = []
    var keys: [URL: ContentKey] = [:]
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
    }

    /// The URL the open folder's list gives a photo at `path` (a folder's path, a slash and a name), as
    /// `LibraryFolderList` makes them; nil for a photo outside the folders shown.
    func listedURL(ofPath path: String) -> URL? {
        guard let folder = openFolder else { return nil }
        let top = LibraryService.path(folder)
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if directory == top {
            return folder.appending(path: name, directoryHint: .notDirectory)
        }
        let below = top == "/" ? "/" : top + "/"
        guard includesSubfolders, directory.hasPrefix(below) else { return nil }
        return folder.appending(
            path: String(directory.dropFirst(below.count)) + "/" + name,
            directoryHint: .notDirectory,
        )
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
                diff: LibraryDiff(updated: IndexSet(renamed.map(\.0))), reordered: false,
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

    /// Returns once the open folder's list from the library has handed over every change the library had for
    /// it: the content key of `photo`'s row (its index ID and URL) is taken out, the library hears the photo
    /// changed, and the list's change for it gives the key back, as it does every photo it hands over. A
    /// change made before it would otherwise reach a list a rename or a move has since changed, and show the
    /// photos where they were. A filtered list keeps its photos' IDs by their places, so it isn't waited for.
    func caughtUp(with photo: (id: Int64, url: URL), live: LibraryLive) async {
        guard fromLibrary.list != nil, !isFiltered, let key = fromLibrary.keys.removeValue(forKey: photo.url) else {
            return
        }
        live.photosChanged([photo.id])
        await live.settle()
        for _ in 0 ..< 400 where fromLibrary.keys[photo.url] == nil && fromLibrary.list != nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if fromLibrary.keys[photo.url] == nil, positions[photo.url] != nil {
            fromLibrary.keys[photo.url] = key
        }
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
