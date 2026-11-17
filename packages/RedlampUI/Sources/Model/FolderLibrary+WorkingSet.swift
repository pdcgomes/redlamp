import Foundation
import RedlampDocument

/// The working set: folders added, removed and located again, and what's remembered of it across
/// launches. Anything that touches the file system (bookmarks, whether a folder exists) runs on the
/// scheduler, never on the main thread: a network volume can take seconds to answer.
public extension FolderLibrary {
    /// The root `url` is in, if any.
    func root(containing url: URL) -> WorkingFolder? {
        roots.first { $0.contains(url) }
    }

    /// Adds folders to the working set and returns them. A folder inside one already there isn't added again, and one
    /// holding roots takes them in. Their bookmarks are made in the background, and each is saved once it has one;
    /// until then, the roots it took in are saved in its place.
    @discardableResult
    func add(_ folders: [URL]) -> [WorkingFolder] {
        var added: [WorkingFolder] = []
        for folder in folders where root(containing: folder) == nil {
            let root = WorkingFolder(path: folder.standardizedFileURL.path)
            let inside = roots.filter { root.contains($0.url) }
            bookmarking[root.id] = inside.flatMap { bookmarking[$0.id] ?? [$0] }
            added.removeAll(where: inside.contains)
            takeIn(inside)
            roots.append(root)
            added.append(root)
        }
        guard !added.isEmpty else { return [] }
        watchRoots()
        for root in added {
            bookmark(root, at: root.url)
        }
        return added
    }

    /// Takes the roots inside another root that can be found into it, as adding that root does: those a launch kept
    /// from before adding a root took in the roots inside it, or that a volume coming back finds inside another.
    internal func takeInNestedRoots() {
        let nested = roots.filter { root in
            roots.contains { $0.path != root.path && !missing.contains($0.id) && $0.contains(root.url) }
        }
        guard !nested.isEmpty else { return }
        takeIn(nested)
        saveSettings()
    }

    /// Takes roots another root holds out of the working set, the folder open staying open: the other root shows their
    /// folders, and the library keeps their photos as its own once it has indexed it (`LibraryService.takeIn`).
    private func takeIn(_ nested: [WorkingFolder]) {
        guard !nested.isEmpty else { return }
        for root in nested {
            roots.removeAll { $0.id == root.id }
            missing.remove(root.id)
            bookmarking.removeValue(forKey: root.id)
            stopAccess(root.id)
        }
        service?.takeIn(nested.map(\.url))
    }

    /// Takes a root out of the working set and, with the library on, out of the library: its photos leave every
    /// list, count and search, and the index forgets them, as Lightroom Classic's Remove does
    /// (`LibraryService.remove`); adding the folder again brings them back from their sidecars. Nothing on disk
    /// changes. Closes it if it was open. The task returned is over once the library's lists leave its photos out.
    @discardableResult
    func remove(_ root: WorkingFolder) -> Task<Void, Never>? {
        roots.removeAll { $0.id == root.id }
        missing.remove(root.id)
        bookmarking.removeValue(forKey: root.id)
        stopAccess(root.id)
        if let openFolder, root.contains(openFolder), self.root(containing: openFolder) == nil {
            open(nil)
        }
        saveSettings()
        let removal = service?.remove(root.url, keeping: roots.map(\.url))
        watchRoots()
        return removal
    }

    /// Points a missing root at the folder the user found it in. The library forgets the photos it had where
    /// the root was, and reads them where it is. Until its new bookmark is made, it's saved where it was.
    func locate(_ root: WorkingFolder, at url: URL) {
        stopAccess(root.id)
        if bookmarking[root.id] == nil, let saved = roots.first(where: { $0.id == root.id }) {
            bookmarking[root.id] = [saved]
        }
        let moved = WorkingFolder(id: root.id, path: url.standardizedFileURL.path)
        replaceRoot(moved)
        missing.remove(root.id)
        if moved.path != root.path {
            service?.remove(root.url, keeping: roots.map(\.url))
        }
        watchRoots()
        bookmark(moved, at: url)
    }

    /// Makes `root`'s bookmark off the main thread, then saves the root with it and starts its access, unless it
    /// left the working set or was located elsewhere meanwhile. `url` is a panel's or a drop's, which reaches the
    /// folder until the app quits.
    private func bookmark(_ root: WorkingFolder, at url: URL) {
        scheduler.submit(.lookAhead) {
            let made = WorkingFolder.make(for: url, id: root.id)
            Task { @MainActor [weak self] in
                guard let self, roots.contains(where: { $0.id == root.id && $0.path == made.path }) else { return }
                bookmarking.removeValue(forKey: root.id)
                replaceRoot(made)
                startAccess(root.id, at: url)
            }
        }
    }

    internal func replaceRoot(_ root: WorkingFolder) {
        guard let index = roots.firstIndex(where: { $0.id == root.id }) else { return }
        roots[index] = root
        saveSettings()
    }

    /// Finds every root again (bookmarks resolved off the main thread), marks the ones that are
    /// missing, and calls `restored` with the folder that was open and the photo shown in it.
    func restore(_ restored: @escaping @MainActor (_ folder: URL?, _ photo: URL?) -> Void) {
        let saved = roots
        let open = openFolder
        scheduler.submit(.onScreen) {
            let found = saved.map { ($0, $0.resolve()) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (root, resolved) in found {
                    if let (folder, url) = resolved {
                        if folder != root {
                            replaceRoot(folder)
                        }
                        missing.remove(root.id)
                        startAccess(root.id, at: url)
                    } else {
                        missing.insert(root.id)
                    }
                }
                takeInNestedRoots()
                watchRoots()
                let folder = open.flatMap { open in
                    root(containing: open).flatMap { missing.contains($0.id) ? nil : open }
                }
                restored(folder, folder.flatMap(lastPhoto(in:)))
            }
        }
    }

    /// Marks roots found or lost (a volume mounted or unmounted), checked off the main thread.
    internal func recheckRoots(_ changed: @escaping @MainActor (_ found: [WorkingFolder]) -> Void = { _ in }) {
        let saved = roots
        scheduler.submit(.lookAhead) {
            let found = saved.map { ($0, $0.resolve()) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var appeared: [WorkingFolder] = []
                // `missing` changes only when a root is found or lost: any change to it shows the roots
                // again, and a change in a root's own folder comes here.
                for (root, resolved) in found where roots.contains(where: { $0.id == root.id }) {
                    if let (folder, url) = resolved {
                        if missing.contains(root.id) {
                            missing.remove(root.id)
                            appeared.append(folder)
                            startAccess(root.id, at: url)
                        }
                        if folder != root, bookmarking[root.id] == nil {
                            replaceRoot(folder)
                        }
                    } else if !missing.contains(root.id) {
                        missing.insert(root.id)
                    }
                }
                changed(appeared)
            }
        }
    }

    // MARK: - The folder tree

    /// What the tree knows of `folder`; nil until it has been listed (see `listTree`).
    func node(for folder: URL) -> FolderNode? {
        tree[folder.standardizedFileURL.path]
    }

    /// The photos `folder`'s row counts, as Show Photos in Subfolders shows it: those directly in it, or
    /// with it on those in every folder below it too. A folder the library has indexed is counted from its
    /// index (`countFolders`); any other from its listing, which counts only the photos directly in it, so
    /// with Show Photos in Subfolders on one with subfolders isn't counted. Nil until known.
    func photoCount(of folder: URL) -> Int? {
        let path = folder.standardizedFileURL.path
        if let counted = counting.counts.folders[path] {
            return includesSubfolders ? counted.all : counted.own
        }
        guard let node = tree[path] else { return nil }
        return includesSubfolders && !node.subfolders.isEmpty ? nil : node.count
    }

    /// Lists `folder` for the tree: when its row first shows, and again when it changes on disk.
    func listTree(_ folder: URL, lane: WorkScheduler.Lane = .lookAhead) {
        let path = folder.standardizedFileURL.path
        guard listingTree.insert(path).inserted else { return }
        scheduler.submit(lane, key: keyPrefix + "tree:\(path)") {
            let listing = try? FolderScanner.list(folder)
            Task { @MainActor [weak self] in
                guard let self else { return }
                listingTree.remove(path)
                let node = listing.map { FolderNode(count: $0.photos.count, subfolders: $0.subfolders) }
                guard tree[path] != node else { return }
                tree[path] = node
                for observer in treeObservers.values {
                    observer([path])
                }
            }
        }
    }

    /// Calls `handler` with the paths of folders whose count or subfolders changed.
    func observeTree(_ handler: @escaping @MainActor (Set<String>) -> Void) -> LibraryObservation {
        let id = UUID()
        treeObservers[id] = handler
        return LibraryObservation { [weak self] in self?.treeObservers.removeValue(forKey: id) }
    }

    func isExpanded(_ folder: URL) -> Bool {
        expandedFolders.contains(folder.standardizedFileURL.path)
    }

    func setExpanded(_ folder: URL, _ expanded: Bool) {
        let path = folder.standardizedFileURL.path
        guard expanded != expandedFolders.contains(path) else { return }
        if expanded {
            expandedFolders.insert(path)
        } else {
            expandedFolders.remove(path)
        }
        saveSettings()
    }

    // MARK: - The last photo in each folder

    /// The photo last shown in `folder`.
    func lastPhoto(in folder: URL) -> URL? {
        lastPhotos[folder.standardizedFileURL.path].map { URL(fileURLWithPath: $0) }
    }

    /// Remembers `photo` as the one shown in the open folder.
    func remember(_ photo: URL) {
        if items.readsOnRequest {
            activePhoto = sourcePhotoID(of: photo)
        }
        guard let folder = openFolder?.standardizedFileURL.path else { return }
        let path = photo.standardizedFileURL.path
        guard lastPhotos[folder] != path else { return }
        lastPhotos[folder] = path
        lastPhotoOrder.removeAll { $0 == folder }
        lastPhotoOrder.append(folder)
        if lastPhotoOrder.count > Self.rememberedFolders {
            for dropped in lastPhotoOrder.prefix(lastPhotoOrder.count - Self.rememberedFolders) {
                lastPhotos.removeValue(forKey: dropped)
            }
            lastPhotoOrder.removeFirst(lastPhotoOrder.count - Self.rememberedFolders)
        }
        saveSettings()
    }

    /// Folders whose last photo is remembered.
    static let rememberedFolders = 200

    // MARK: - Access

    /// Starts access to root `id` through `url`, the URL its bookmark resolved to, for as long as it stays in the
    /// working set: once, however often its path changes.
    private func startAccess(_ id: UUID, at url: URL) {
        if let started = accessing[id] {
            guard started != url else { return }
            FolderAccess.stop(started)
        }
        accessing[id] = url
        FolderAccess.start(url)
    }

    private func stopAccess(_ id: UUID) {
        guard let url = accessing.removeValue(forKey: id) else { return }
        FolderAccess.stop(url)
    }
}

// MARK: - Settings

extension FolderLibrary {
    enum Key {
        static let roots = "folders.roots"
        static let open = "folders.open"
        /// Show Photos in Subfolders as the user last set it, written only when they do. Earlier versions
        /// kept it in `folders.subfolders`, written at every save, which can't tell a choice from the
        /// default they had, off, so it isn't read.
        static let subfolders = "folders.includesSubfolders"
        static let expanded = "folders.expanded"
        static let lastPhotos = "folders.lastPhotos"
        /// The highest photo ID the index was known to have given (`FolderLibrary.noteIndexID`).
        static let highestIndexID = "library.highestPhotoID"
        /// The single folder earlier versions remembered.
        static let legacyFolder = "lastFolder"
    }

    func loadSettings() {
        guard let defaults else { return }
        highestIndexID = Int64(defaults.integer(forKey: Key.highestIndexID))
        if let data = defaults.data(forKey: Key.roots),
           let saved = try? JSONDecoder().decode([WorkingFolder].self, from: data) {
            roots = saved
            hasSavedRoots = true
            openFolder = defaults.string(forKey: Key.open).map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else if let legacy = defaults.string(forKey: Key.legacyFolder) {
            roots = [WorkingFolder(path: URL(fileURLWithPath: legacy).standardizedFileURL.path)]
            openFolder = roots.first?.url
        }
        includesSubfolders = defaults.object(forKey: Key.subfolders) as? Bool ?? true
        expandedFolders = Set(defaults.stringArray(forKey: Key.expanded) ?? [])
        let pairs = defaults.array(forKey: Key.lastPhotos) as? [[String]] ?? []
        for pair in pairs where pair.count == 2 {
            lastPhotos[pair[0]] = pair[1]
            lastPhotoOrder.append(pair[0])
        }
    }

    /// The roots as they're saved: each with its bookmark, which in the App Sandbox is what reaches it after a
    /// relaunch. One whose bookmark is being made is saved as it was before (`bookmarking`): if it was just added, as
    /// the roots it took in, or not at all.
    var savedRoots: [WorkingFolder] {
        roots.flatMap { bookmarking[$0.id] ?? [$0] }
    }

    func saveSettings() {
        guard let defaults else { return }
        defaults.set(try? JSONEncoder().encode(savedRoots), forKey: Key.roots)
        defaults.set((openFolder ?? trash.folderBefore)?.standardizedFileURL.path, forKey: Key.open)
        defaults.set(expandedFolders.sorted(), forKey: Key.expanded)
        defaults.set(
            lastPhotoOrder.compactMap { folder in lastPhotos[folder].map { [folder, $0] } },
            forKey: Key.lastPhotos,
        )
    }
}
