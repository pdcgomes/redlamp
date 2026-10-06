import Foundation
import RedlampDocument

/// Plans steps from where photos and folders are now: each photo with its `.redlamp` sidecars
/// (beside it and on this Mac) and other apps' sidecars named after it, and its pair's files when
/// they all go; renames ordered so none takes a name another photo still holds, through a temporary
/// name where they go round in a cycle; and, across volumes, copies. It lists each folder once, and
/// says what would stop the steps before they start.
///
/// It blocks on the file system: use it off the caller.
final class FilePlanner: @unchecked Sendable {
    let fileSystem: any LibraryFileSystem
    /// Every root of the library, so a sidecar on this Mac has a place wherever its photo goes.
    let locator: SidecarLocator
    private var listings: [String: Listing] = [:]
    private var volumes: [String: String] = [:]

    /// Other apps' sidecars, named after a photo (`IMG_1234.ARW.xmp`) or its name without the
    /// extension (`IMG_1234.xmp`).
    static let otherAppExtensions = NamingJob.sidecarExtensions.subtracting(["redlamp"]).sorted()

    struct Listing {
        /// By folded name.
        var entries: [String: FileEntry] = [:]
        var exists = false
        /// There, but it can't be listed: the Trash from inside a sandbox, a drop box. What's in it is
        /// asked for by name.
        var isClosed = false
        /// The photos' names by their folded names without extensions.
        var photosByStem: [String: [String]] = [:]
    }

    init(fileSystem: any LibraryFileSystem, locator: SidecarLocator) {
        self.fileSystem = fileSystem
        self.locator = locator
    }

    // MARK: - Folders and volumes

    func listing(_ folder: String) -> Listing {
        if let listing = listings[folder] {
            return listing
        }
        var listing = Listing()
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        if let entries = try? fileSystem.contentsOfDirectory(at: url) {
            listing.exists = true
            for entry in entries {
                listing.entries[NamingJob.fold(entry.name)] = entry
                if FolderWalk.isPhoto(entry) {
                    listing.photosByStem[NamingJob.fold(NamingJob.split(entry.name).base), default: []]
                        .append(entry.name)
                }
            }
        } else if (try? fileSystem.attributes(of: url))?.isDirectory == true {
            listing.exists = true
            listing.isClosed = true
        }
        listings[folder] = listing
        return listing
    }

    /// What's at `path` as its folder's listing has it, or as the file system says when the folder
    /// can't be listed.
    func entry(_ path: String) -> FileEntry? {
        let (folder, name) = Self.split(path)
        let listing = listing(folder)
        guard listing.isClosed else { return listing.entries[NamingJob.fold(name)] }
        return try? fileSystem.attributes(of: URL(fileURLWithPath: path))
    }

    /// Forgets the listings, so the next ones are read again.
    func forgetListings() {
        listings = [:]
    }

    /// The volume `path` is on, or would be: its nearest folder that's there decides.
    func volume(of path: String) -> String {
        var url = URL(fileURLWithPath: path)
        var visited: [String] = []
        while true {
            let folder = url.path
            if let known = volumes[folder] {
                visited.forEach { volumes[$0] = known }
                return known
            }
            visited.append(folder)
            if let info = try? fileSystem.volume(of: url) {
                let id = info.uuid ?? info.name ?? ""
                visited.forEach { volumes[$0] = id }
                return id
            }
            guard folder != "/", !folder.isEmpty else { return "" }
            url = url.deletingLastPathComponent()
        }
    }

    /// The path with its last name in Unicode's composed form, as the file system's writes make it.
    static func composedLast(_ path: String) -> String {
        let (folder, name) = split(path)
        return (folder == "/" ? "" : folder) + "/" + name.precomposedStringWithCanonicalMapping
    }

    /// A path's folder and name.
    static func split(_ path: String) -> (folder: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        let folder = String(path[..<slash])
        return (folder.isEmpty ? "/" : folder, String(path[path.index(after: slash)...]))
    }

    // MARK: - Photos

    /// Photos going one way together: from one folder and name without its extension to another.
    struct Group {
        var from: String
        var stem: String
        var to: String
        var newStem: String
        var members: [PhotoMove]

        var sourceKey: String {
            NamingJob.fold(from + "/" + stem)
        }

        var destinationKey: String {
            NamingJob.fold(to + "/" + newStem)
        }
    }

    /// Steps that put each photo where its move says, with its files; the photos of a group run
    /// together. `temporaryStem` names the photos a cycle parks while the others move.
    func moveSteps(_ moves: [PhotoMove], temporaryStem: () -> String = FilePlanner.temporaryStem) -> [FileStep] {
        var groups: [Group] = []
        var byKey: [String: Int] = [:]
        for move in moves where move.from != move.to {
            let (from, name) = Self.split(move.from)
            let (to, newName) = Self.split(move.to)
            let stem = NamingJob.split(name).base
            let newStem = NamingJob.split(newName).base
            let key = NamingJob.fold(from + "/" + stem) + "\u{0}" + NamingJob.fold(to + "/" + newStem)
            if let group = byKey[key] {
                groups[group].members.append(move)
            } else {
                byKey[key] = groups.count
                groups.append(Group(from: from, stem: stem, to: to, newStem: newStem, members: [move]))
            }
        }

        var holder: [String: Int] = [:]
        for (index, group) in groups.enumerated() where group.sourceKey != group.destinationKey {
            holder[group.sourceKey] = index
        }
        var blocker = [Int?](repeating: nil, count: groups.count)
        var blocks = [Int?](repeating: nil, count: groups.count)
        for (index, group) in groups.enumerated() {
            guard let held = holder[group.destinationKey], held != index, blocks[held] == nil else { continue }
            blocker[index] = held
            blocks[held] = index
        }

        var steps: [FileStep] = []
        var visited = [Bool](repeating: false, count: groups.count)
        for start in groups.indices where blocker[start] == nil {
            var next: Int? = start
            while let index = next, !visited[index] {
                visited[index] = true
                steps.append(step(moving: groups[index]))
                next = blocks[index]
            }
        }
        for start in groups.indices where !visited[start] {
            let parked = parking(groups[start], as: temporaryStem())
            var cycle: [Int] = []
            var next = blocks[start]
            while let index = next, index != start, !visited[index] {
                cycle.append(index)
                next = blocks[index]
            }
            visited[start] = true
            var first = step(moving: parked)
            first.isSafe = false
            steps.append(first)
            for index in cycle {
                visited[index] = true
                var step = step(moving: groups[index])
                step.isSafe = false
                steps.append(step)
            }
            steps.append(closing(groups[start], parked: parked, from: first))
        }
        return steps
    }

    /// The group moved to a name of its own in its folder.
    private func parking(_ group: Group, as stem: String) -> Group {
        var parked = group
        parked.to = group.from
        parked.newStem = stem
        parked.members = group.members.map { member in
            let ext = NamingJob.split(Self.split(member.from).name).ext
            return PhotoMove(
                id: member.id,
                from: member.from,
                to: group.from + "/" + stem + (ext.isEmpty ? "" : "." + ext),
            )
        }
        return parked
    }

    /// The step from a parked group's names to where the group goes: each item `away` moved, on from
    /// where it put it.
    private func closing(_ group: Group, parked: Group, from away: FileStep) -> FileStep {
        var direct: [String: FileItem] = [:]
        for item in items(for: group) where direct[item.source] == nil {
            direct[item.source] = item
        }
        let items = away.items.compactMap { parkedItem -> FileItem? in
            guard let source = parkedItem.destination, var item = direct[parkedItem.source] else { return nil }
            item.source = source
            return item
        }
        let photos = zip(group.members, parked.members).map { PhotoMove(id: $0.id, from: $1.to, to: $0.to) }
        return FileStep(kind: .move, items: items, photos: photos)
    }

    private func step(moving group: Group) -> FileStep {
        FileStep(kind: .move, items: items(for: group), photos: group.members)
    }

    /// A group's files: each photo, its sidecars beside it and on this Mac, other apps' sidecars named
    /// after it, and those named after the group's name without the extension when every photo of
    /// that name goes.
    func items(for group: Group) -> [FileItem] {
        let listing = listing(group.from)
        let copies = volume(of: group.from) != volume(of: group.to)
        var items: [FileItem] = []
        var seen = Set<String>()
        func add(_ role: FileItem.Role, _ entry: FileEntry, from folder: String, to destination: String) {
            let source = folder + "/" + entry.name
            guard seen.insert(source).inserted else { return }
            items.append(FileItem(
                role: role, source: source, destination: destination, copies: copies, fileID: entry.fileIdentifier,
                size: entry.isDirectory ? nil : entry.size, modified: entry.isDirectory ? nil : entry.modified,
                isDirectory: entry.isDirectory,
            ))
        }
        for member in group.members {
            let name = Self.split(member.from).name
            let newName = Self.split(member.to).name
            if let photo = listing.entries[NamingJob.fold(name)] {
                add(.photo, photo, from: group.from, to: member.to)
            } else {
                items.append(FileItem(role: .photo, source: member.from, destination: member.to, copies: copies))
            }
            if let sidecar = listing.entries[NamingJob.fold(name + ".redlamp")] {
                add(.sidecar, sidecar, from: group.from, to: group.to + "/" + newName + "." + Self.ext(sidecar))
            }
            if let mac = locator.onThisMac(URL(fileURLWithPath: member.from)),
               let destination = locator.onThisMac(URL(fileURLWithPath: member.to)),
               let sidecar = entry(mac.path) {
                let folder = Self.split(mac.path).folder
                let crosses = volume(of: folder) != volume(of: destination.deletingLastPathComponent().path)
                if seen.insert(mac.path).inserted {
                    items.append(FileItem(
                        role: .sidecarOnThisMac, source: mac.path, destination: destination.path, copies: crosses,
                        fileID: sidecar.fileIdentifier, isDirectory: sidecar.isDirectory,
                    ))
                }
            }
            for ext in Self.otherAppExtensions {
                if let other = listing.entries[NamingJob.fold(name + "." + ext)] {
                    add(.otherApp, other, from: group.from, to: group.to + "/" + newName + "." + Self.ext(other))
                }
            }
        }
        let names = Set(group.members.map { NamingJob.fold(Self.split($0.from).name) })
        let stemPhotos = listing.photosByStem[NamingJob.fold(group.stem)] ?? []
        if stemPhotos.allSatisfy({ names.contains(NamingJob.fold($0)) }),
           group.from != group.to || group.stem != group.newStem {
            for ext in Self.otherAppExtensions {
                if let other = listing.entries[NamingJob.fold(group.stem + "." + ext)] {
                    add(.otherApp, other, from: group.from, to: group.to + "/" + group.newStem + "." + Self.ext(other))
                }
            }
        }
        return items
    }

    /// The extension as the file has it.
    private static func ext(_ entry: FileEntry) -> String {
        NamingJob.split(entry.name).ext
    }

    /// A name for photos parked while a cycle of renames goes round: short, so it fits whatever
    /// the names around it.
    static func temporaryStem() -> String {
        "Redlamp-renaming-" + String(UInt32.random(in: .min ... .max), radix: 16, uppercase: true)
    }

    // MARK: - Checking

    /// What would stop `steps`, as the files are now: a file at a place a step would put one, a
    /// photo or folder gone or written since they were planned, or a folder to go in that isn't
    /// there. The steps come back without the sidecars that have gone meanwhile, and with those
    /// written since as they are now, so they still go with their photos.
    func check(_ steps: [FileStep]) -> (steps: [FileStep], conflicts: [FileConflict]) {
        var vacated = Set<String>()
        var placed = Set<String>()
        var conflicts: [FileConflict] = []
        var checked = steps
        func isThere(_ path: String) -> Bool {
            let key = NamingJob.fold(path)
            return placed.contains(key) || !vacated.contains(key) && entry(path) != nil
        }
        /// `item` as its step will find it: as planned, or put there by a step before; a sidecar as
        /// it is now. Nil when it isn't there, or is a photo, folder or file written since: for those
        /// the step can't do without, a conflict.
        func atSource(_ item: FileItem) -> FileItem? {
            let key = NamingJob.fold(item.source)
            if placed.contains(key) {
                return item
            }
            guard !vacated.contains(key), let entry = entry(item.source) else {
                if item.isRequired {
                    conflicts.append(FileConflict(path: item.source, reason: .gone))
                }
                return nil
            }
            if FileRunner.matches(entry, item) {
                return item
            }
            guard item.isRequired else { return item.found(as: entry) }
            let another = item.fileID.map { $0 != entry.fileIdentifier && entry.fileIdentifier != nil } ?? false
            conflicts.append(FileConflict(
                path: item.source, reason: another || item.isDirectory != entry.isDirectory ? .gone : .changed,
            ))
            return nil
        }
        func folderIsThere(_ path: String) -> Bool {
            placed.contains(NamingJob.fold(path)) || listing(path).exists
        }
        for (number, step) in steps.enumerated() {
            switch step.kind {
            case .move, .putBack:
                var kept: [FileItem] = []
                for item in step.items {
                    guard let destination = item.destination, let item = atSource(item) else { continue }
                    let (sourceKey, destinationKey) = (NamingJob.fold(item.source), NamingJob.fold(destination))
                    if sourceKey != destinationKey, isThere(destination) {
                        conflicts.append(FileConflict(path: destination, reason: .taken))
                    }
                    let folder = Self.split(destination).folder
                    if item.role != .sidecarOnThisMac, step.kind != .putBack, !folderIsThere(folder) {
                        conflicts.append(FileConflict(path: destination, reason: .noFolder))
                    }
                    placed.remove(sourceKey)
                    vacated.insert(sourceKey)
                    vacated.remove(destinationKey)
                    placed.insert(destinationKey)
                    kept.append(item)
                }
                checked[number].items = kept
            case .trash:
                var kept: [FileItem] = []
                for item in step.items {
                    guard let item = atSource(item) else { continue }
                    vacated.insert(NamingJob.fold(item.source))
                    kept.append(item)
                }
                checked[number].items = kept
            case .createFolder:
                guard let folder = step.folder else { continue }
                if isThere(folder) {
                    conflicts.append(FileConflict(path: folder, reason: .taken))
                } else if !folderIsThere(Self.split(folder).folder) {
                    conflicts.append(FileConflict(path: folder, reason: .noFolder))
                }
                vacated.remove(NamingJob.fold(folder))
                placed.insert(NamingJob.fold(folder))
            case .removeFolder:
                if let folder = step.folder {
                    placed.remove(NamingJob.fold(folder))
                    vacated.insert(NamingJob.fold(folder))
                }
            case .recordOriginalNames, .clearOriginalNames:
                break
            }
        }
        return (checked, conflicts)
    }
}

extension FileItem {
    /// The item as `entry`, at its source, is now.
    func found(as entry: FileEntry) -> FileItem {
        var item = self
        item.fileID = entry.fileIdentifier
        item.isDirectory = entry.isDirectory
        item.size = entry.isDirectory ? nil : entry.size
        item.modified = entry.isDirectory ? nil : entry.modified
        return item
    }
}
