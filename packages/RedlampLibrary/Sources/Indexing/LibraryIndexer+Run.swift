import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization

extension LibraryIndexer {
    enum Request: Sendable {
        /// Index these roots, adding them, and every folder below them.
        case roots([String])
        /// List these folders again, and their subfolders where recursive.
        case folders([(path: String, recursive: Bool)])
    }

    /// A photo a run has to read, or whose row it has to bring up to date.
    struct PhotoJob: Sendable {
        enum Kind: Sendable {
            /// A name the folder's rows don't have: renamed or moved here, or new.
            case new
            /// Its file, its other app's `.xmp` or the sidecar it had changed: read again.
            case changed
            /// Only its `.redlamp` sidecar changed.
            case sidecar
            /// Nothing it's read from changed, but its row's state or file identifier did.
            case refresh
        }

        let kind: Kind
        let folder: String
        let entry: FileEntry
        let existing: PhotoRecord?
        let sidecar: FileEntry?
        let xmp: FileEntry?
    }

    /// One volume's part of a run: its readers, the folders it has yet to list and the photos it
    /// has yet to read.
    struct VolumeWork: Sendable {
        /// The index's name for the volume.
        let key: String
        let id: Int64
        let io: VolumeIO
        let walk: WalkQueue
        let photos: PhotoQueue
    }

    /// One run: lists folders, compares them with the index, reads what changed and writes it.
    final class Run: Sendable {
        let indexer: LibraryIndexer
        let events: AsyncStream<LibraryIndexerEvent>.Continuation
        let batcher: Batcher
        let state = Mutex(RunState())
        private let started = ContinuousClock.now

        /// Folders listed at once on each volume; its readers decide how many reach it.
        static let walkers = 8

        init(indexer: LibraryIndexer, events: AsyncStream<LibraryIndexerEvent>.Continuation) {
            self.indexer = indexer
            self.events = events
            // A reference, not a closure, in the `Mutex`: a function `withLock` lends out `inout` can
            // come back wrapped in another reabstraction thunk, and each batch's call would then run
            // one thunk deeper than the last.
            let owner = Mutex(Owner())
            batcher = Batcher(
                index: indexer.index, configuration: indexer.configuration, scheduler: indexer.scheduler,
                thumbnails: indexer.thumbnails, committed: { outcome in owner.withLock { $0.run }?.committed(outcome) },
            )
            owner.withLock { $0.run = self }
        }

        /// The run its batcher reports to, held without keeping it.
        private struct Owner {
            weak var run: Run?
        }

        func perform(_ request: Request) async {
            await withTaskCancellationHandler {
                await run(request)
            } onCancel: {
                for volume in state.withLock({ $0.volumes }) {
                    volume.walk.close()
                    _ = volume.photos.close()
                }
            }
        }

        private func run(_ request: Request) async {
            let volumes: [VolumeWork]
            do {
                volumes = try await prepare(request)
            } catch {
                events.yield(.failed(path: "", message: String(describing: error)))
                await finish()
                return
            }
            await withTaskGroup(of: Void.self) { group in
                for volume in volumes {
                    for _ in 0 ..< Self.walkers {
                        group.addTask { await self.walk(volume) }
                    }
                    for _ in 0 ..< Self.photoWorkers(volume.io) {
                        group.addTask { await self.read(volume) }
                    }
                }
            }
            if !Task.isCancelled {
                await conclude()
            }
            await finish()
        }

        /// Photos read at once on a volume: enough to keep its widest readers busy and every
        /// performance core parsing.
        static func photoWorkers(_ io: VolumeIO) -> Int {
            2 * max(CoreCounts.performance, io.width)
        }

        // MARK: - Roots and volumes

        /// Finds the volumes and roots `request` covers, adding those the index doesn't have,
        /// loads their folders, clears the offline mark of those that answer again, and queues the
        /// first folders to list.
        private func prepare(_ request: Request) async throws -> [VolumeWork] {
            let roots: [String]
            switch request {
            case let .roots(paths):
                roots = paths
            case let .folders(changes):
                let known = try await indexer.index.read { try $0.roots().map(\.path) }
                roots = Array(Set(changes.compactMap { change in Self.root(of: change.path, among: known) })).sorted()
            }
            var byVolume: [String: (info: VolumeInfo, io: VolumeIO, roots: [String])] = [:]
            for root in roots {
                let url = URL(fileURLWithPath: root, isDirectory: true)
                let info: VolumeInfo
                do {
                    info = try await indexer.volumes.volume(of: url)
                } catch {
                    try await markOffline(root: root, error: error)
                    continue
                }
                let key = VolumeIORegistry.key(for: info, probe: url)
                let io = byVolume[key]?.io ?? indexer.volumes.io(for: info, probe: url)
                byVolume[key, default: (info, io, [])].roots.append(root)
            }
            let entries = byVolume.map { key, value in (key: key, info: value.info, roots: value.roots) }
            let records = try await indexer.index.write { writer in
                try entries.map { entry -> (volume: Int64, roots: [RootRecord]) in
                    let existing = try writer.volume(uuid: entry.key)
                    let volume = try writer.upsertVolume(VolumeRecord(
                        uuid: entry.key, name: entry.info.name, kind: Self.kind(of: entry.info),
                        eventDatabase: existing?.eventDatabase, lastEvent: existing?.lastEvent,
                    ))
                    let roots = try entry.roots.map { path in
                        if let root = try writer.root(path: path), root.volume == volume {
                            return root
                        }
                        let id = try writer.upsertRoot(RootRecord(volume: volume, path: path))
                        return RootRecord(id: id, volume: volume, path: path)
                    }
                    return (volume, roots)
                }
            }
            let rootIDs = records.flatMap { $0.roots.map(\.id) }
            let folders = try await indexer.index.read { reader in
                try rootIDs.flatMap { try reader.folders(inRoot: $0) }
            }
            state.withLock { state in
                for folder in folders {
                    state.folders[folder.path] = folder
                    state.paths[folder.id] = folder.path
                    if let parent = folder.parent {
                        state.children[parent, default: []].append(folder.path)
                    }
                }
            }
            var volumes: [VolumeWork] = []
            for (entry, record) in zip(entries, records) {
                guard let io = byVolume[entry.key]?.io else { continue }
                let prioritised: @Sendable () -> Set<String> = { [indexer] in indexer.prioritised }
                let volume = VolumeWork(
                    key: entry.key, id: record.volume, io: io, walk: WalkQueue(prioritised: prioritised),
                    photos: PhotoQueue(prioritised: prioritised),
                )
                if io.isReachable, try await indexer.index.read({ try $0.isMarkedOffline(volume: entry.key) }) {
                    try await indexer.index.write { try $0.setOffline(false, onVolume: record.volume, uuid: entry.key) }
                    events.yield(.volumeOnline(entry.key))
                }
                let seeds = seeds(for: request, roots: record.roots)
                state.withLock { state in
                    state.volumes.append(volume)
                    state.queued.formUnion(seeds.map(\.path))
                }
                volume.walk.add(seeds)
                volumes.append(volume)
            }
            return volumes
        }

        /// The folders a run starts from: its roots, or the folders named, each found from the nearest
        /// folder above it that the index has.
        private func seeds(for request: Request, roots: [RootRecord]) -> [WalkQueue.Item] {
            switch request {
            case .roots:
                return roots.map { root in
                    WalkQueue.Item(
                        path: root.path,
                        parent: nil,
                        root: root.id,
                        recursive: true,
                        modified: .distantFuture,
                    )
                }
            case let .folders(changes):
                var chosen: [String: (root: RootRecord, recursive: Bool)] = [:]
                state.withLock { state in
                    for change in changes {
                        guard let root = roots.first(where: { Self.root(of: change.path, among: [$0.path]) != nil }),
                              var path = Self.folder(of: change.path, below: root.path)
                        else { continue }
                        var recursive = change.recursive
                        while path != root.path, state.folders[path] == nil {
                            path = (path as NSString).deletingLastPathComponent
                            recursive = false
                        }
                        if state.folders[path] == nil {
                            recursive = true
                        }
                        let earlier = chosen[path]?.recursive ?? false
                        chosen[path] = (root, earlier || recursive)
                    }
                }
                let recursive = chosen.filter(\.value.recursive).keys
                return chosen.compactMap { path, choice in
                    if recursive.contains(where: { path.hasPrefix($0 + "/") }) {
                        return nil
                    }
                    let parent = path == choice.root.path ? nil : (path as NSString).deletingLastPathComponent
                    return WalkQueue.Item(
                        path: path, parent: parent, root: choice.root.id, recursive: choice.recursive,
                        modified: .distantFuture,
                    )
                }
            }
        }

        /// The root of `roots` that `path` is in.
        static func root(of path: String, among roots: [String]) -> String? {
            roots.filter { path == $0 || path.hasPrefix($0 == "/" ? $0 : $0 + "/") }.max { $0.count < $1.count }
        }

        /// The folder a change at `path` is to: `path`, or the folder holding the sidecar package it's
        /// in; nil inside a hidden folder, which listings leave out.
        static func folder(of path: String, below root: String) -> String? {
            guard path != root else { return root }
            var folder = root
            for component in path.dropFirst(root.count).split(separator: "/") {
                if component.hasPrefix(".") {
                    return nil
                }
                if component.lowercased().hasSuffix(".redlamp") {
                    break
                }
                folder += "/" + component
            }
            return folder
        }

        static func kind(of volume: VolumeInfo) -> VolumeRecord.Kind {
            guard volume.isLocal else { return .network }
            return volume.isInternal ? .ssd : .unknown
        }

        /// A root whose volume can't be found: the photos already indexed on it are marked offline.
        private func markOffline(root: String, error: any Error) async throws {
            let marked = try await indexer.index.write { writer -> String? in
                guard let root = try writer.root(path: root),
                      let volume = try writer.volumes().first(where: { $0.id == root.volume })
                else { return nil }
                try writer.setOffline(true, onVolume: volume.id, uuid: volume.uuid)
                return volume.uuid
            }
            if let marked {
                state.withLock { $0.summary.offlineVolumes.append(marked) }
                events.yield(.volumeOffline(marked))
            }
            failed(root, error)
        }

        // MARK: - Walking

        private func walk(_ volume: VolumeWork) async {
            while let item = await volume.walk.next() {
                await list(item, on: volume)
                volume.walk.done()
            }
            volume.photos.finish()
        }

        private func list(_ item: WalkQueue.Item, on volume: VolumeWork) async {
            let url = URL(fileURLWithPath: item.path, isDirectory: true)
            let entries: [FileEntry]
            do {
                entries = try await volume.io.contentsOfDirectory(at: url)
            } catch {
                if VolumeIO.isNotFound(error), item.parent != nil {
                    state.withLock { state in
                        if state.folders[item.path] != nil {
                            state.vanishedFolders[item.path] = volume.id
                        }
                    }
                } else if VolumeIO.isNotFound(error) || VolumeIO.isVolumeFailure(error) || !volume.io.isReachable {
                    if VolumeIO.isNotFound(error) {
                        volume.io.markUnreachable()
                    }
                    await volumeFailed(volume)
                } else if !(error is CancellationError) {
                    failed(item.path, error)
                }
                return
            }
            await listed(item, entries, on: volume)
        }

        private func listed(_ item: WalkQueue.Item, _ entries: [FileEntry], on volume: VolumeWork) async {
            let signature = FolderSignature(entries)
            let subfolders = entries.filter(FolderWalk.isFolder)
            let (existing, found) = state.withLock { state -> (FolderRecord?, [WalkQueue.Item]) in
                state.summary.foldersListed += 1
                let existing = state.folders[item.path]
                var found: [WalkQueue.Item] = []
                var paths = Set<String>()
                for subfolder in subfolders {
                    let path = item.path + "/" + subfolder.name
                    paths.insert(path)
                    guard item.recursive || state.folders[path] == nil,
                          state.queued.insert(path).inserted else { continue }
                    found.append(WalkQueue.Item(
                        path: path, parent: item.path, root: item.root, recursive: true, modified: subfolder.modified,
                    ))
                }
                if let existing {
                    for child in state.children[existing.id] ?? [] where !paths.contains(child) {
                        state.vanishedFolders[child] = volume.id
                    }
                }
                return (existing, found)
            }
            if let existing, existing.signature == signature.rawValue, existing.indexedSignature == signature.rawValue {
                state.withLock { _ = $0.unchanged.insert(item.path) }
                volume.walk.add(found)
                return
            }
            // Before its subfolders are listed, so a new folder's row is written before theirs.
            await batcher.add([.folder(FolderListing(
                path: item.path, root: item.root, parent: item.parent, signature: signature.rawValue, listedAt: Date(),
            ))])
            volume.walk.add(found)
            let rows: [PhotoRecord]
            if let existing {
                do {
                    rows = try await indexer.index.read { try $0.photos(inFolder: existing.id) }
                } catch {
                    failed(item.path, error)
                    return
                }
            } else {
                rows = []
            }
            let jobs = compare(item.path, entries, rows, signature: signature, on: volume)
            volume.photos.add(jobs, folder: item.path, modified: item.modified)
            await jobFinished(in: item.path)
        }

        /// The jobs that bring `folder`'s rows in step with its listing; rows whose names are gone
        /// wait for the end of the run, where those that weren't moved elsewhere are removed.
        private func compare(
            _ folder: String, _ entries: [FileEntry], _ rows: [PhotoRecord], signature: FolderSignature,
            on volume: VolumeWork,
        ) -> [PhotoJob] {
            var sidecars: [String: FileEntry] = [:]
            var xmps: [String: FileEntry] = [:]
            var photos: [FileEntry] = []
            for entry in entries {
                let name = entry.name.lowercased()
                if name.hasSuffix(".redlamp") {
                    sidecars[String(entry.name.dropLast(".redlamp".count))] = entry
                } else if !entry.isDirectory, name.hasSuffix(".xmp") {
                    xmps[name] = entry
                } else if FolderWalk.isPhoto(entry) {
                    photos.append(entry)
                }
            }
            photos.sort { FileOrder.precedes($0.name, $1.name) }
            let byName = Dictionary(rows.map { ($0.name, $0) }) { first, _ in first }
            var jobs: [PhotoJob] = []
            for entry in photos {
                let sidecar = sidecars[entry.name]
                let xmp = Self.xmp(for: entry.name, in: xmps)
                func job(_ kind: PhotoJob.Kind, _ existing: PhotoRecord?) -> PhotoJob {
                    PhotoJob(kind: kind, folder: folder, entry: entry, existing: existing, sidecar: sidecar, xmp: xmp)
                }
                guard let row = byName[entry.name] else {
                    jobs.append(job(.new, nil))
                    continue
                }
                if row.size != entry.size || !Self.same(row.modified, entry.modified) || row.indexed == 0
                    || !Self.same(row.xmpModified, xmp?.modified) || (row.sidecarModified != nil && sidecar == nil) {
                    jobs.append(job(.changed, row))
                } else if !Self.same(row.sidecarModified, sidecar?.modified) {
                    jobs.append(job(.sidecar, row))
                } else if !row.state.isEmpty || row.fileID != entry.fileIdentifier {
                    jobs.append(job(.refresh, row))
                }
            }
            let names = Set(photos.map(\.name))
            let gone = rows.filter { !names.contains($0.name) }
            state.withLock { state in
                state.names[folder] = names
                var vanished: [Int64] = []
                for row in gone where !state.moved.contains(row.id) {
                    state.vanished[row.id] = Vanished(record: row, folder: folder, volume: volume.id)
                    if let file = row.fileID {
                        state.vanishedByFile[FileKey(volume: volume.id, file: file), default: []].append(row.id)
                    }
                    vanished.append(row.id)
                }
                state.work[folder] = FolderWork(
                    path: folder, volume: volume.id, signature: signature.rawValue, pending: jobs.count + 1,
                    vanished: vanished,
                )
            }
            return jobs
        }

        /// The other app's `.xmp` of the photo named `name`: `IMG_1234.xmp`, else `IMG_1234.ARW.xmp`.
        static func xmp(for name: String, in xmps: [String: FileEntry]) -> FileEntry? {
            guard !xmps.isEmpty else { return nil }
            let stem = (name as NSString).deletingPathExtension.lowercased()
            return xmps[stem + ".xmp"] ?? xmps[name.lowercased() + ".xmp"]
        }

        /// Whether two dates from listings and the index are the same, allowing for what storing a
        /// date as seconds since 1970 rounds away.
        static func same(_ lhs: Date?, _ rhs: Date?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): true
            case let (lhs?, rhs?): abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < 1e-6
            default: false
            }
        }

        // MARK: - Reading

        private func read(_ volume: VolumeWork) async {
            while let job = await volume.photos.next() {
                do {
                    try await process(job, on: volume)
                } catch {
                    if VolumeIO.isVolumeFailure(error) || !volume.io.isReachable {
                        await volumeFailed(volume)
                    } else {
                        state.withLock { $0.work[job.folder]?.failed = true }
                        if !(error is CancellationError) {
                            failed(job.folder + "/" + job.entry.name, error)
                        }
                    }
                }
                await jobFinished(in: job.folder)
            }
        }

        /// One job done: the folder is indexed once its last is, unless rows of its are to be removed
        /// at the end of the run.
        func jobFinished(in folder: String) async {
            let completion = state.withLock { state -> FolderCompletion? in
                guard var work = state.work[folder] else { return nil }
                work.pending -= 1
                state.work[folder] = work
                guard work.pending == 0, !work.failed, !state.failedVolumes.contains(work.volume) else { return nil }
                guard work.vanished.isEmpty else {
                    state.deferred.append(folder)
                    return nil
                }
                state.work.removeValue(forKey: folder)
                return FolderCompletion(
                    signature: work.signature,
                    counts: FolderIndexed(path: folder, inserted: work.inserted, updated: work.updated),
                )
            }
            if let completion {
                await batcher.add([.complete(completion)])
            }
        }

        /// The volume stopped answering: what it had left is dropped, and its photos are marked offline.
        private func volumeFailed(_ volume: VolumeWork) async {
            let first = state.withLock { $0.failedVolumes.insert(volume.id).inserted }
            guard first else { return }
            volume.walk.close()
            _ = volume.photos.close()
            state.withLock { $0.summary.offlineVolumes.append(volume.key) }
            await batcher.add([.offline(volume: volume.id, key: volume.key)])
        }

        func failed(_ path: String, _ error: any Error) {
            state.withLock { $0.summary.failures += 1 }
            events.yield(.failed(path: path, message: String(describing: error)))
        }

        // MARK: - The end

        /// Removes the rows whose photos vanished and weren't found elsewhere, and the folders that
        /// vanished, then marks the folders that waited for that indexed.
        private func conclude() async {
            let items = state.withLock { state -> [Batcher.Item] in
                let failed = state.failedVolumes
                let deleted = state.vanished.values
                    .filter { !failed.contains($0.volume) && !state.moved.contains($0.record.id) }
                var removed: [String: Int] = [:]
                for photo in deleted {
                    removed[photo.folder, default: 0] += 1
                }
                let folders = state.vanishedFolders.filter { !failed.contains($0.value) }.keys
                let topmost = folders.filter { path in !folders.contains { path.hasPrefix($0 + "/") } }.sorted()
                var items: [Batcher.Item] = []
                if !deleted.isEmpty {
                    items.append(.delete(deleted.map(\.record.id)))
                }
                items += topmost.map(Batcher.Item.deleteFolder)
                for path in state.deferred {
                    guard let work = state.work.removeValue(forKey: path), !work.failed,
                          !failed.contains(work.volume)
                    else { continue }
                    items.append(.complete(FolderCompletion(
                        signature: work.signature,
                        counts: FolderIndexed(
                            path: path, inserted: work.inserted, updated: work.updated, removed: removed[path] ?? 0,
                        ),
                    )))
                }
                state.summary.foldersRemoved += topmost.count
                return items
            }
            await batcher.add(items)
        }

        private func finish() async {
            await batcher.drain()
            let summary = state.withLock { state in
                state.summary.elapsed = ContinuousClock.now - started
                return state.summary
            }
            events.yield(.finished(summary))
        }

        /// A batch is written: its photos are in the index.
        private func committed(_ outcome: Batcher.Outcome) {
            state.withLock { state in
                state.summary.photosInserted += outcome.inserted.count
                state.summary.photosUpdated += outcome.updated.count - outcome.moved
                state.summary.photosMoved += outcome.moved
                state.summary.photosRemoved += outcome.removed.count
                state.summary.foldersIndexed += outcome.completed.count
            }
            if let failure = outcome.failure {
                state.withLock { $0.summary.failures += 1 }
                events.yield(.failed(path: "", message: failure))
            }
            if !outcome.inserted.isEmpty {
                events.yield(.photosInserted(outcome.inserted))
            }
            if !outcome.updated.isEmpty {
                events.yield(.photosUpdated(outcome.updated))
            }
            if !outcome.removed.isEmpty {
                events.yield(.photosRemoved(outcome.removed))
            }
            for folder in outcome.completed {
                events.yield(.folderIndexed(folder))
            }
            for volume in outcome.offline {
                events.yield(.volumeOffline(volume))
            }
        }
    }

    /// What a run keeps while it goes.
    struct RunState: Sendable {
        var volumes: [VolumeWork] = []
        /// The index's folders under the run's roots, as the run started, by path.
        var folders: [String: FolderRecord] = [:]
        var paths: [Int64: String] = [:]
        /// Each folder's subfolders in the index, by path.
        var children: [Int64: [String]] = [:]
        /// Folders handed to the walk.
        var queued: Set<String> = []
        /// Folders listed whose signatures are the ones they were indexed at.
        var unchanged: Set<String> = []
        /// The names of the photos in folders listed with a new signature.
        var names: [String: Set<String>] = [:]
        /// The names in folders listed only to see whether a photo left them; nil for one that's gone.
        var probed: [String: Set<String>?] = [:]
        var work: [String: FolderWork] = [:]
        /// Rows whose photos' names are gone from their folders, by ID.
        var vanished: [Int64: Vanished] = [:]
        var vanishedByFile: [FileKey: [Int64]] = [:]
        /// Rows found renamed or moved.
        var moved: Set<Int64> = []
        /// Folders in the index that listings no longer find, and their volumes.
        var vanishedFolders: [String: Int64] = [:]
        /// Folders indexed but for rows to remove at the end.
        var deferred: [String] = []
        var failedVolumes: Set<Int64> = []
        var summary = LibraryIndexerSummary()
    }

    struct FolderWork: Sendable {
        let path: String
        let volume: Int64
        let signature: Int64
        /// Jobs not finished, and one for the listing until its jobs are queued.
        var pending: Int
        var inserted = 0
        var updated = 0
        /// A job's photo wasn't written: it couldn't be read, or the run was cancelled while it was.
        var failed = false
        var vanished: [Int64]
    }

    struct Vanished: Sendable {
        let record: PhotoRecord
        let folder: String
        let volume: Int64
    }

    struct FileKey: Sendable, Hashable {
        let volume: Int64
        let file: UInt64
    }
}
