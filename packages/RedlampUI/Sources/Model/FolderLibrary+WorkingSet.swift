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

    /// Adds folders to the working set (a folder inside one already there isn't added again) and
    /// returns them. Their bookmarks are made in the background.
    @discardableResult
    func add(_ folders: [URL]) -> [WorkingFolder] {
        var added: [WorkingFolder] = []
        for folder in folders where root(containing: folder) == nil {
            let root = WorkingFolder(path: folder.standardizedFileURL.path)
            roots.append(root)
            added.append(root)
        }
        guard !added.isEmpty else { return [] }
        saveSettings()
        watchRoots()
        for root in added {
            startAccess(root)
            let url = root.url
            scheduler.submit(.lookAhead) {
                let made = WorkingFolder.make(for: url, id: root.id)
                Task { @MainActor [weak self] in self?.replaceRoot(made) }
            }
        }
        return added
    }

    /// Takes a root out of the working set and, with the library on, out of the library: its photos leave every
    /// list, count and search, and the index forgets them, as Lightroom Classic's Remove does
    /// (`LibraryService.remove`); adding the folder again brings them back from their sidecars. Nothing on disk
    /// changes. Closes it if it was open. The task returned is over once the library's lists leave its photos out.
    @discardableResult
    func remove(_ root: WorkingFolder) -> Task<Void, Never>? {
        roots.removeAll { $0.id == root.id }
        missing.remove(root.id)
        stopAccess(root)
        if let openFolder, root.contains(openFolder), self.root(containing: openFolder) == nil {
            open(nil)
        }
        saveSettings()
        let removal = service?.remove(root.url, keeping: roots.map(\.url))
        watchRoots()
        return removal
    }

    /// Points a missing root at the folder the user found it in. The library forgets the photos it had where
    /// the root was, and reads them where it is.
    func locate(_ root: WorkingFolder, at url: URL) {
        stopAccess(root)
        let moved = WorkingFolder(id: root.id, path: url.standardizedFileURL.path)
        replaceRoot(moved)
        missing.remove(root.id)
        startAccess(moved)
        if moved.path != root.path {
            service?.remove(root.url, keeping: roots.map(\.url))
        }
        watchRoots()
        scheduler.submit(.lookAhead) {
            let made = WorkingFolder.make(for: url, id: root.id)
            Task { @MainActor [weak self] in self?.replaceRoot(made) }
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
                    if let resolved {
                        if resolved != root {
                            replaceRoot(resolved)
                        }
                        missing.remove(root.id)
                        startAccess(resolved)
                    } else {
                        missing.insert(root.id)
                    }
                }
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
                    if let resolved {
                        if missing.contains(root.id) {
                            missing.remove(root.id)
                            appeared.append(resolved)
                            startAccess(resolved)
                        }
                        if resolved != root {
                            replaceRoot(resolved)
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

    private func startAccess(_ root: WorkingFolder) {
        guard accessing.insert(root.path).inserted else { return }
        FolderAccess.start(root.url)
    }

    private func stopAccess(_ root: WorkingFolder) {
        guard accessing.remove(root.path) != nil else { return }
        FolderAccess.stop(root.url)
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

    func saveSettings() {
        guard let defaults else { return }
        defaults.set(try? JSONEncoder().encode(roots), forKey: Key.roots)
        defaults.set((openFolder ?? trash.folderBefore)?.standardizedFileURL.path, forKey: Key.open)
        defaults.set(expandedFolders.sorted(), forKey: Key.expanded)
        defaults.set(
            lastPhotoOrder.compactMap { folder in lastPhotos[folder].map { [folder, $0] } },
            forKey: Key.lastPhotos,
        )
    }
}
