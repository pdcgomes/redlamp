import Dispatch
import Foundation
import RedlampDocument
import Synchronization

/// Metadata shared with other apps (LIB-24, DEC-37): the `.redlamp` sidecar is the photo's record;
/// other apps' ratings, flags, labels, keywords, titles and captions, in `.xmp` sidecars and in the
/// photos' own XMP and IPTC, are read and their changes taken into it field by field
/// (`XMPMerge`); standard `.xmp` sidecars are written beside the photos, wherever their root keeps
/// its `.redlamp` sidecars, only once the library's setting is on and a field changed. An `.xmp`
/// is rewritten keeping every byte of what Redlamp doesn't own, and a raw and its JPEG share one.
/// The originals are never written.
public struct LibraryXMP: Sendable {
    public let index: LibraryIndex
    public let paths: LibraryPaths

    public init(index: LibraryIndex, paths: LibraryPaths) {
        self.index = index
        self.paths = paths
    }

    /// The library whose index is `index`, at `LibraryPaths.index` in its folder.
    public init(index: LibraryIndex) {
        self.init(index: index, paths: LibraryPaths(root: index.url.deletingLastPathComponent()))
    }

    public func settings() async throws -> XMPSettings {
        try await index.read { try XMPSettings($0) }
    }

    public func setSettings(_ settings: XMPSettings) async throws {
        try await index.write { try settings.save($0) }
    }

    /// Merges the XMP of photos `ids` into their `.redlamp` sidecars and, when `writing` (the
    /// library's setting when nil) says so, writes their `.xmp`; with `dryRun`, works out what that
    /// would do and writes nothing. Photos sharing an `.xmp` with one of them are merged with it.
    /// Records what was merged and written, so the next sync takes only what changed since and
    /// doesn't take Redlamp's own `.xmp` for another app's, and brings the index's rows up to date:
    /// the organising fields of photos whose `.redlamp` changed, and the `.xmp` date of those whose
    /// `.xmp` Redlamp wrote, so the indexer doesn't read them again.
    public func sync(_ ids: [Int64], writing: Bool? = nil, dryRun: Bool = false) async throws -> XMPReport {
        let clock = ContinuousClock()
        let started = clock.now
        let settings = try await settings()
        let writes = writing ?? settings.writes
        let locator = try await LibrarySidecars(index: index, paths: paths).locator()
        let selected = Set(ids)
        let folders = try await index.read { reader -> [(path: String, rows: [PhotoRecord])] in
            var folderIDs = Set<Int64>()
            for id in selected {
                if let photo = try reader.photo(id: id) {
                    folderIDs.insert(photo.folder)
                }
            }
            return try folderIDs.sorted().compactMap { id in
                try reader.folder(id: id).map { try ($0.path, reader.photos(inFolder: id)) }
            }
        }
        let involved = folders.flatMap(\.rows).map(\.id)
        let records = try await index.read { try XMPMergeRecord.records(involved, in: $0) }
        let context = XMPSyncContext(
            locator: locator, conventions: settings.conventions, writes: writes, dryRun: dryRun,
            fields: XMPField.held, now: Date(), records: records,
        )
        let outcomes = try await LibraryIndex.offCaller {
            let groups = Mutex<[XMPGroup]>([])
            let fileSystem = LocalFileSystem()
            DispatchQueue.concurrentPerform(iterations: folders.count) { index in
                let folder = folders[index]
                guard let entries = try? fileSystem.contentsOfDirectory(at: URL(fileURLWithPath: folder.path)) else {
                    return
                }
                let rows = Dictionary(folder.rows.map { ($0.name, $0) }) { first, _ in first }
                let found = XMPGroup.groups(in: folder.path, entries: entries, rows: rows, selected: selected)
                groups.withLock { $0 += found }
            }
            let all = groups.withLock { $0 }
            let outcomes = Mutex<[XMPGroupOutcome]>([])
            DispatchQueue.concurrentPerform(iterations: all.count) { index in
                let outcome = all[index].sync(context)
                outcomes.withLock { $0.append(outcome) }
            }
            return outcomes.withLock { $0 }
        }

        if !dryRun {
            let records = outcomes.reduce(into: [Int64: XMPMergeRecord]()) { $0.merge($1.records) { _, new in new } }
            let dropped = outcomes.flatMap(\.dropped)
            let organising = outcomes.flatMap(\.organising)
            let xmpModified = outcomes.flatMap(\.xmpModified)
            if !records.isEmpty || !dropped.isEmpty || !organising.isEmpty || !xmpModified.isEmpty {
                try await index.write { writer in
                    try XMPMergeRecord.save(records, dropping: dropped, in: writer)
                    for (id, fields) in organising {
                        try writer.setOrganising(
                            [.rating(fields.rating ?? 0), .flag(fields.flag), .label(fields.label)], forPhotos: [id],
                        )
                    }
                    try writer.setXMPModified(xmpModified)
                }
            }
        }
        let photos = outcomes.flatMap(\.photos).sorted { $0.path < $1.path }
        return XMPReport(
            photos: photos, considered: selected.count, writing: writes, dryRun: dryRun, elapsed: clock.now - started,
        )
    }

    /// The photos whose `.redlamp` sidecars changed in `report`: the rows to hand `LibraryLive`.
    public static func changedPhotos(_ report: XMPReport) -> [Int64] {
        report.dryRun ? [] : report.photos.filter { !$0.taken.isEmpty && $0.problem == nil }.compactMap(\.photo)
    }

    /// Removes what's recorded of photos the index no longer has; returns how many.
    @discardableResult
    public func removeOrphanedRecords() async throws -> Int {
        try await index.write { writer in
            let prefix = XMPMergeRecord.key(0).dropLast()
            let statement = try writer.database.cached("""
            DELETE FROM settings WHERE key > ?1 AND key < ?2
              AND CAST(substr(key, length(?1) + 1) AS INTEGER) NOT IN (SELECT id FROM photos)
            """)
            try statement.bind(String(prefix), at: 1)
            try statement.bind(String(prefix.dropLast()) + "/", at: 2)
            try statement.run()
            return writer.database.changes
        }
    }
}

extension LibraryIndex.Writer {
    /// Records the modification dates of `.xmp` sidecars Redlamp wrote, as the indexer compares them
    /// with the folder's listing: those photos aren't read again for them.
    func setXMPModified(_ dates: [(id: Int64, modified: Date)]) throws {
        guard !dates.isEmpty else { return }
        let statement = try database.cached("UPDATE photos SET xmp_modified = ? WHERE id = ?")
        for (id, modified) in dates {
            try statement.bind(modified.timeIntervalSince1970, at: 1)
            try statement.bind(id, at: 2)
            try statement.run()
        }
    }
}
