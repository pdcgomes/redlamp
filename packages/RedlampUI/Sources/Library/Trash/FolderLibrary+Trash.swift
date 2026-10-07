import AppKit
import Foundation
import RedlampDocument
import RedlampLibrary

/// What `FolderLibrary` keeps of Recently Trashed.
struct TrashFollowing {
    /// The library's list, followed while it's open.
    var following: Task<Void, Never>?
    var activation: (any NSObjectProtocol)?
    /// The photos it lists, the newest batch's first.
    var photos: [TrashedPhoto] = []
    /// Each by its place in the Trash, as its row's URL.
    var byPlace: [URL: TrashedPhoto] = [:]
    /// The content keys of those shown, for their thumbnails.
    var keys: [URL: ContentKey] = [:]
    /// The folder open before Recently Trashed, which the next launch opens.
    var folderBefore: URL?
    /// Told of the photos once the first are in, for Recently Trashed shown before they were.
    var opened: (@MainActor ([LibraryItem]) -> Void)?
}

/// Recently Trashed as a source (LIB-26): the photos the library's batches moved to the Trash that are still
/// there (`FileOperations.trashed()`), the newest batch's first, shown in the grid and the filmstrip as a
/// folder's photos are: each at its place in the Trash, with the badges and the store's thumbnails of the row
/// its batch took out of the index. The list is followed while the library is open, for the Folders panel's
/// count, and looked at again when the app becomes active and when a volume comes back.
///
/// Nothing in it is written: its photos don't open in Develop, and culling leaves them as they are
/// (`EditorModel+Trash`); Put Back puts them where they were.
public extension FolderLibrary {
    /// Whether Recently Trashed can be shown: the library is open.
    var canShowRecentlyTrashed: Bool {
        service?.isReady == true
    }

    /// Shows Recently Trashed in place of the open folder, then calls `opened` with its photos once the first
    /// are in, as opening a folder does. The folder that was open is the one the next launch opens.
    func showRecentlyTrashed(opened: @escaping @MainActor ([LibraryItem]) -> Void = { _ in }) {
        guard canShowRecentlyTrashed else { return }
        let before = openFolder ?? trash.folderBefore
        open(nil)
        trash.folderBefore = before
        showsRecentlyTrashed = true
        saveSettings()
        followTrash()
        service?.checkTrash()
        guard trashedCount != nil else {
            isListing = true
            trash.opened = opened
            return
        }
        showTrashed()
        if items.isEmpty {
            trash.opened = opened
        }
        opened(items)
    }

    /// The photo Recently Trashed lists at `url`, its place in the Trash.
    func trashedPhoto(at url: URL) -> TrashedPhoto? {
        trash.byPlace[url]
    }
}

extension FolderLibrary {
    /// Follows Recently Trashed once the library is open.
    func followTrash() {
        guard trash.following == nil, let updates = service?.trashedUpdates() else { return }
        trash.following = Task { [weak self] in
            for await photos in updates {
                self?.trashed(photos)
            }
        }
        trash.activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.service?.checkTrash() }
        }
    }

    /// The library's list changed: kept for the count, and shown when Recently Trashed is.
    private func trashed(_ photos: [TrashedPhoto]) {
        trash.photos = photos
        trash.byPlace = Dictionary(photos.map { (URL(fileURLWithPath: $0.place), $0) }) { first, _ in first }
        trashedCount = photos.count
        guard showsRecentlyTrashed else { return }
        showTrashed()
        // Told once the first photos are in; the first list ends the listing even when it's empty.
        if let opened = trash.opened, isListing || !items.isEmpty {
            isListing = false
            if !items.isEmpty {
                trash.opened = nil
            }
            opened(items)
        }
    }

    /// The list as the photos shown: the photos that left it removed and those new to it inserted, row by
    /// row while those that stay keep their order, as a batch put back or one more moved to the Trash leave
    /// them; anything else replaces them.
    private func showTrashed() {
        let shown = trash.photos.map(Self.item)
        var keys: [URL: ContentKey] = [:]
        for photo in trash.photos {
            if let key = photo.photo.photo.contentKey.flatMap(ContentKey.init(data:)) {
                keys[URL(fileURLWithPath: photo.place)] = key
            }
        }
        trash.keys = keys
        let incoming = Set(shown.map(\.url))
        let removed = IndexSet(items.indices.filter { !incoming.contains(items[$0].url) })
        let staying = items.indices.filter { !removed.contains($0) }.map { items[$0].url }
        let stays = Set(staying)
        guard !items.isEmpty, staying == shown.map(\.url).filter(stays.contains) else {
            return replace(with: shown)
        }
        var ids = ContiguousArray<Int64>()
        ids.reserveCapacity(shown.count)
        var inserted = IndexSet()
        var updated = IndexSet()
        for (row, item) in shown.enumerated() {
            if let before = positions[item.url] {
                ids.append(photoIDs[before])
                if items[before] != item {
                    updated.insert(row)
                }
            } else {
                ids.append(newPhotoIDs(1).lowerBound)
                inserted.insert(row)
            }
        }
        guard !removed.isEmpty || !inserted.isEmpty || !updated.isEmpty else { return }
        items = shown
        photoIDs = ids
        positions = Dictionary(shown.enumerated().map { ($1.url, $0) }) { first, _ in first }
        photosMoved()
        publish(LibraryDiff(removed: removed, inserted: inserted, updated: updated))
    }

    /// `photo` as Recently Trashed shows it: at its place in the Trash, with its row's badges.
    nonisolated static func item(_ photo: TrashedPhoto) -> LibraryItem {
        LibraryFolderList.Mapping.item(photo.photo.photo.record(inFolder: 0), url: URL(fileURLWithPath: photo.place))
    }
}
