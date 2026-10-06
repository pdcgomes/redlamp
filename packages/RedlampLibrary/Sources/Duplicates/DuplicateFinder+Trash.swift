import Foundation
import RedlampDocument
import Synchronization

public extension DuplicateFinder {
    /// The batch that moves `plan`'s copies to the Trash, as `operations` plans one (LIB-26): each copy
    /// at the path the plan has, with its `.redlamp` sidecars and the other apps' sidecars named after
    /// it, taken out of the index, journaled and undoable. Planning it moves nothing: `trash` checks it
    /// against the plan and the files, and runs it. A copy the index no longer has isn't in it
    /// (`FileBatch.notInIndex`), which `check` reports.
    func trashBatch(for plan: DuplicateRemovalPlan, operations: FileOperations) async throws -> FileBatch {
        var named = Set<Int64>()
        let photos = plan.removals.filter { named.insert($0.photo).inserted }.map { removal in
            PhotoFiles(id: removal.photo, files: [removal.file])
        }
        var batch = try await operations.planTrash(photos)
        batch.title = "Move \(photos.count) duplicate\(photos.count == 1 ? "" : "s") to the Trash"
        return batch
    }

    /// Runs `batch`, `plan`'s (`trashBatch`), once `check` finds nothing that differs from the plan;
    /// otherwise throws `DuplicateRemovalPlan.Refusal.differs`, having moved nothing. It throws as
    /// `FileOperations.run` does too, `FileOperationError.conflicts` among them, also moving nothing.
    /// Undo (`FileOperations.undo`) puts every copy back where it was, with its sidecars, while the
    /// Trash still has it. `progress` follows the files as they're read again.
    @discardableResult
    func trash(
        _ plan: DuplicateRemovalPlan, _ batch: FileBatch, operations: FileOperations,
        progress: (@Sendable (Progress) -> Void)? = nil,
    ) async throws -> FileOutcome {
        let differences = try await check(plan, batch, operations: operations, progress: progress)
        guard differences.isEmpty else { throw DuplicateRemovalPlan.Refusal.differs(differences) }
        return try await operations.run(batch)
    }

    /// What stops `batch` (`trashBatch`) carrying out `plan`, as the library is now, by path; empty
    /// when it can run.
    ///
    /// - **The plan** keeps a copy of every group it removes from: no copy it keeps is one it removes.
    /// - **The index** has each copy, and each copy kept, where the plan has it.
    /// - **The batch** moves each copy, as it was in the review when the batch was planned, with what
    ///   the plan says goes with it, and nothing but the copies' own files: their `.redlamp` sidecars,
    ///   other apps' sidecars named after them, and those named after their names without the
    ///   extension where every photo of that name in the index is a copy the plan removes. It takes
    ///   no other photo out of the index.
    /// - **The files,** through their volumes' readers: each copy, and each copy kept, read whole for
    ///   its full SHA-256, unless `hashing` is false or something else differs already; then each is
    ///   checked again for the plan's size and modification date, and each copy's sidecar for what it
    ///   held in the review.
    ///
    /// Cancelling the calling task stops it once the files being read are done, and throws
    /// `CancellationError`.
    func check(
        _ plan: DuplicateRemovalPlan, _ batch: FileBatch, operations: FileOperations, hashing: Bool = true,
        progress: (@Sendable (Progress) -> Void)? = nil,
    ) async throws -> [DuplicateRemovalPlan.Difference] {
        let removals = plan.removals
        let removed = Set(removals.map(\.photo))
        let removedPaths = Set(removals.map { NamingJob.fold(LibraryIndexer.path($0.file)) })
        var found = Set(Set(removals.map(PlannedFile.init(keptFor:))).filter { kept in
            removed.contains(kept.photo) || removedPaths.contains(NamingJob.fold(kept.path))
        }.map { $0.difference(.keptRemoved) })

        let planned = Set(removals.map(PlannedFile.init(_:)) + removals.map(PlannedFile.init(keptFor:)))
        let rows = try await index.read { try $0.duplicateRows(Array(Set(planned.map(\.photo)))) }
        let placed = planned.filter { file in
            rows[file.photo].map { NamingJob.fold(LibraryIndexer.path($0.url)) == NamingJob.fold(file.path) } == true
        }
        found.formUnion(planned.subtracting(placed).map { $0.difference(.notInLibrary) })
        let folders = Set(removals.compactMap { rows[$0.photo]?.record.folder })
        let names = try await index.read { reader in
            try Dictionary(uniqueKeysWithValues: folders.map { try ($0, reader.photoNames(inFolder: $0)) })
        }
        let locator = try await LibrarySidecars(index: operations.index, paths: operations.paths).locator()
        let copies = Set(placed.filter { !$0.isKept }.map(\.photo))
        let own = Self.own(plan, placed: copies, rows: rows, names: names, locator: locator)
        found.formUnion(Self.outside(plan, batch, own: own) + Self.missing(plan, batch, placed: copies))

        let disk = PlanFileCheck(finder: self, rows: rows, report: progress)
        if hashing, found.isEmpty {
            await found.formUnion(disk.differences(Array(placed), hashing: true))
            try Task.checkCancellation()
        }
        await found.formUnion(disk.differences(Array(placed), hashing: false))
        try Task.checkCancellation()
        return found.sorted { lhs, rhs in
            lhs.path != rhs.path ? lhs.path < rhs.path : lhs.reason.rawValue < rhs.reason.rawValue
        }
    }

    /// The paths, folded, of the files that are `plan`'s copies' own: each copy, its `.redlamp`
    /// sidecars beside it and on this Mac, other apps' sidecars named after it, and, for copies
    /// `placed` where the plan has them, those named after its name without the extension where every
    /// photo of that name in its folder (`names`, by folder) is a copy the plan removes.
    private static func own(
        _ plan: DuplicateRemovalPlan, placed: Set<Int64>, rows: [Int64: DuplicateRow], names: [Int64: [String]],
        locator: SidecarLocator,
    ) -> Set<String> {
        let others = NamingJob.sidecarExtensions.subtracting(["redlamp"])
        var going: [Int64: Set<String>] = [:]
        for removal in plan.removals {
            if let row = rows[removal.photo] {
                going[row.record.folder, default: []].insert(NamingJob.fold(row.record.name))
            }
        }
        var own = Set<String>()
        for removal in plan.removals {
            let path = LibraryIndexer.path(removal.file)
            own.formUnion(([path, path + ".redlamp"] + others.map { path + "." + $0 }).map(NamingJob.fold))
            own.formUnion([locator.onThisMac(removal.file), removal.sidecar, removal.otherXMP].compactMap { url in
                url.map { NamingJob.fold(LibraryIndexer.path($0)) }
            })
            guard placed.contains(removal.photo), let row = rows[removal.photo] else { continue }
            let stem = NamingJob.split(row.record.name).base
            let sharing = (names[row.record.folder] ?? []).filter { name in
                NamingJob.fold(NamingJob.split(name).base) == NamingJob.fold(stem)
            }
            if sharing.allSatisfy({ going[row.record.folder]?.contains(NamingJob.fold($0)) == true }) {
                own.formUnion(others.map { NamingJob.fold(row.folder + "/" + stem + "." + $0) })
            }
        }
        return own
    }

    /// What `batch` would do that `plan` doesn't say: move files that aren't the copies' `own`, or take
    /// photos or folders out of the index that aren't the copies.
    private static func outside(
        _ plan: DuplicateRemovalPlan, _ batch: FileBatch, own: Set<String>,
    ) -> [DuplicateRemovalPlan.Difference] {
        typealias Difference = DuplicateRemovalPlan.Difference
        let removed = Set(plan.removals.map(\.photo))
        var found: [Difference] = []
        for step in batch.steps {
            found += step.removed.filter { !removed.contains($0.photo.id) }.map { photo in
                Difference(path: photo.folder + "/" + photo.photo.name, reason: .notInPlan)
            }
            found += (step.removedFolders.map(\.path) + [step.folder].compactMap(\.self)).map { folder in
                Difference(path: folder, reason: .notInPlan)
            }
            found += step.items.filter { step.kind != .trash || !own.contains(NamingJob.fold($0.source)) }.map { item in
                Difference(path: item.source, reason: .notInPlan)
            }
        }
        return found
    }

    /// What `plan` says that `batch` wouldn't do, as the batch found the files when it was planned:
    /// move each copy `placed` where the plan has it, as it was in the review, with its sidecar and
    /// its other app's `.xmp`.
    private static func missing(
        _ plan: DuplicateRemovalPlan, _ batch: FileBatch, placed: Set<Int64>,
    ) -> [DuplicateRemovalPlan.Difference] {
        typealias Difference = DuplicateRemovalPlan.Difference
        let taken = Set(batch.steps.flatMap { $0.removed.map(\.photo.id) })
        let moving = Dictionary(
            batch.steps.flatMap(\.items).map { (NamingJob.fold($0.source), $0) },
            uniquingKeysWith: { first, _ in first },
        )
        var found: [Difference] = []
        for removal in plan.removals where placed.contains(removal.photo) {
            let path = LibraryIndexer.path(removal.file)
            guard taken.contains(removal.photo), let item = moving[NamingJob.fold(path)], item.role == .photo else {
                found.append(Difference(path: path, reason: .notInBatch))
                continue
            }
            if item.size == nil {
                found.append(Difference(path: path, reason: .gone))
            } else if item.size != removal.size || !LibraryIndexer.Run.same(item.modified, removal.modified) {
                found.append(Difference(path: path, reason: .changed))
            }
            if let sidecar = removal.sidecar, moving[NamingJob.fold(LibraryIndexer.path(sidecar))] == nil {
                found.append(Difference(path: path, reason: .sidecarChanged))
            }
            if let xmp = removal.otherXMP, moving[NamingJob.fold(LibraryIndexer.path(xmp))] == nil {
                found.append(Difference(path: LibraryIndexer.path(xmp), reason: .notInBatch))
            }
        }
        return found
    }
}

/// A file a removal plan names: a copy it removes, with its sidecar as the review found it, or a copy
/// it keeps, with the full SHA-256 it shares with the copy it's kept for.
struct PlannedFile: Sendable, Hashable {
    var photo: Int64
    var url: URL
    var size: Int64
    var modified: Date
    var sha256: Data
    var isKept: Bool
    var sidecar: URL?
    var sidecarContents: DuplicateReview.SidecarContents?

    init(_ removal: DuplicateRemovalPlan.Removal) {
        photo = removal.photo
        url = removal.file
        size = removal.size
        modified = removal.modified
        sha256 = removal.sha256
        isKept = false
        sidecar = removal.sidecar
        sidecarContents = removal.sidecarContents
    }

    init(keptFor removal: DuplicateRemovalPlan.Removal) {
        photo = removal.kept.photo
        url = removal.kept.file
        size = removal.kept.size
        modified = removal.kept.modified
        sha256 = removal.sha256
        isKept = true
    }

    var path: String {
        LibraryIndexer.path(url)
    }

    func difference(_ reason: DuplicateRemovalPlan.Difference.Reason) -> DuplicateRemovalPlan.Difference {
        DuplicateRemovalPlan.Difference(path: path, reason: reason, isKept: isKept)
    }
}

/// A plan's files checked on their disks: each volume's through its readers, as many at once as
/// confirming reads there, in folder order.
final class PlanFileCheck: Sendable {
    let finder: DuplicateFinder
    let rows: [Int64: DuplicateRow]
    let report: (@Sendable (DuplicateFinder.Progress) -> Void)?
    private let state = Mutex(DuplicateFinder.Progress())

    init(
        finder: DuplicateFinder, rows: [Int64: DuplicateRow],
        report: (@Sendable (DuplicateFinder.Progress) -> Void)?,
    ) {
        self.finder = finder
        self.rows = rows
        self.report = report
    }

    /// What differs from the plan in `files`, each of which has its row: with `hashing`, each file's
    /// size, modification date and full SHA-256; without, its size and date, and each copy's sidecar.
    func differences(_ files: [PlannedFile], hashing: Bool) async -> [DuplicateRemovalPlan.Difference] {
        if hashing {
            let progress = state.withLock { progress in
                progress = DuplicateFinder.Progress()
                progress.candidates = files.count
                progress.bytes = files.reduce(0) { $0 + $1.size }
                return progress
            }
            report?(progress)
        }
        let byVolume = Dictionary(grouping: files) { rows[$0.photo]?.volume ?? "" }
        return await withTaskGroup(of: [DuplicateRemovalPlan.Difference].self) { group in
            for (volume, files) in byVolume {
                group.addTask { await self.differences(files, onVolume: volume, hashing: hashing) }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
    }

    private func differences(
        _ files: [PlannedFile], onVolume volume: String, hashing: Bool,
    ) async -> [DuplicateRemovalPlan.Difference] {
        guard let root = files.first.flatMap({ rows[$0.photo]?.root }),
              let io = await finder.io(forVolume: volume, root: root)
        else { return files.map { $0.difference(.offline) } }
        let ordered = files.compactMap { file in rows[file.photo].map { (file: file, row: $0) } }.sorted { lhs, rhs in
            lhs.row.folder != rhs.row.folder
                ? lhs.row.folder < rhs.row.folder : FileOrder.precedes(lhs.row.record.name, rhs.row.record.name)
        }
        let queue = DuplicateQueue(ordered.map(\.file))
        return await withTaskGroup(of: [DuplicateRemovalPlan.Difference].self) { group in
            for _ in 0 ..< DuplicateFinder.filesAtOnce(on: io) {
                group.addTask {
                    var found: [DuplicateRemovalPlan.Difference] = []
                    while !Task.isCancelled, let file = queue.next() {
                        if let reason = await self.check(file, on: io, hashing: hashing) {
                            found.append(file.difference(reason))
                        }
                    }
                    return found
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
    }

    /// What differs in the file, if anything.
    private func check(
        _ file: PlannedFile, on io: VolumeIO, hashing: Bool,
    ) async -> DuplicateRemovalPlan.Difference.Reason? {
        defer {
            if hashing {
                done()
            }
        }
        do {
            let entry = try await io.attributes(of: file.url)
            guard entry.size == file.size, LibraryIndexer.Run.same(entry.modified, file.modified) else {
                return .changed
            }
            if hashing {
                let sha256 = try await DuplicateFinder.sha256(of: file.url, size: Int(file.size), on: io) { bytes in
                    self.read(bytes)
                }
                return sha256 == file.sha256 ? nil : .changed
            }
            guard !file.isKept else { return nil }
            let (sidecars, url) = (finder.sidecars, file.url)
            let disk = try await io.perform(url, measured: false) { fileSystem in
                var disk = OnDisk()
                let sidecar = sidecars.url(for: url)
                if (try? fileSystem.attributes(of: sidecar)) != nil {
                    disk.sidecarURL = sidecar
                    disk.sidecar = sidecars.summary(for: url).map(DuplicateReview.SidecarContents.init)
                }
                return disk
            }
            func folded(_ url: URL?) -> String? {
                url.map { NamingJob.fold(LibraryIndexer.path($0)) }
            }
            return folded(disk.sidecarURL) == folded(file.sidecar) && disk.sidecar == file.sidecarContents
                ? nil : .sidecarChanged
        } catch is CancellationError {
            return nil
        } catch where VolumeIO.isNotFound(error) {
            return .gone
        } catch is DuplicateFinder.FileChanged {
            return .changed
        } catch where VolumeIO.isVolumeFailure(error) || !io.isReachable {
            return .offline
        } catch {
            return .unreadable
        }
    }

    private func read(_ bytes: Int) {
        let progress = state.withLock { progress in
            progress.bytesRead += Int64(bytes)
            return progress
        }
        report?(progress)
    }

    private func done() {
        let progress = state.withLock { progress in
            progress.done += 1
            return progress
        }
        report?(progress)
    }
}
