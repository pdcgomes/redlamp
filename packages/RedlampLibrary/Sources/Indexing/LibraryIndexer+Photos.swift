import Foundation
import RedlampDocument
import RedlampEngineAPI

extension LibraryIndexer.Run {
    /// What's read through the volume's readers before ImageIO or `SidecarStore` reads a file
    /// itself, at most: all that ImageIO reads of the raws whose heads don't hold their metadata
    /// (16 to 740 KB), and a whole sidecar. They then read it from memory, on the scheduler's lanes,
    /// without holding a place on the volume while they parse.
    static let chargedFileRead = 1 << 20

    func process(_ job: LibraryIndexer.PhotoJob, on volume: LibraryIndexer.VolumeWork) async throws {
        let first = indexer.prioritised.contains(job.folder)
        let priority: VolumeIO.Priority = first ? .high : .normal
        let lane: WorkScheduler.Lane = first ? .onScreen : .background
        guard let job = await placed(job) else { return }
        switch job.kind {
        case .new:
            if let move = try await move(job, on: volume, priority: priority, lane: lane) {
                await batcher.add([.move(move)])
                return
            }
            let photo = try await read(job, on: volume, priority: priority, lane: lane)
            count(photo, in: job.folder)
            await batcher.add([.photo(photo)])
        case .changed:
            let photo = try await read(job, on: volume, priority: priority, lane: lane)
            count(photo, in: job.folder)
            await batcher.add([.photo(photo)])
        case .sidecar:
            guard var record = job.existing,
                  let sidecar = try await sidecar(of: job, on: volume, priority: priority, lane: lane)
            else {
                let photo = try await read(job, on: volume, priority: priority, lane: lane)
                count(photo, in: job.folder)
                return await batcher.add([.photo(photo)])
            }
            record.rating = sidecar.summary.metadata.rating
            record.flag = sidecar.summary.metadata.flag
            record.label = sidecar.summary.metadata.label
            record.edited = sidecar.summary.hasEdits
            record.sidecarModified = sidecar.modified
            record.state = []
            record.fileID = job.entry.fileIdentifier
            let photo = LibraryIndexer.PendingPhoto(folder: job.folder, record: record, isNew: false)
            count(photo, in: job.folder)
            await batcher.add([.photo(photo)])
        case .refresh:
            guard var record = job.existing else { return }
            record.state = []
            record.fileID = job.entry.fileIdentifier
            let photo = LibraryIndexer.PendingPhoto(folder: job.folder, record: record, isNew: false)
            count(photo, in: job.folder)
            await batcher.add([.photo(photo)])
        }
    }

    private func count(_ photo: LibraryIndexer.PendingPhoto, in folder: String) {
        state.withLock { state in
            if photo.isNew {
                state.work[folder]?.inserted += 1
            } else {
                state.work[folder]?.updated += 1
            }
        }
    }

    // MARK: - Reading a photo

    /// Reads the photo's head once, for its content key and metadata, and what its sidecars say.
    func read(
        _ job: LibraryIndexer.PhotoJob, on volume: LibraryIndexer.VolumeWork, priority: VolumeIO.Priority,
        lane: WorkScheduler.Lane,
    ) async throws -> LibraryIndexer.PendingPhoto {
        let io = volume.io
        let url = URL(fileURLWithPath: job.folder + "/" + job.entry.name, isDirectory: false)
        let size = Int(job.entry.size)
        let head = try await io.read(url, range: 0 ..< PhotoMetadataReader.headLength, priority: priority)
        state.withLock { $0.summary.headsRead += 1 }
        var xmpData: Data?
        if let xmp = job.xmp {
            let xmpURL = URL(fileURLWithPath: job.folder + "/" + xmp.name, isDirectory: false)
            xmpData = try await Self.ignoringMissing {
                try await io.read(xmpURL, range: 0 ..< max(Int(xmp.size), 1), priority: priority)
            }
        }
        let read = xmpData
        var parsed = try await indexer.scheduler.run(lane) {
            Self.parse(head: head, size: size, url: url, xmp: read)
        }
        if parsed.needsFile {
            let headLength = PhotoMetadataReader.headLength
            if size > headLength {
                _ = try await io.read(url, range: headLength ..< min(size, Self.chargedFileRead), priority: priority)
            }
            parsed.metadata = try await indexer.scheduler.run(lane) { PhotoMetadataReader.read(url: url) }
        }
        let sidecar = try await sidecar(of: job, on: volume, priority: priority, lane: lane)
        var record = Self.record(
            job, key: parsed.key, metadata: parsed.metadata, sidecar: sidecar?.summary, xmp: parsed.xmp,
        )
        if let sidecar {
            record.sidecarModified = sidecar.modified
        }
        record.marked = job.existing?.marked ?? false
        let metadata = parsed.metadata
        let keywords = Self.organising(metadata, sidecar: sidecar?.summary, xmp: parsed.xmp).keywords
        return LibraryIndexer.PendingPhoto(
            folder: job.folder, record: record,
            camera: metadata?.cameraName.map {
                LibraryIndexer.CameraName(name: $0, make: metadata?.make, model: metadata?.model)
            },
            lens: metadata?.lens, keywords: keywords, isNew: job.existing == nil,
            thumbnail: indexer.thumbnails == nil ? nil : LibraryIndexer.Thumbnail(
                url: url,
                key: parsed.key,
                head: head,
            ),
        )
    }

    /// What the photo's `.redlamp` sidecar says and when it was saved, read where the root's locator
    /// finds it: beside the photo, as the listing found it, or on this Mac. Nil when there's none or
    /// it can't be read.
    func sidecar(
        of job: LibraryIndexer.PhotoJob, on volume: LibraryIndexer.VolumeWork, priority: VolumeIO.Priority,
        lane: WorkScheduler.Lane,
    ) async throws -> ReadSidecar? {
        let photo = URL(fileURLWithPath: job.folder + "/" + job.entry.name, isDirectory: false)
        let locator = await sidecarLocator()
        let mac = locator.onThisMac(photo)
        guard job.sidecar != nil || mac != nil else { return nil }
        if let entry = job.sidecar {
            let package = URL(fileURLWithPath: job.folder + "/" + entry.name, isDirectory: entry.isDirectory)
            let edit = entry.isDirectory ? package.appending(path: SidecarStore.editFile) : package
            _ = try await Self.ignoringMissing {
                try await volume.io.read(edit, range: 0 ..< Self.chargedFileRead, priority: priority)
            }
        }
        let beside = job.sidecar?.modified
        return try await indexer.scheduler.run(lane) {
            let saved = mac.flatMap(Self.modified)
            let read: (url: URL, modified: Date?)
            if let mac, let saved {
                let url = beside == nil ? mac : locator.readURL(for: photo)
                read = url == mac ? (mac, saved) : (url, beside)
            } else if beside != nil {
                read = (SidecarLocator.besidePhoto(photo), beside)
            } else {
                return nil
            }
            return SidecarStore.summary(atSidecar: read.url).map { ReadSidecar(summary: $0, modified: read.modified) }
        }
    }

    /// A photo's sidecar as read: what it says, and when it was saved.
    struct ReadSidecar: Sendable {
        let summary: SidecarSummary
        let modified: Date?
    }

    /// The locator this run reads sidecars through.
    func sidecarLocator() async -> SidecarLocator {
        await IndexerSidecars.locator(for: self, index: indexer.index)
    }

    /// The job as comparing the folder's listing with its rows would have made it had the listing
    /// held the photo's sidecar on this Mac: a photo whose sidecar is missing from beside it only
    /// because it's on this Mac isn't read again. Nil when that leaves nothing to do.
    private func placed(_ job: LibraryIndexer.PhotoJob) async -> LibraryIndexer.PhotoJob? {
        guard job.kind == .changed, job.sidecar == nil, let row = job.existing, let recorded = row.sidecarModified,
              row.size == job.entry.size, Self.same(row.modified, job.entry.modified), row.indexed != 0,
              Self.same(row.xmpModified, job.xmp?.modified)
        else { return job }
        let photo = URL(fileURLWithPath: job.folder + "/" + job.entry.name, isDirectory: false)
        guard let mac = await sidecarLocator().onThisMac(photo), let saved = Self.modified(mac) else { return job }
        let kind: LibraryIndexer.PhotoJob.Kind
        if !Self.same(recorded, saved) {
            kind = .sidecar
        } else if !row.state.isEmpty || row.fileID != job.entry.fileIdentifier {
            kind = .refresh
        } else {
            return nil
        }
        return LibraryIndexer.PhotoJob(
            kind: kind, folder: job.folder, entry: job.entry, existing: row, sidecar: nil, xmp: job.xmp,
        )
    }

    /// When the sidecar at `url` on this Mac was last saved; nil when there's none.
    static func modified(_ url: URL) -> Date? {
        try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    struct ParsedHead: Sendable {
        var key: ContentKey
        var metadata: CaptureMetadata?
        /// The head doesn't hold the file's metadata: ImageIO has to read the file itself.
        var needsFile: Bool
        var xmp: CaptureMetadata?
    }

    static func parse(head: Data, size: Int, url: URL, xmp: Data?) -> ParsedHead {
        let key = ContentKey(fileSize: size, head: head)
        let xmp = xmp.flatMap(XMPMetadata.parse)
        if head.count >= size {
            return ParsedHead(
                key: key, metadata: PhotoMetadataReader.read(head: head, fileSize: size, url: url), needsFile: false,
                xmp: xmp,
            )
        }
        let found = PhotoMetadataReader.headMetadata(head, fileSize: size, url: url)
        return ParsedHead(key: key, metadata: found, needsFile: found == nil, xmp: xmp)
    }

    /// `body`'s answer, or nil when the file it reads has gone since it was listed.
    static func ignoringMissing<T>(_ body: () async throws -> T) async throws -> T? {
        do {
            return try await body()
        } catch where VolumeIO.isNotFound(error) {
            return nil
        }
    }

    // MARK: - Rows

    /// The photo's row, from its listing and what was read: its rating, flag and label are its
    /// sidecar's, else its other app's `.xmp`'s, else its own XMP's; its keywords its own and its
    /// `.xmp`'s; its title and caption its `.xmp`'s, else its own.
    static func record(
        _ job: LibraryIndexer.PhotoJob, key: ContentKey, metadata: CaptureMetadata?, sidecar: SidecarSummary?,
        xmp: CaptureMetadata?,
    ) -> PhotoRecord {
        let organising = organising(metadata, sidecar: sidecar, xmp: xmp)
        return PhotoRecord(
            id: job.existing?.id ?? 0, folder: 0, name: job.entry.name, size: job.entry.size,
            modified: job.entry.modified, fileID: job.entry.fileIdentifier, contentKey: key.data,
            captured: metadata?.captured, capturedOffset: metadata?.capturedOffset, iso: metadata?.iso,
            aperture: metadata?.aperture, shutter: metadata?.shutter, focal: metadata?.focalLength,
            width: metadata?.pixelSize?.width, height: metadata?.pixelSize?.height, orientation: metadata?.orientation,
            latitude: metadata?.latitude, longitude: metadata?.longitude, rating: organising.rating,
            flag: organising.flag, label: organising.label, edited: sidecar?.hasEdits ?? false,
            sidecarModified: job.sidecar?.modified, xmpModified: job.xmp?.modified, title: organising.title,
            caption: organising.caption, indexed: 1,
        )
    }

    struct Organising {
        var rating: Int
        var flag: PhotoFlag?
        var label: ColorLabel?
        var keywords: [String]
        var title: String?
        var caption: String?
    }

    static func organising(
        _ embedded: CaptureMetadata?,
        sidecar: SidecarSummary?,
        xmp: CaptureMetadata?,
    ) -> Organising {
        let other = xmp?.rating ?? embedded?.rating
        let otherLabel = (xmp?.label ?? embedded?.label).flatMap { name in
            ColorLabel.allCases.first { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }
        }
        var keywords: [String] = []
        var seen = Set<String>()
        for keyword in (embedded?.keywords ?? []) + (xmp?.keywords ?? []) where seen.insert(keyword).inserted {
            if keyword.split(separator: "/").contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                keywords.append(keyword)
            }
        }
        return Organising(
            rating: sidecar?.metadata.rating ?? max(other ?? 0, 0),
            flag: sidecar.map(\.metadata.flag) ?? (other == -1 ? .reject : nil),
            label: sidecar.map(\.metadata.label) ?? otherLabel,
            keywords: keywords,
            title: xmp?.title ?? embedded?.title,
            caption: xmp?.caption ?? embedded?.caption,
        )
    }

    // MARK: - Renames and moves

    /// The move that explains a photo new to its folder: a row on the same volume, with its file
    /// identifier, size and date, whose own name is gone. Nil when there's none, and the photo is new.
    func move(
        _ job: LibraryIndexer.PhotoJob, on volume: LibraryIndexer.VolumeWork, priority: VolumeIO.Priority,
        lane: WorkScheduler.Lane,
    ) async throws -> LibraryIndexer.PendingMove? {
        guard let file = job.entry.fileIdentifier else { return nil }
        let key = LibraryIndexer.FileKey(volume: volume.id, file: file)
        let claimed = state.withLock { state -> PhotoRecord? in
            for id in state.vanishedByFile[key] ?? [] {
                guard let vanished = state.vanished[id], matches(vanished.record, job.entry) else { continue }
                return claim(id, &state) ? vanished.record : nil
            }
            return nil
        }
        if let claimed {
            return try await moved(claimed, to: job, on: volume, priority: priority, lane: lane)
        }
        let candidates = try await indexer.index.read { try $0.photos(fileID: file, volume: volume.id) }
        for candidate in candidates where matches(candidate, job.entry) {
            guard let folder = try await path(ofFolder: candidate.folder),
                  folder != job.folder || candidate.name != job.entry.name,
                  try await isGone(candidate.name, from: folder, on: volume, priority: priority),
                  state.withLock({ claim(candidate.id, &$0) })
            else { continue }
            return try await moved(candidate, to: job, on: volume, priority: priority, lane: lane)
        }
        return nil
    }

    private func matches(_ record: PhotoRecord, _ entry: FileEntry) -> Bool {
        record.size == entry.size && Self.same(record.modified, entry.modified)
    }

    /// Takes the row as moved, unless another photo took it first.
    private func claim(_ id: Int64, _ state: inout LibraryIndexer.RunState) -> Bool {
        guard state.moved.insert(id).inserted else { return false }
        if let vanished = state.vanished.removeValue(forKey: id), let file = vanished.record.fileID {
            let key = LibraryIndexer.FileKey(volume: vanished.volume, file: file)
            state.vanishedByFile[key]?.removeAll { $0 == id }
        }
        return true
    }

    /// The row moved to the job's name, and read again when what's beside it there isn't what was
    /// beside it before (a sidecar left behind).
    private func moved(
        _ record: PhotoRecord, to job: LibraryIndexer.PhotoJob, on volume: LibraryIndexer.VolumeWork,
        priority: VolumeIO.Priority, lane: WorkScheduler.Lane,
    ) async throws -> LibraryIndexer.PendingMove {
        var replacement: LibraryIndexer.PendingPhoto?
        if !Self.same(record.sidecarModified, job.sidecar?.modified) || !Self.same(
            record.xmpModified,
            job.xmp?.modified,
        ) {
            let existing = LibraryIndexer.PhotoJob(
                kind: .changed, folder: job.folder, entry: job.entry, existing: record, sidecar: job.sidecar,
                xmp: job.xmp,
            )
            replacement = try await read(existing, on: volume, priority: priority, lane: lane)
            replacement?.thumbnail = nil
        }
        state.withLock { $0.work[job.folder]?.updated += 1 }
        return LibraryIndexer.PendingMove(
            id: record.id,
            folder: job.folder,
            name: job.entry.name,
            replacement: replacement,
        )
    }

    private func path(ofFolder id: Int64) async throws -> String? {
        if let path = state.withLock({ $0.paths[id] }) {
            return path
        }
        let path = try await indexer.index.read { try $0.folder(id: id)?.path }
        if let path {
            state.withLock { $0.paths[id] = path }
        }
        return path
    }

    /// Whether `folder` no longer holds `name`: from its listing in this run, or listing it now.
    private func isGone(
        _ name: String, from folder: String, on volume: LibraryIndexer.VolumeWork, priority: VolumeIO.Priority,
    ) async throws -> Bool {
        let known = state.withLock { state -> Bool? in
            if state.unchanged.contains(folder) {
                return false
            }
            if let names = state.names[folder] {
                return !names.contains(name)
            }
            if let probed = state.probed[folder] {
                return probed.map { !$0.contains(name) } ?? true
            }
            return nil
        }
        if let known {
            return known
        }
        let names: Set<String>?
        do {
            let entries = try await volume.io.contentsOfDirectory(
                at: URL(fileURLWithPath: folder, isDirectory: true), priority: priority,
            )
            names = Set(entries.filter(FolderWalk.isPhoto).map(\.name))
        } catch where VolumeIO.isNotFound(error) {
            names = nil
        }
        state.withLock { $0.probed[folder] = .some(names) }
        return names.map { !$0.contains(name) } ?? true
    }
}

extension LibraryIndexer {
    struct CameraName: Sendable, Hashable {
        let name: String
        let make: String?
        let model: String?
    }

    struct Thumbnail: Sendable {
        let url: URL
        let key: ContentKey
        let head: Data
    }

    /// A row to write, with what's resolved to IDs as it's written.
    struct PendingPhoto: Sendable {
        let folder: String
        var record: PhotoRecord
        /// The camera and lens to look up; nil keeps the row's.
        var camera: CameraName?
        var lens: String?
        /// The photo's keywords; nil keeps the row's.
        var keywords: [String]?
        var isNew: Bool
        var thumbnail: Thumbnail?

        init(
            folder: String, record: PhotoRecord, camera: CameraName? = nil, lens: String? = nil,
            keywords: [String]? = nil, isNew: Bool, thumbnail: Thumbnail? = nil,
        ) {
            self.folder = folder
            self.record = record
            self.camera = camera
            self.lens = lens
            self.keywords = keywords
            self.isNew = isNew
            self.thumbnail = thumbnail
        }
    }

    /// A row renamed or moved, keeping its ID, and what replaces its fields when it was read again.
    struct PendingMove: Sendable {
        let id: Int64
        let folder: String
        let name: String
        var replacement: PendingPhoto?
    }
}
