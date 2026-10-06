import Foundation
import RedlampDocument
import RedlampLibrary

/// What `FolderLibrary` keeps for showing the open folder from the library.
struct FromLibrary {
    /// The open folder's photo list, while it's shown from the library.
    var list: LibraryFolderList?
    /// The list's first change hasn't arrived.
    var awaitingFirst = false
    /// Told of the photos once the first change is in, for a folder that wasn't listed here.
    var opened: (@MainActor ([LibraryItem]) -> Void)?
    /// The photos listed here are being taken over from the first change: the changes after it
    /// wait for that.
    var adopting = false
    var pending: [LibraryFolderList.Change] = []
    /// The open folder was listed here, and is shown from the library once it can be.
    var waiting = false
    var checking = false
    /// The library had more to say while a check ran.
    var recheck = false
    var observation: LibraryObservation?
    /// Photos added or rewritten still settle.
    var settling = false
    /// The content keys of the photos shown from the library, for their thumbnails.
    var keys: [URL: ContentKey] = [:]
    /// The opening whose list didn't deliver within `libraryPatience`: it stays listed here.
    var gaveUp: Int?
}

/// Folders shown from the library (LIB-10). A folder it has indexed is shown from its photo list:
/// the same photos, in the same order, with the same badges as listing it gives, and LibraryLive's
/// changes become `LibraryDiff`s in place of FSEvents' listings. A folder it hasn't indexed yet is
/// listed here as before, then switches over once the library has it, changing only what differs,
/// so the filmstrip doesn't jump.
public extension FolderLibrary {
    /// Shows the folders `service` has indexed from its photo lists, starting it, and has it follow
    /// the folders in Folders.
    func attach(_ service: LibraryService) {
        self.service = service
        service.start(following: roots.map(\.url))
    }

    /// Whether the open folder is shown from the library.
    var isShownFromLibrary: Bool {
        fromLibrary.list != nil
    }

    /// The store's thumbnails and the content key of a photo shown from the library.
    func storeThumbnail(for item: LibraryItem) -> (StoreThumbnails, ContentKey)? {
        guard let key = fromLibrary.keys[item.url], let thumbnails = service?.thumbnails else { return nil }
        return (thumbnails, key)
    }

    /// Redlamp wrote `photo`'s sidecar: the library reads it again, since FSEvents doesn't report
    /// Redlamp's own writes on this Mac.
    func sidecarSaved(_ photo: URL) {
        service?.sidecarSaved(photo, store: sidecars.store(for: photo))
    }
}

extension FolderLibrary {
    /// How long the first photos from the library may take before the folder is listed instead.
    static let libraryPatience = Duration.seconds(10)

    /// Starts showing `folder` from the library if it can be; false when it's to be listed.
    func openFromLibrary(
        _ folder: URL, generation: Int, opened: @escaping @MainActor ([LibraryItem]) -> Void,
    ) async -> Bool {
        guard let service, service.isReady,
              await service.canShow(folder, includingSubfolders: includesSubfolders),
              self.generation == generation
        else { return false }
        show(folder, from: service, generation: generation, opened: opened)
        return true
    }

    /// Follows the open folder's photo list. Its first change replaces what's shown, or, when the
    /// folder was listed here, changes only what differs.
    private func show(
        _ folder: URL, from service: LibraryService, generation: Int,
        opened: (@MainActor ([LibraryItem]) -> Void)?,
    ) {
        fromLibrary.waiting = false
        fromLibrary.observation = nil
        fromLibrary.awaitingFirst = true
        fromLibrary.opened = opened
        fromLibrary.list = service.list(folder, includingSubfolders: includesSubfolders) { [weak self] change in
            self?.received(change, generation: generation)
        }
        Task { [weak self] in
            try? await Task.sleep(for: Self.libraryPatience)
            guard let self, self.generation == generation, fromLibrary.awaitingFirst else { return }
            let opened = fromLibrary.opened
            closeLibraryList()
            fromLibrary.gaveUp = generation
            if let opened {
                list(folder, generation: generation, opened: opened)
            }
        }
    }

    func closeLibraryList() {
        fromLibrary.list?.close()
        fromLibrary = FromLibrary(gaveUp: fromLibrary.gaveUp)
    }

    private func received(_ change: LibraryFolderList.Change, generation: Int) {
        guard generation == self.generation, fromLibrary.list != nil else { return }
        guard let all = change.all else {
            if fromLibrary.adopting {
                fromLibrary.pending.append(change)
                return
            }
            return apply(library: change)
        }
        fromLibrary.awaitingFirst = false
        fromLibrary.keys = change.keys
        let opened = fromLibrary.opened
        fromLibrary.opened = nil
        if let opened {
            replace(with: all.items, positions: all.positions)
            listedDirectories = Set(all.items.map(\.folderPath)).union(openFolder.map { [$0.path] } ?? [])
            isListing = false
            isOpenFolderUnavailable = false
            opened(items)
            refreshStacks()
            let directories = listedDirectories
            scheduler.submit(.background) {
                for directory in directories {
                    SidecarStore.removeLeftovers(in: URL(fileURLWithPath: directory))
                }
            }
        } else {
            adopt(all.items, generation: generation)
        }
    }

    /// Takes over the photos listed here from the library's, off the main thread: photos only one
    /// side has are removed or inserted, and those whose badges differ updated, keeping each file's
    /// dates as listed so cells and the thumbnail cache see the same photo.
    private func adopt(_ library: [LibraryItem], generation: Int) {
        let (current, revision) = (items, revision)
        fromLibrary.adopting = true
        Task { [weak self] in
            let difference = await Task.detached(priority: .userInitiated) {
                Self.difference(from: current, to: library)
            }.value
            guard let self, self.generation == generation, fromLibrary.list != nil else { return }
            guard self.revision == revision else { return adopt(library, generation: generation) }
            for (index, item) in difference.updated {
                items[index] = item
            }
            if !difference.removed.isEmpty || !difference.inserting.isEmpty || !difference.updated.isEmpty {
                apply(
                    removed: difference.removed, inserting: difference.inserting,
                    updated: difference.updated.map { items[$0.index].url }, probing: false,
                )
            }
            listedDirectories.formUnion(difference.inserting.map(\.folderPath))
            if items.contains(where: \.isSettling) {
                settleFromLibrary(generation)
            }
            fromLibrary.adopting = false
            let pending = fromLibrary.pending
            fromLibrary.pending = []
            pending.forEach(apply(library:))
        }
    }

    /// What changes `current`, the photos listed, into `library`'s.
    nonisolated static func difference(from current: [LibraryItem], to library: [LibraryItem]) -> (
        removed: IndexSet, updated: [(index: Int, item: LibraryItem)], inserting: [LibraryItem],
    ) {
        let incoming = Dictionary(library.map { ($0.url, $0) }) { first, _ in first }
        var removed = IndexSet()
        var updated: [(index: Int, item: LibraryItem)] = []
        var listed = Set<URL>()
        listed.reserveCapacity(current.count)
        for (index, item) in current.enumerated() {
            listed.insert(item.url)
            guard let new = incoming[item.url] else {
                removed.insert(index)
                continue
            }
            let kept = keeping(item, as: new)
            if kept != item {
                updated.append((index, kept))
            }
        }
        return (removed, updated, library.filter { !listed.contains($0.url) })
    }

    /// `new`, keeping `current`'s file and sidecar dates when they're the same within a millisecond:
    /// the index keeps dates as seconds since 1970, which rounds them, and the filmstrip and the
    /// thumbnail cache compare them exactly.
    nonisolated static func keeping(_ current: LibraryItem, as new: LibraryItem) -> LibraryItem {
        var kept = new
        if new.size == current.size, abs(new.modified.timeIntervalSince(current.modified)) < 1e-3 {
            kept.modified = current.modified
        }
        if let date = new.sidecarModified, let listed = current.sidecarModified,
           abs(date.timeIntervalSince(listed)) < 1e-3 {
            kept.sidecarModified = listed
        }
        // The index has no field a newer Redlamp wrote; the badges are what it has.
        if new.metadata.rating == current.metadata.rating, new.metadata.flag == current.metadata.flag,
           new.metadata.label == current.metadata.label {
            kept.metadata = current.metadata
        }
        kept.isSettling = current.isSettling
        return kept
    }

    /// LibraryLive's change to the open folder's photos, as a `LibraryDiff`.
    private func apply(library change: LibraryFolderList.Change) {
        for url in change.removed {
            fromLibrary.keys[url] = nil
        }
        fromLibrary.keys.merge(change.keys) { _, new in new }
        var removed = IndexSet(change.removed.compactMap { positions[$0] })
        var updated: [URL] = []
        var inserting: [LibraryItem] = []
        let now = Date()
        for var item in change.inserted + change.updated {
            guard let index = positions[item.url] else {
                item.isSettling = now.timeIntervalSince(item.modified) < Self.settleDelay
                inserting.append(item)
                continue
            }
            removed.remove(index)
            var kept = Self.keeping(items[index], as: item)
            if kept.size != items[index].size || kept.modified != items[index].modified {
                kept.isSettling = now.timeIntervalSince(kept.modified) < Self.settleDelay
            }
            if kept != items[index] {
                items[index] = kept
                updated.append(item.url)
            }
        }
        guard !removed.isEmpty || !inserting.isEmpty || !updated.isEmpty else { return }
        apply(removed: removed, inserting: inserting, updated: updated, probing: false)
        listedDirectories.formUnion(inserting.map(\.folderPath))
        if items.contains(where: \.isSettling) {
            settleFromLibrary(generation)
        }
        if !removed.isEmpty || !inserting.isEmpty {
            refreshStacks()
        }
    }

    /// Photos added or rewritten in the last `settleDelay` may still be being written: their
    /// thumbnails wait until then, as for a listed folder.
    private func settleFromLibrary(_ generation: Int) {
        guard !fromLibrary.settling else { return }
        fromLibrary.settling = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleDelay))
            guard let self, self.generation == generation, fromLibrary.list != nil else { return }
            fromLibrary.settling = false
            let now = Date()
            var settled = IndexSet()
            var waiting = false
            for index in items.indices where items[index].isSettling {
                if now.timeIntervalSince(items[index].modified) >= Self.settleDelay {
                    items[index].isSettling = false
                    settled.insert(index)
                } else {
                    waiting = true
                }
            }
            if !settled.isEmpty {
                publish(LibraryDiff(updated: settled))
            }
            if waiting {
                settleFromLibrary(generation)
            }
        }
    }

    // MARK: - Switching over

    /// The open folder, listed here, is shown from the library once the library can show it.
    func awaitLibrary(_ generation: Int) {
        guard let service, generation == self.generation, fromLibrary.list == nil, openFolder != nil,
              fromLibrary.gaveUp != generation
        else { return }
        fromLibrary.waiting = true
        if fromLibrary.observation == nil {
            fromLibrary.observation = service.observe { [weak self] in self?.retryLibrary(generation) }
        }
        retryLibrary(generation)
    }

    private func retryLibrary(_ generation: Int) {
        guard let service, service.isReady, generation == self.generation, fromLibrary.waiting, !isListing,
              let folder = openFolder
        else { return }
        guard !fromLibrary.checking else {
            fromLibrary.recheck = true
            return
        }
        fromLibrary.checking = true
        let (listed, includesSubfolders) = (listedDirectories, includesSubfolders)
        Task { [weak self] in
            let can = await service.canShow(folder, includingSubfolders: includesSubfolders, listed: listed)
            guard let self, generation == self.generation else { return }
            fromLibrary.checking = false
            guard fromLibrary.waiting else { return }
            if can, listed == listedDirectories, !isListing {
                show(folder, from: service, generation: generation, opened: nil)
            } else if fromLibrary.recheck {
                fromLibrary.recheck = false
                retryLibrary(generation)
            }
        }
    }
}
