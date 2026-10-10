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
                volume.ends.add(move.replacement?.endCheck.map { [$0] } ?? [])
                return
            }
            let photo = try await read(job, on: volume, priority: priority, lane: lane)
            await written(photo, in: job.folder, on: volume)
        case .changed:
            let photo = try await read(job, on: volume, priority: priority, lane: lane)
            await written(photo, in: job.folder, on: volume)
        case .sidecar:
            guard var record = job.existing,
                  let sidecar = try await sidecar(of: job, on: volume, priority: priority, lane: lane)
            else {
                let photo = try await read(job, on: volume, priority: priority, lane: lane)
                return await written(photo, in: job.folder, on: volume)
            }
            guard let changed = Self.organising(afterSidecar: sidecar.summary, of: job, row: record) else {
                var photo = try await read(job, on: volume, priority: priority, lane: lane, sidecar: sidecar)
                photo.thumbnail = nil
                return await written(photo, in: job.folder, on: volume)
            }
            Self.show(changed.organising, in: &record)
            Self.place(sidecar.summary.metadata, in: &record)
            record.edited = sidecar.summary.hasEdits
            record.sidecarModified = sidecar.modified
            record.state = []
            record.missingSince = nil
            record.fileID = job.entry.fileIdentifier
            var photo = LibraryIndexer.PendingPhoto(
                folder: job.folder, record: record, keywords: changed.keywords,
                collections: sidecar.summary.metadata.collections, isNew: false,
            )
            photo.listed = job.existing
            count(photo, in: job.folder)
            await batcher.add([.photo(photo)])
        case .refresh:
            guard var record = job.existing else { return }
            record.state = []
            record.missingSince = nil
            record.fileID = job.entry.fileIdentifier
            var photo = LibraryIndexer.PendingPhoto(folder: job.folder, record: record, isNew: false)
            photo.listed = job.existing
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
            if photo.record.state.contains(.unreadable) {
                state.summary.photosUnreadable += 1
            }
        }
    }

    /// Hands `photo` to the batcher, then its end to the volume's end reads: its row is written
    /// before the end's result, which needs it.
    private func written(
        _ photo: LibraryIndexer.PendingPhoto, in folder: String, on volume: LibraryIndexer.VolumeWork,
    ) async {
        count(photo, in: folder)
        await batcher.add([.photo(photo)])
        if let check = photo.endCheck {
            volume.ends.add([check])
        }
    }

    // MARK: - Reading a photo

    /// Reads the photo's head once, for its content key, metadata and health (LIB-40), other apps'
    /// `.xmp` beside it, and what its `.redlamp` says (`known`, when it's been read). An empty file
    /// isn't read, and one that can't be read for a reason other than its being gone or its volume
    /// away is written as unreadable, with the reader's reason, rather than failing its folder: only
    /// such a photo is left out of lists.
    func read(
        _ job: LibraryIndexer.PhotoJob, on volume: LibraryIndexer.VolumeWork, priority: VolumeIO.Priority,
        lane: WorkScheduler.Lane, sidecar known: ReadSidecar? = nil,
    ) async throws -> LibraryIndexer.PendingPhoto {
        let io = volume.io
        let url = URL(fileURLWithPath: job.folder + "/" + job.entry.name, isDirectory: false)
        let size = Int(job.entry.size)
        var head: Data?
        var damage: PhotoHealth.Damage?
        if size == 0 {
            damage = .empty
        } else {
            do {
                head = try await io.read(url, range: 0 ..< PhotoMetadataReader.headLength, priority: priority)
                state.withLock { $0.summary.headsRead += 1 }
            } catch where Self.isDamage(error, on: io) {
                damage = .unreadable(PhotoHealth.reason(for: error))
            }
        }
        func contents(_ xmp: FileEntry?) async throws -> Data? {
            guard let xmp else { return nil }
            let xmpURL = URL(fileURLWithPath: job.folder + "/" + xmp.name, isDirectory: false)
            return try await Self.ignoringMissing {
                try await io.read(xmpURL, range: 0 ..< max(Int(xmp.size), 1), priority: priority)
            }
        }
        let (xmp, darktable) = try await (contents(job.xmp), contents(job.darktable))
        let conventions = state.withLock { $0.conventions }
        var parsed: ParsedHead?
        var bytes = FileBytes()
        if let head {
            bytes.add(head, at: 0)
            parsed = try await indexer.scheduler.run(lane) {
                Self.parse(head: head, size: size, url: url, xmp: xmp, darktable: darktable, conventions: conventions)
            }
        } else {
            parsed = nil
        }
        if parsed?.needsFile == true {
            let headLength = PhotoMetadataReader.headLength
            do {
                if size > headLength {
                    let more = try await io.read(
                        url, range: headLength ..< min(size, Self.chargedFileRead), priority: priority,
                    )
                    bytes.add(more, at: headLength)
                }
                parsed?.metadata = try await indexer.scheduler.run(lane) {
                    PhotoMetadataReader.read(url: url, conventions: conventions)
                }
            } catch where Self.isDamage(error, on: io) {
                damage = .unreadable(PhotoHealth.reason(for: error))
            }
        }
        var health = PhotoHealth(size: job.entry.size, modified: job.entry.modified, damage: damage)
        var endCheck: LibraryIndexer.EndCheck?
        if damage == nil, let head, let parsed {
            let read = bytes
            (health, endCheck) = try await indexer.scheduler.run(lane) {
                Self.health(of: job, head: head, bytes: read, readable: parsed.metadata != nil)
            }
        }
        var others = (parsed?.xmp, parsed?.darktable)
        if parsed == nil {
            others = try await indexer.scheduler.run(lane) {
                (
                    xmp.flatMap { XMPMetadata.parse($0, conventions: conventions) },
                    darktable.flatMap { XMPMetadata.parse($0, conventions: conventions) },
                )
            }
        }
        var sidecar = known
        if sidecar == nil {
            sidecar = try await self.sidecar(of: job, on: volume, priority: priority, lane: lane)
        }
        let unreadable = if case .unreadable = health.damage {
            true
        } else {
            false
        }
        let metadata = unreadable ? nil : parsed?.metadata
        let organising = Self.organising(
            metadata, sidecar: sidecar?.summary, xmp: others.0, darktable: others.1, merged: job.merged,
            otherIsLater: XMPMerge.otherIsLater(
                job.merged, sidecar: job.xmp.map(XMPFileStamp.init), darktable: job.darktable.map(XMPFileStamp.init),
                photo: XMPFileStamp(job.entry), redlampSaved: sidecar?.modified,
            ),
        )
        let key = head == nil ? nil : parsed?.key
        var record = Self.record(
            job, key: key, metadata: metadata, organising: organising,
            edited: sidecar?.summary.hasEdits ?? false,
        )
        if let sidecar {
            record.sidecarModified = sidecar.modified
        }
        if unreadable {
            record.state = [.unreadable]
        }
        Self.place(sidecar?.summary.metadata ?? PhotoMetadata(), in: &record)
        var thumbnail: LibraryIndexer.Thumbnail?
        if indexer.thumbnails != nil, !unreadable, let head, let key {
            thumbnail = LibraryIndexer.Thumbnail(url: url, key: key, head: head)
        }
        var photo = LibraryIndexer.PendingPhoto(
            folder: job.folder, record: record,
            camera: metadata?.cameraName.map {
                LibraryIndexer.CameraName(name: $0, make: metadata?.make, model: metadata?.model)
            },
            lens: metadata?.lens, keywords: organising.fields.keywords ?? [],
            collections: sidecar?.summary.metadata.collections ?? [], isNew: job.existing == nil, thumbnail: thumbnail,
        )
        photo.health = health
        photo.endCheck = endCheck
        photo.listed = job.existing
        return photo
    }

    /// Whether a failed read of a photo's file says the file is damaged: not gone, not on a volume
    /// that's away or stopped answering, and not a read given up on or cancelled.
    static func isDamage(_ error: any Error, on io: VolumeIO) -> Bool {
        !(error is CancellationError) && !(error is VolumeOperationTimedOut) && !VolumeIO.isNotFound(error)
            && !VolumeIO.isVolumeFailure(error) && io.isReachable
    }

    /// The photo's health from its head and what else has been read of it (`bytes`): the format its
    /// first bytes hold, the extension it takes when its name's doesn't fit, a start no image has
    /// when ImageIO read nothing either (`readable`), and how it ends, or the end check that will
    /// say.
    static func health(
        of job: LibraryIndexer.PhotoJob, head: Data, bytes: FileBytes, readable: Bool,
    ) -> (PhotoHealth, LibraryIndexer.EndCheck?) {
        let name = job.entry.name
        let format = PhotoFormat(head: head)
        var health = PhotoHealth(size: job.entry.size, modified: job.entry.modified, format: format)
        if format == .unknown {
            if !readable, PhotoFormat.formats(forExtension: (name as NSString).pathExtension) != nil {
                health.damage = .unrecognised
            }
            return (health, nil)
        }
        if !format.fits(name: name) {
            health.proposedExtension = format.proposedExtension(head: head)
        }
        switch FileEnd.judge(format, size: Int(job.entry.size), bytes: bytes) {
        case .whole:
            return (health, nil)
        case let .early(missing):
            health.damage = .endsEarly(missing: missing)
            return (health, nil)
        case let .needs(range):
            health.endUnread = true
            let check = LibraryIndexer.EndCheck(
                folder: job.folder, name: name, size: job.entry.size, modified: job.entry.modified, format: format,
                boxesFrom: format == .jpeg || format == .png ? 0 : range.lowerBound,
            )
            return (health, check)
        }
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
              row.xmpSignature == job.xmpSignature, !row.state.contains(.unreadable)
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
            darktable: job.darktable, merged: job.merged,
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
        /// What the `.xmp` the photos of its name share says (`IMG_1234.xmp`).
        var xmp: CaptureMetadata?
        /// What darktable's `.xmp` says (`IMG_1234.ARW.xmp`).
        var darktable: CaptureMetadata?
    }

    /// The photo's content key and metadata from its head, and what other apps' `.xmp` beside it
    /// say, read in `conventions`.
    static func parse(
        head: Data, size: Int, url: URL, xmp: Data?, darktable: Data? = nil,
        conventions: XMPConventions = XMPConventions(),
    ) -> ParsedHead {
        let key = ContentKey(fileSize: size, head: head)
        let xmp = xmp.flatMap { XMPMetadata.parse($0, conventions: conventions) }
        let darktable = darktable.flatMap { XMPMetadata.parse($0, conventions: conventions) }
        if head.count >= size {
            let metadata = PhotoMetadataReader.read(head: head, fileSize: size, url: url, conventions: conventions)
            return ParsedHead(key: key, metadata: metadata, needsFile: false, xmp: xmp, darktable: darktable)
        }
        let found = PhotoMetadataReader.headMetadata(head, fileSize: size, url: url, conventions: conventions)
        return ParsedHead(key: key, metadata: found, needsFile: found == nil, xmp: xmp, darktable: darktable)
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

    /// The photo's row, from its listing, what was read and its organising fields.
    static func record(
        _ job: LibraryIndexer.PhotoJob, key: ContentKey?, metadata: CaptureMetadata?, organising: Organising,
        edited: Bool,
    ) -> PhotoRecord {
        var record = PhotoRecord(
            id: job.existing?.id ?? 0, folder: 0, name: job.entry.name, size: job.entry.size,
            modified: job.entry.modified, fileID: job.entry.fileIdentifier, contentKey: key?.data,
            captured: metadata?.captured, capturedOffset: metadata?.capturedOffset, iso: metadata?.iso,
            aperture: metadata?.aperture, shutter: metadata?.shutter, focal: metadata?.focalLength,
            width: metadata?.pixelSize?.width, height: metadata?.pixelSize?.height, orientation: metadata?.orientation,
            latitude: metadata?.latitude, longitude: metadata?.longitude, edited: edited,
            sidecarModified: job.sidecar?.modified, xmpModified: job.xmpModified, indexed: 1,
            xmpSignature: job.xmpSignature,
        )
        show(organising, in: &record)
        return record
    }

    /// The fields a photo shows, merged from other apps' and its `.redlamp`'s, and which of them are
    /// other apps'.
    struct Organising {
        var fields: XMPFields
        var others: Set<XMPField>
    }

    /// Shows `organising` in the photo's row: empty texts and locations as none, a creator's names
    /// separated as XMP reads them, and the capture time shifted from the camera's time the row has.
    static func show(_ organising: Organising, in record: inout PhotoRecord) {
        let fields = organising.fields
        record.rating = fields.rating ?? 0
        record.flag = fields.flag
        record.label = fields.label
        record.customLabel = fields.label == nil ? XMPFields.text(fields.customLabel) : nil
        record.title = XMPFields.text(fields.title)
        record.caption = XMPFields.text(fields.caption)
        record.creator = XMPSource.joined(XMPFields.names(fields.creator))
        record.copyright = XMPFields.text(fields.copyright)
        record.location = XMPFields.place(fields.location)
        record.showCapture(shift: fields.captureShift ?? 0, offset: fields.captureOffset)
        record.otherFields = organising.others
    }

    /// What only the `.redlamp` holds, in the photo's row: the mark and its stack.
    static func place(_ metadata: PhotoMetadata, in record: inout PhotoRecord) {
        record.marked = metadata.mark
        record.stack = metadata.stack.flatMap { stack in
            stack.id == nil && !stack.top ? nil : PhotoStack(id: stack.id, top: stack.top, position: stack.position)
        }
    }

    /// The fields a photo's row shows, but its keywords.
    static func fields(of row: PhotoRecord) -> XMPFields {
        let shown = PhotoMetadata(shown: row)
        return XMPFields(
            rating: row.rating > 0 ? row.rating : nil, flag: row.flag, label: row.label, customLabel: row.customLabel,
            title: row.title, caption: row.caption, creator: row.creator, copyright: row.copyright,
            location: row.location, captureShift: shown.captureShift != 0 ? shown.captureShift : nil,
            captureOffset: shown.captureOffset,
        )
    }

    /// The fields the indexer shows from other apps and the `.redlamp`: those `LibraryXMP` merges, and
    /// the capture time.
    static let shownFields = XMPField.held.union([.captureTime])

    /// The photo's organising fields as `LibraryXMP` merges them (`XMPMerge`): other apps' value is
    /// its `.xmp`'s, then darktable's, then its own XMP's and IPTC's, field by field, a capture time
    /// being a shift from the one the photo's file records (`embedded`); its `.redlamp`'s
    /// stand where it holds them, an empty keyword list, title or location included, as the sidecar
    /// format has it, or, once `LibraryXMP` has merged the photo (`merged`), where other apps haven't
    /// changed them since.
    static func organising(
        _ embedded: CaptureMetadata?, sidecar: SidecarSummary?, xmp: CaptureMetadata?,
        darktable: CaptureMetadata? = nil, merged: XMPMergeRecord? = nil, otherIsLater: Bool = false,
    ) -> Organising {
        let camera = embedded?.captured.map { XMPCaptureTime(time: $0, offset: embedded?.capturedOffset) }
        func capturing(_ other: CaptureMetadata?) -> XMPSource? {
            let captured = other?.captured.map { XMPCaptureTime(time: $0, offset: other?.capturedOffset) }
            return other?.xmp?.capturing(captured, camera: camera)
        }
        var shown = XMPSource.combining([capturing(xmp), capturing(darktable), embedded?.xmp])
        guard let sidecar else {
            return Organising(fields: shown, others: Set(XMPField.allCases.filter(shown.holds)))
        }
        let merge = XMPMerge.merge(
            redlamp: XMPFields(sidecar.metadata), other: shown, record: merged, fields: shownFields,
            otherIsLater: otherIsLater,
        )
        for field in shownFields {
            shown.take(field, from: merge.fields)
        }
        return Organising(fields: shown, others: Set(merge.taken))
    }

    /// The organising fields of a photo whose `.redlamp` alone changed, from the `.redlamp` and the
    /// photo's row, without reading other apps' files again; their keywords nil where the row's stay.
    /// A field the `.redlamp` leaves open keeps the row's value when the row says it's other apps'
    /// (`otherFields`), whose files haven't changed, and a capture time it leaves open is the camera's
    /// when no other app's `.xmp` is beside the photo. Nil when other apps' fields are needed: they
    /// changed since `LibraryXMP`'s record, or, without one, the `.redlamp` leaves open a field whose value
    /// in the row was its own.
    static func organising(
        afterSidecar sidecar: SidecarSummary, of job: LibraryIndexer.PhotoJob, row: PhotoRecord,
    ) -> (organising: Organising, keywords: [String]?)? {
        let redlamp = XMPFields(sidecar.metadata)
        if let record = job.merged {
            guard XMPFileStamp.same(record.sidecar, job.xmp.map(XMPFileStamp.init)),
                  XMPFileStamp.same(record.darktable, job.darktable.map(XMPFileStamp.init)),
                  XMPFileStamp.same(record.photo, XMPFileStamp(job.entry))
            else { return nil }
            let merged = XMPMerge.merge(
                redlamp: redlamp, other: record.other, record: record, fields: shownFields, otherIsLater: false,
            )
            return (Organising(fields: merged.fields, others: Set(merged.taken)), merged.fields.keywords ?? [])
        }
        let shown = fields(of: row)
        var organising = Organising(fields: redlamp, others: [])
        for field in XMPField.allCases where field != .keywords && !redlamp.holds(field) && shown.holds(field) {
            if field == .captureTime, job.xmp == nil, job.darktable == nil {
                continue
            }
            guard row.otherFields.contains(field) else { return nil }
            organising.fields.take(field, from: shown)
            organising.others.insert(field)
        }
        if redlamp.keywords == nil, row.otherFields.contains(.keywords) {
            organising.others.insert(.keywords)
        }
        return (organising, sidecar.metadata.keywords.map(KeywordPath.texts))
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
    /// beside it before (a sidecar left behind), or its extension changed, which its format may no
    /// longer fit (LIB-40).
    private func moved(
        _ record: PhotoRecord, to job: LibraryIndexer.PhotoJob, on volume: LibraryIndexer.VolumeWork,
        priority: VolumeIO.Priority, lane: WorkScheduler.Lane,
    ) async throws -> LibraryIndexer.PendingMove {
        var replacement: LibraryIndexer.PendingPhoto?
        let besideChanged = !Self.same(record.sidecarModified, job.sidecar?.modified)
            || record.xmpSignature != job.xmpSignature
            || (record.name as NSString).pathExtension.lowercased()
            != (job.entry.name as NSString).pathExtension.lowercased()
        if besideChanged {
            let id = record.id
            var merged: XMPMergeRecord?
            if state.withLock({ $0.hasMergeRecords }) {
                merged = try await indexer.index.read { try XMPMergeRecord.records([id], in: $0)[id] }
            }
            let existing = LibraryIndexer.PhotoJob(
                kind: .changed, folder: job.folder, entry: job.entry, existing: record, sidecar: job.sidecar,
                xmp: job.xmp, darktable: job.darktable, merged: merged,
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
        let listing = try await indexer.index.folderHolds.list(folder)
        defer { listing.done() }
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
        /// The collections it's in, by path; nil keeps the row's.
        var collections: [String]?
        var isNew: Bool
        var thumbnail: Thumbnail?
        /// What its file's read found (LIB-40); nil keeps what the index has, for a photo not read.
        var health: PhotoHealth?
        /// Its end, still to be read once its row is written.
        var endCheck: EndCheck?
        /// Its row as its folder's listing found it; nil for a photo new to the index. A row that has changed since
        /// was written after this read began, and what was read isn't written over it.
        var listed: PhotoRecord?

        init(
            folder: String, record: PhotoRecord, camera: CameraName? = nil, lens: String? = nil,
            keywords: [String]? = nil, collections: [String]? = nil, isNew: Bool, thumbnail: Thumbnail? = nil,
        ) {
            self.folder = folder
            self.record = record
            self.camera = camera
            self.lens = lens
            self.keywords = keywords
            self.collections = collections
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
