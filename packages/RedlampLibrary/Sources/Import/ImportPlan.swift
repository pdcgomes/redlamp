import Foundation
import RedlampDocument

/// An import worked out before anything is copied (LIB-27): each photo chosen, with its files and the
/// folders and names they get below the destination and the backup, and what stays on the sources and
/// why. The import window and `redlamp library import --dry-run` show it; `Importer` runs it.
public struct ImportPlan: Sendable, Hashable {
    /// A source as the plan and its journal keep it.
    public struct Source: Sendable, Hashable, Codable {
        public var id: String
        public var name: String
        public var kind: ImportSource.Kind
        public var path: String
        public var volumeUUID: String?
        public var volumeName: String?
        public var isLocal: Bool
        public var isInternal: Bool
        /// Photos chosen from it that the plan can't take: unreadable, or with no folder to go in. Its
        /// card isn't safe to erase while there are any.
        public var unimported: Int
        /// Files on it that aren't photos or their sidecars (videos, a camera's own), which an import
        /// leaves where they are.
        public var otherFiles: Int

        public init(_ source: ImportSource, unimported: Int = 0, otherFiles: Int = 0) {
            id = source.id
            name = source.name
            kind = source.kind
            path = LibraryIndexer.path(source.url)
            volumeUUID = source.volume.uuid
            volumeName = source.volume.name
            isLocal = source.volume.isLocal
            isInternal = source.volume.isInternal
            self.unimported = unimported
            self.otherFiles = otherFiles
        }

        public var volume: VolumeInfo {
            VolumeInfo(uuid: volumeUUID, name: volumeName, isLocal: isLocal, isInternal: isInternal)
        }

        public var url: URL {
            URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// A file copied from its source to one path below the destination and the backup.
    public struct Copy: Sendable, Hashable, Codable {
        /// Where it is on its source.
        public var source: String
        public var role: ImportFile.Role
        public var size: Int64
        public var modified: Date
        public var isDirectory: Bool
        public var contentKey: ContentKey?
        /// Its folders and name below the destination: `2026/2026-10-05/IMG_0001.CR3`.
        public var path: String

        public var name: String {
            FilePlanner.split(path).name
        }

        public var sourceName: String {
            FilePlanner.split(source).name
        }
    }

    /// A photo: its files go together, a raw with its JPEG and the sidecars named after them.
    public struct Item: Sendable, Hashable, Codable {
        public var photo: String
        public var source: String
        public var captured: Date
        public var copies: [Copy]
        public var choices: ImportChoices
        /// Its own keywords, from its file and other apps' `.xmp`.
        public var keywords: [String]
        /// The number its name was given to tell it from another photo's or a file's.
        public var numbered: Int?
        /// The name tokens that came out empty for it.
        public var emptyTokens: [String]
        /// Its own title, caption, creator, copyright and location, from its file and other apps' `.xmp`,
        /// which the metadata preset's fields add to (LIB-22); nil when the import ticks none.
        public var fields: XMPFields?

        /// Its photo files: a raw, its JPEG.
        public var photos: [Copy] {
            copies.filter { $0.role == .photo }
        }

        public var bytes: Int64 {
            copies.reduce(0) { $0 + $1.size }
        }
    }

    /// Why a file stays on its source.
    public enum Reason: String, Sendable, Hashable, Codable, CaseIterable {
        /// The user left its photo out.
        case notChosen
        /// The library has it: its content key is a photo's there.
        case imported
        /// The folder it would go in holds it already: a file of its size and content key.
        case atDestination
        /// It isn't a raw, and only raws are imported.
        case rawOnly
        /// Its first bytes couldn't be read.
        case unreadable
        /// Something that isn't a folder is where its folder would be.
        case blocked
    }

    public struct Left: Sendable, Hashable, Codable {
        public var photo: String
        /// The photo file's path on its source.
        public var file: String
        public var reason: Reason
    }

    public var id: UUID
    public var created: Date
    public var settings: ImportSettings
    public var sources: [Source]
    /// In capture order, as they're named and copied.
    public var items: [Item]
    public var left: [Left]
    /// The folders below the destination and the backup that photos go in, parents first.
    public var folders: [String]
    /// The named counters once the import is done.
    public var counters: NamingCounters
    /// What stops parts of the plan, as sentences: a file where a folder would go.
    public var problems: [String]

    public init(
        id: UUID = UUID(), created: Date = Date(), settings: ImportSettings, sources: [Source], items: [Item],
        left: [Left] = [], folders: [String] = [], counters: NamingCounters = NamingCounters(),
        problems: [String] = [],
    ) {
        self.id = id
        self.created = created
        self.settings = settings
        self.sources = sources
        self.items = items
        self.left = left
        self.folders = folders
        self.counters = counters
        self.problems = problems
    }

    public var files: Int {
        items.reduce(0) { $0 + $1.copies.count }
    }

    public var bytes: Int64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    public var numbered: Int {
        items.count { $0.numbered != nil }
    }

    /// Where `copy` goes at the destination, then at the backup.
    public func targets(of copy: Copy) -> [URL] {
        ([settings.destination] + (settings.backup.map { [$0] } ?? [])).map { root in
            URL(fileURLWithPath: LibraryIndexer.path(root) + "/" + copy.path, isDirectory: copy.isDirectory)
        }
    }

    /// The photo files `reason` leaves on the sources.
    public func left(_ reason: Reason) -> Int {
        left.count { $0.reason == reason }
    }
}

/// Works out an `ImportPlan` from a session's photos: folders from the folder template's levels,
/// names from the naming template with every photo going to one folder told apart in capture order,
/// against the files already at the destination and the backup.
///
/// It blocks on the destinations' file system: use it off the caller.
struct ImportPlanner {
    let settings: ImportSettings
    let fileSystem: any LibraryFileSystem
    let date: Date

    private struct Unit {
        var photo: ImportPhoto
        /// Its photo files to copy.
        var files: [ImportFile]
        var folder = ""
    }

    /// `others` counts each source's files that aren't photos, by source.
    func plan(_ photos: [ImportPhoto], sources: [ImportSource], others: [String: Int] = [:]) -> ImportPlan {
        var left: [ImportPlan.Left] = []
        func leave(_ photo: ImportPhoto, _ files: [ImportFile], _ reason: ImportPlan.Reason) {
            left += Self.left(photo, files, reason)
        }
        var units = chosenUnits(of: photos, leaving: &left)

        let context = NamingContext(date: date, texts: settings.texts)
        let levels = settings.folderLevels.map { level in
            NamingJob(units.enumerated().map { number, unit in
                NamingPhoto(fields(unit, unit.files[0]), destination: "/\(number)")
            }).names(level, options: settings.naming, context: context, counters: settings.counters)
        }
        for index in units.indices {
            units[index].folder = levels.compactMap { batch -> String? in
                let result = batch.results[index]
                return result.adjustments.contains(.keptName) ? nil : result.base
            }.joined(separator: "/")
        }

        var problems: [String] = []
        let destination = LibraryIndexer.path(settings.destination)
        let backup = settings.backup.map(LibraryIndexer.path)
        var listings: [String: [FileEntry]?] = [:]
        func listing(_ path: String) -> [FileEntry]? {
            if let known = listings[path] {
                return known
            }
            let found: [FileEntry]?
            do {
                found = try fileSystem.contentsOfDirectory(at: URL(fileURLWithPath: path, isDirectory: true))
            } catch where VolumeIO.isNotFound(error) && !isFile(path) {
                found = []
            } catch {
                found = nil
                problems.append("\(path) can't be listed: \(ImportCopyError.message(error))")
            }
            listings[path] = .some(found)
            return found
        }
        var kept: [Unit] = []
        for var unit in units {
            let folder = Self.join(destination, unit.folder)
            guard let entries = listing(folder),
                  backup.map({ listing(Self.join($0, unit.folder)) != nil }) ?? true else {
                leave(unit.photo, unit.files, .blocked)
                continue
            }
            let there = unit.files.filter { isThere($0, in: folder, entries: entries) }
            leave(unit.photo, there, .atDestination)
            unit.files.removeAll { there.contains($0) }
            if !unit.files.isEmpty {
                kept.append(unit)
            }
        }
        units = kept

        var existing: [String: Set<String>] = [:]
        for unit in units {
            let folder = Self.join(destination, unit.folder)
            guard existing[folder] == nil else { continue }
            var names = Set((listing(folder) ?? []).map(\.name))
            if let backup {
                names.formUnion((listing(Self.join(backup, unit.folder)) ?? []).map(\.name))
            }
            existing[folder] = names
        }
        var named: [NamingPhoto] = []
        for unit in units {
            for file in unit.files {
                named.append(NamingPhoto(fields(unit, file), destination: Self.join(destination, unit.folder)))
            }
        }
        let batch = NamingJob(named, existing: existing).names(
            settings.names, options: settings.naming, context: context, counters: settings.counters,
        )
        let tokens = settings.names.tokens

        var items: [ImportPlan.Item] = []
        var result = 0
        var folders = Set<String>()
        for unit in units {
            let photo = unit.photo
            var copies: [ImportPlan.Copy] = []
            var renamed: [String: String] = [:]
            var numbered: Int?
            var empty: [String] = []
            for file in unit.files {
                let naming = batch.results[result]
                result += 1
                renamed[NamingJob.fold(file.name)] = naming.name
                numbered = numbered ?? naming.collision?.suffix
                empty += naming.emptyTokens.map { tokens[$0].description }.filter { !empty.contains($0) }
                copies.append(copy(file, of: photo, to: Self.join(unit.folder, naming.name)))
            }
            let base = NamingJob.split(copies[0].name).base
            let stem = NamingJob.fold(NamingJob.split(unit.files[0].name).base)
            for file in photo.files where file.role != .photo {
                let folded = NamingJob.fold(file.name)
                let (owner, ext) = NamingJob.split(folded)
                let newName: String? = if let photoName = renamed[owner] {
                    photoName + "." + NamingJob.split(file.name).ext
                } else if owner == stem {
                    base + "." + NamingJob.split(file.name).ext
                } else {
                    nil
                }
                if let newName, NamingJob.sidecarExtensions.contains(ext) {
                    copies.append(copy(file, of: photo, to: Self.join(unit.folder, newName)))
                }
            }
            var level = ""
            for part in unit.folder.split(separator: "/") {
                level = level.isEmpty ? String(part) : level + "/" + part
                folders.insert(level)
            }
            items.append(ImportPlan.Item(
                photo: photo.id, source: photo.source, captured: photo.captured, copies: copies,
                choices: photo.choices, keywords: Self.ownKeywords(of: photo), numbered: numbered, emptyTokens: empty,
                fields: settings.metadata.fields.isEmpty ? nil : Self.ownFields(of: photo),
            ))
        }
        let sourceOf = Dictionary(photos.map { ($0.id, $0.source) }) { first, _ in first }
        var unimported: [String: Set<String>] = [:]
        for entry in left where entry.reason == .unreadable || entry.reason == .blocked {
            unimported[sourceOf[entry.photo] ?? "", default: []].insert(entry.photo)
        }
        let used = Set(photos.map(\.source))
        return ImportPlan(
            created: date, settings: settings,
            sources: sources.filter { used.contains($0.id) }.map { source in
                ImportPlan.Source(
                    source, unimported: unimported[source.id]?.count ?? 0, otherFiles: others[source.id] ?? 0,
                )
            },
            items: items, left: left, folders: folders.sorted(), counters: batch.counters, problems: problems,
        )
    }

    /// The photos chosen, each with its photo files left to copy, in the order they were taken; the files they
    /// leave out go in `left`.
    private func chosenUnits(of photos: [ImportPhoto], leaving left: inout [ImportPlan.Left]) -> [Unit] {
        var units: [Unit] = []
        for photo in photos {
            guard photo.choices.isChosen else {
                left += Self.left(photo, photo.photoFiles, .notChosen)
                continue
            }
            guard photo.isRead, photo.files.contains(where: { $0.contentKey != nil }) else {
                left += Self.left(photo, photo.photoFiles, .unreadable)
                continue
            }
            var files = photo.photoFiles
            if settings.rawOnly {
                left += Self.left(photo, files.filter { !$0.isRaw }, .rawOnly)
                files.removeAll { !$0.isRaw }
            }
            if settings.skipsImported {
                left += Self.left(photo, files.filter { photo.imported.contains($0.name) }, .imported)
                files.removeAll { photo.imported.contains($0.name) }
            }
            if !files.isEmpty {
                units.append(Unit(photo: photo, files: files))
            }
        }
        units.sort { first, second in
            first.photo.captured != second.photo.captured
                ? first.photo.captured < second.photo.captured : first.photo.id < second.photo.id
        }
        return units
    }

    private static func left(
        _ photo: ImportPhoto,
        _ files: [ImportFile],
        _ reason: ImportPlan.Reason,
    ) -> [ImportPlan.Left] {
        files.map { ImportPlan.Left(photo: photo.id, file: photo.folder + "/" + $0.name, reason: reason) }
    }

    /// What naming knows of one of a photo's files: its own name and date, its photo's metadata, the
    /// choices made for it and the keywords it gets.
    private func fields(_ unit: Unit, _ file: ImportFile) -> NamingFields {
        let photo = unit.photo
        var fields = NamingFields(
            name: file.name, folder: photo.folder, metadata: photo.metadata ?? CaptureMetadata(),
            modified: file.modified,
        )
        if fields.captured == nil {
            fields.captured = ImportPhoto.wallClock(file.modified)
        }
        fields.rating = photo.choices.rating
        fields.flag = photo.choices.flag
        fields.label = photo.choices.label.map(NamingFields.labelName)
        fields.keywords = KeywordPath.texts(Self.ownKeywords(of: photo) + settings.metadata.keywords)
        return fields
    }

    private func copy(_ file: ImportFile, of photo: ImportPhoto, to path: String) -> ImportPlan.Copy {
        ImportPlan.Copy(
            source: photo.folder + "/" + file.name, role: file.role, size: file.size, modified: file.modified,
            isDirectory: file.isDirectory, contentKey: file.contentKey, path: path,
        )
    }

    /// Whether `folder`'s `entries` hold `file` already: an entry of its size whose first bytes give its
    /// content key.
    private func isThere(_ file: ImportFile, in folder: String, entries: [FileEntry]) -> Bool {
        guard let key = file.contentKey else { return false }
        return entries.contains { entry in
            guard !entry.isDirectory, entry.size == file.size,
                  let head = try? fileSystem.read(
                      URL(fileURLWithPath: folder + "/" + entry.name, isDirectory: false),
                      range: 0 ..< ContentKey.headLength,
                  )
            else { return false }
            return ContentKey(fileSize: Int(entry.size), head: head) == key
        }
    }

    private func isFile(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if let entry = try? fileSystem.attributes(of: url) {
                return !entry.isDirectory
            }
            url = url.deletingLastPathComponent()
        }
        return false
    }

    static func ownKeywords(of photo: ImportPhoto) -> [String] {
        LibraryIndexer.Run.organising(photo.metadata, sidecar: nil, xmp: photo.xmp).fields.keywords ?? []
    }

    static func ownFields(of photo: ImportPhoto) -> XMPFields {
        let own = LibraryIndexer.Run.organising(photo.metadata, sidecar: nil, xmp: photo.xmp).fields
        return XMPFields(
            title: own.title, caption: own.caption, creator: own.creator, copyright: own.copyright,
            location: own.location,
        )
    }

    static func join(_ folder: String, _ path: String) -> String {
        path.isEmpty ? folder : folder.isEmpty ? path : folder + "/" + path
    }
}
