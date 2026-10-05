import AppKit
import Foundation
import RedlampDocument

/// What `FolderLibrary` keeps for following the file system.
struct Watching {
    var watcher: FolderWatcher?
    var paths: [String] = []
    var mountObservers: [any NSObjectProtocol] = []
    /// Roots on network volumes, which FSEvents doesn't cover: their folders are polled.
    var remote: [String] = []
    var poll: Timer?
    /// Directories waiting for files still being written to settle.
    var settling: Set<String> = []
    /// Roots' real paths (symlinks resolved), which FSEvents reports, with the paths the library
    /// knows them by.
    var aliases: [(real: String, path: String)] = []

    /// `path` as the library knows it.
    func translate(_ path: String) -> String {
        for alias in aliases where alias.real != alias.path {
            if path == alias.real {
                return alias.path
            }
            if path.hasPrefix(alias.real + "/") {
                return alias.path + path.dropFirst(alias.real.count)
            }
        }
        return path
    }
}

/// Following the disk: the roots are watched with FSEvents; a changed directory that's shown is
/// listed again and diffed into the photos (inserts, removals, rewritten files, never a reload),
/// unless the library shows the open folder and follows it itself, and a changed directory in the
/// tree updates its row. Mounting and unmounting volumes finds and loses roots. Network volumes are
/// polled.
extension FolderLibrary {
    nonisolated static let settleDelay: TimeInterval = 2
    static let pollInterval: TimeInterval = 15

    /// Watches the roots that can be found; called whenever they change.
    func watchRoots() {
        observeMounts()
        service?.follow(roots.map(\.url))
        let paths = roots.filter { !missing.contains($0.id) }.map(\.path)
        guard paths != watching.paths else { return }
        watching.watcher?.stop()
        watching.paths = paths
        watching.watcher = paths.isEmpty ? nil : FolderWatcher(paths: paths) { [weak self] directories in
            Task { @MainActor in
                guard let library = self else { return }
                library.changed(directories.map(library.watching.translate))
            }
        }
        scheduler.submit(.lookAhead) {
            // `realpath`, not `resolvingSymlinksInPath`, which strips `/private` back off.
            let aliases = paths.map { path in
                guard let real = realpath(path, nil) else { return (path, path) }
                defer { free(real) }
                return (String(cString: real), path)
            }
            let remote = paths.filter { path in
                (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
            }
            Task { @MainActor [weak self] in
                self?.watching.aliases = aliases
                self?.poll(remote)
            }
        }
    }

    private func poll(_ remote: [String]) {
        watching.remote = remote
        watching.poll?.invalidate()
        watching.poll = nil
        guard !remote.isEmpty else { return }
        watching.poll = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let library = self else { return }
                let remote = library.watching.remote
                let watched = library.listedDirectories.union(library.tree.keys)
                library.changed(watched.filter { path in remote.contains { path == $0 || path.hasPrefix($0 + "/") } })
            }
        }
    }

    private func observeMounts() {
        guard watching.mountObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            watching.mountObservers
                .append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.volumesChanged() }
                })
        }
    }

    /// A volume came or went: roots are found or lost, and the open folder follows its root.
    func volumesChanged() {
        recheckRoots { [weak self] appeared in
            guard let self else { return }
            watchRoots()
            guard let open = openFolder, let root = root(containing: open) else { return }
            if missing.contains(root.id) {
                guard !isOpenFolderUnavailable else { return }
                closeLibraryList()
                isOpenFolderUnavailable = true
                listedDirectories = []
                replace(with: [])
            } else if isOpenFolderUnavailable || appeared.contains(where: { $0.id == root.id }) {
                self.open(open) { [weak self] found in self?.onReopened?(found) }
            }
        }
    }

    // MARK: - Changes

    /// Directories FSEvents (or polling) reported changed.
    func changed(_ directories: some Sequence<String>) {
        for directory in Set(directories) {
            if tree[directory] != nil {
                listTree(URL(fileURLWithPath: directory, isDirectory: true))
            }
            if shows(directory) {
                relist(directory)
            }
            if roots.contains(where: { $0.path == directory }) {
                volumesChanged()
            }
        }
    }

    /// Whether photos in `directory` are shown, or would be once listed (a new subfolder).
    func shows(_ directory: String) -> Bool {
        guard let open = openFolder?.path else { return false }
        return directory == open || includesSubfolders && directory.hasPrefix(open + "/")
    }

    private func relist(_ directory: String) {
        guard !isShownFromLibrary else { return }
        let generation = generation
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        scheduler.submit(.onScreen, key: keyPrefix + "relist:\(generation):\(directory)") {
            let listing = try? FolderScanner.list(url)
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                merge(listing, at: directory)
            }
        }
    }

    /// Diffs a directory's new listing into the photos (nil: it's gone, with everything beneath).
    func merge(_ listing: FolderListing?, at directory: String) {
        guard !isShownFromLibrary else { return }
        let now = Date()
        var incoming: [URL: LibraryItem] = [:]
        for var item in listing.map(LibraryItem.items) ?? [] {
            // Dated further ahead than that, a photo was copied with its source's date (a camera's
            // clock set ahead), and has finished.
            item.isSettling = abs(now.timeIntervalSince(item.modified)) < Self.settleDelay
            incoming[item.url] = item
        }
        var removed = IndexSet()
        var updated: [URL] = []
        for (index, item) in items.enumerated() {
            if item.folderPath == directory {
                guard var new = incoming.removeValue(forKey: item.url) else {
                    removed.insert(index)
                    continue
                }
                guard new.size != item.size || new.modified != item.modified || new.isSettling != item.isSettling
                    || new.hasSidecar != item.hasSidecar || new.sidecarModified != item.sidecarModified
                else { continue }
                new.hasEdits = item.hasEdits
                new.metadata = item.metadata
                items[index] = new
                updated.append(item.url)
            } else if listing == nil, item.folderPath.hasPrefix(directory + "/") {
                removed.insert(index)
            }
        }
        let inserting = incoming.values.sorted(by: LibraryItem.walkPrecedes)
        if !removed.isEmpty || !inserting.isEmpty || !updated.isEmpty {
            apply(removed: removed, inserting: inserting, updated: updated)
        }
        if let listing {
            listedDirectories.insert(directory)
            if includesSubfolders {
                for subfolder in listing.subfolders where !listedDirectories.contains(subfolder.path) {
                    walkIn(subfolder)
                }
            }
            // Unchanged photos too: one that arrived while the directory already waited was listed
            // again when that wait ended, maybe before its own date was old enough.
            if items.contains(where: { $0.folderPath == directory && $0.isSettling }) {
                settle(directory)
            }
        } else {
            listedDirectories = listedDirectories.filter { $0 != directory && !$0.hasPrefix(directory + "/") }
        }
        refreshStacks()
    }

    /// Publishes photos removed (by their indexes now), inserted in order, and changed in place
    /// (already in `items`). `probing` reads the badges of those with a sidecar.
    func apply(removed: IndexSet, inserting: [LibraryItem], updated: [URL], probing: Bool = true) {
        if !removed.isEmpty {
            items = items.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        }
        for item in inserting {
            var low = 0
            var high = items.count
            while low < high {
                let middle = (low + high) / 2
                if LibraryItem.walkPrecedes(items[middle], item) {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            items.insert(item, at: low)
        }
        if !removed.isEmpty || !inserting.isEmpty {
            positions = Dictionary(items.enumerated().map { ($1.url, $0) }) { first, _ in first }
        }
        let inserted = IndexSet(inserting.compactMap { positions[$0.url] })
        let changed = IndexSet(updated.compactMap { positions[$0] })
        publish(LibraryDiff(removed: removed, inserted: inserted, updated: changed))
        for row in inserted.union(changed) where probing && items[row].needsSummary {
            probeSidecars(in: row ..< row + 1, generation: generation)
        }
    }

    /// A subfolder that appeared under the open subtree: walked, and merged in in order.
    private func walkIn(_ folder: URL) {
        let generation = generation
        listedDirectories.insert(folder.path)
        Task {
            for await listing in FolderScanner.walk(folder, scheduler: scheduler) {
                guard self.generation == generation else { return }
                merge(listing, at: listing.folder.path)
            }
        }
    }

    /// Lists `directory` again once files still being written have had time to settle.
    private func settle(_ directory: String) {
        guard watching.settling.insert(directory).inserted else { return }
        let generation = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleDelay))
            guard let self else { return }
            watching.settling.remove(directory)
            guard self.generation == generation else { return }
            relist(directory)
        }
    }

    // MARK: - Focus stacks

    /// Looks for focus stacks in each shown directory on the background lane, one directory at a
    /// time (detection decodes thumbnails, and warming shares the lane), reusing what was found
    /// while a directory's listing is unchanged.
    func refreshStacks() {
        let generation = generation
        let snapshot = items
        let cached = stackCache.mapValues(\.signature)
        scheduler.submit(.background, key: keyPrefix + "stacks:\(generation)") {
            var groups: [String: [LibraryItem]] = [:]
            for item in snapshot {
                groups[item.folderPath, default: []].append(item)
            }
            var stale: [(directory: String, signature: Int, urls: [URL])] = []
            for (directory, photos) in groups {
                var hasher = Hasher()
                for photo in photos {
                    hasher.combine(photo.url)
                    hasher.combine(photo.size)
                    hasher.combine(photo.modified)
                }
                let signature = hasher.finalize()
                if cached[directory] != signature {
                    stale.append((directory, signature, photos.map(\.url)))
                }
            }
            let shown = groups.keys.sorted(by: FileOrder.precedes)
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                detectStacks(
                    stale.sorted { FileOrder.precedes($0.directory, $1.directory) },
                    shown: shown,
                    generation: generation,
                )
            }
        }
    }

    private func detectStacks(
        _ remaining: [(directory: String, signature: Int, urls: [URL])], shown: [String], generation: Int,
    ) {
        onStacks?(shown.flatMap { stackCache[$0]?.suggestions ?? [] })
        guard let next = remaining.first else { return }
        let files = files
        scheduler.submit(.background, key: keyPrefix + "stacks:\(generation):\(next.directory)") {
            let found = StackDetector.suggestions(in: next.urls, reading: files, concurrently: false)
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                stackCache[next.directory] = (next.signature, found)
                detectStacks(Array(remaining.dropFirst()), shown: shown, generation: generation)
            }
        }
    }
}
