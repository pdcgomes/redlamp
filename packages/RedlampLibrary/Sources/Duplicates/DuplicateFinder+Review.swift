import Foundation
import RedlampDocument

public extension DuplicateFinder {
    /// The confirmation for review: each copy's folder, size and capture date from the index, what
    /// its sidecar holds and its other app's `.xmp`, and each group's proposed keeper. Sidecars and
    /// `.xmp` are read through `sidecars` on the copies' volumes' readers when the confirmation
    /// checked the files, and copies whose volumes don't answer are shown without them; otherwise
    /// the index says what each sidecar held when it was indexed, and no disk is touched.
    func review(_ confirmation: DuplicateConfirmation) async throws -> DuplicateReview {
        var statuses: [Int64: DuplicateConfirmation.Status] = [:]
        for group in confirmation.groups {
            for candidate in group.candidates {
                statuses[candidate.photo] = candidate.status
            }
        }
        let photos = Array(statuses.keys)
        let rows = try await index.read { try $0.duplicateRows(photos) }
        let xmpFolders = Set(rows.values.filter { $0.record.xmpModified != nil }.map(\.record.folder))
        let names = try await index.read { reader in
            try Dictionary(uniqueKeysWithValues: xmpFolders.map { try ($0, reader.photoNames(inFolder: $0)) })
        }
        let found: [Int64: OnDisk] = if confirmation.checkedFiles {
            await onDisk(rows.values.filter { row in
                switch statuses[row.record.id] {
                case .unconfirmed(.offline), .unconfirmed(.missing): false
                default: true
                }
            })
        } else {
            rows.compactMapValues { row in
                let photo = row.record
                guard photo.sidecarModified != nil else { return nil }
                return OnDisk(
                    sidecar: DuplicateReview.SidecarContents(
                        hasEdits: photo.edited, rating: photo.rating, flag: photo.flag, label: photo.label,
                    ),
                    sidecarURL: sidecars.url(for: row.url),
                )
            }
        }

        func copy(_ photo: Int64) -> DuplicateReview.Copy? {
            guard let row = rows[photo], let status = statuses[photo] else { return nil }
            let disk = found[photo]
            let stem = (row.record.name as NSString).deletingPathExtension.lowercased()
            let shared = disk?.otherXMP?.lastPathComponent.lowercased() == stem + ".xmp"
                && (names[row.record.folder] ?? []).contains { name in
                    name != row.record.name && (name as NSString).deletingPathExtension.lowercased() == stem
                }
            return DuplicateReview.Copy(
                photo: photo, url: row.url, folder: row.folder, size: row.record.size, captured: row.record.captured,
                modified: row.record.modified, rating: row.record.rating, sidecar: disk?.sidecar,
                sidecarURL: disk?.sidecarURL, otherXMP: disk?.otherXMP, sharesOtherXMP: shared, status: status,
            )
        }
        func byPath(_ copies: [DuplicateReview.Copy]) -> [DuplicateReview.Copy] {
            copies.sorted { $0.url.path < $1.url.path }
        }

        let groups = confirmation.duplicates.compactMap { group -> DuplicateReview.Group? in
            let copies = byPath(group.photos.compactMap(copy))
            guard copies.count >= 2 else { return nil }
            // Nil for a sidecar that couldn't be read, which can't be said to hold what the others do.
            let held = copies.map { $0.sidecarURL == nil ? DuplicateReview.SidecarContents() : $0.sidecar }
            return DuplicateReview.Group(
                sha256: group.sha256, contentKey: group.contentKey, size: group.size, copies: copies,
                keeper: DuplicateReview.keeper(of: copies), sidecarsDiffer: held.contains(nil) || Set(held).count > 1,
            )
        }
        return DuplicateReview(
            groups: groups.sorted { lhs, rhs in
                lhs.reclaimable != rhs.reclaimable
                    ? lhs.reclaimable > rhs.reclaimable : lhs.copies[0].url.path < rhs.copies[0].url.path
            },
            different: byPath(confirmation.different.compactMap(copy)),
            unconfirmed: byPath(confirmation.unconfirmed.map(\.photo).compactMap(copy)),
            checkedFiles: confirmation.checkedFiles,
        )
    }

    /// What the copies' disks hold beside them, by photo: their sidecars, through `sidecars`, and
    /// their other apps' `.xmp`, each copy one operation of its volume's readers.
    private func onDisk(_ rows: [DuplicateRow]) async -> [Int64: OnDisk] {
        let sidecars = sidecars
        return await withTaskGroup(of: [Int64: OnDisk].self) { group in
            for (volume, rows) in Dictionary(grouping: rows, by: \.volume) {
                group.addTask {
                    guard let first = rows.first,
                          let io = await io(forVolume: volume, root: first.root) else { return [:] }
                    let queue = DuplicateRowQueue(rows)
                    return await withTaskGroup(of: [Int64: OnDisk].self) { workers in
                        for _ in 0 ..< Self.filesAtOnce(on: io) {
                            workers.addTask {
                                var found: [Int64: OnDisk] = [:]
                                while let row = queue.next() {
                                    let url = row.url
                                    let lookForXMP = row.record.xmpModified != nil
                                    found[row.record.id] = try? await io.perform(url, measured: false) { fileSystem in
                                        var disk = OnDisk()
                                        let sidecar = sidecars.url(for: url)
                                        if (try? fileSystem.attributes(of: sidecar)) != nil {
                                            disk.sidecarURL = sidecar
                                            disk.sidecar = sidecars.summary(for: url)
                                                .map(DuplicateReview.SidecarContents.init)
                                        }
                                        if lookForXMP {
                                            let named = [url.deletingPathExtension(), url].map {
                                                $0.appendingPathExtension("xmp")
                                            }
                                            disk.otherXMP = named.first { (try? fileSystem.attributes(of: $0)) != nil }
                                        }
                                        return disk
                                    }
                                }
                                return found
                            }
                        }
                        return await workers.reduce(into: [:]) { $0.merge($1) { first, _ in first } }
                    }
                }
            }
            return await group.reduce(into: [:]) { $0.merge($1) { first, _ in first } }
        }
    }
}

/// What's beside a copy on its disk.
struct OnDisk: Sendable {
    var sidecar: DuplicateReview.SidecarContents?
    var sidecarURL: URL?
    var otherXMP: URL?
}
