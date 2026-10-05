import Foundation
import RedlampDocument
import Synchronization

extension LibraryIndexer {
    /// A folder's listing, to record, adding its row if the index doesn't have it.
    struct FolderListing: Sendable {
        let path: String
        let root: Int64
        let parent: String?
        let signature: Int64
        let listedAt: Date
    }

    /// A folder whose photos are all written: it's indexed at `signature`.
    struct FolderCompletion: Sendable {
        let signature: Int64
        let counts: FolderIndexed
    }

    /// A run's writes, written in the order they're added, in transactions of up to `batchSize`
    /// photos: a batch is written once it's full (or holds `retainedHeadBytes` of heads for the
    /// thumbnails), or `batchInterval` after the first of its items arrived. Adding waits while three
    /// batches' worth wait to be written.
    final class Batcher: Sendable {
        enum Item: Sendable {
            case folder(FolderListing)
            case photo(PendingPhoto)
            case move(PendingMove)
            case delete([Int64])
            case deleteFolder(String)
            case complete(FolderCompletion)
            case offline(volume: Int64, key: String)

            var photos: Int {
                switch self {
                case .photo, .move: 1
                default: 0
                }
            }

            var retained: Int {
                guard case let .photo(photo) = self else { return 0 }
                return photo.thumbnail?.head.count ?? 0
            }
        }

        /// What a batch changed, once it's written.
        struct Outcome: Sendable {
            var inserted: [Int64] = []
            var updated: [Int64] = []
            /// Of `updated`, the photos renamed or moved.
            var moved = 0
            var removed: [Int64] = []
            var completed: [FolderIndexed] = []
            /// The volumes whose photos were marked offline, by key.
            var offline: [String] = []
            var failure: String?
        }

        private struct State {
            var pending: [Item] = []
            var head = 0
            var photos = 0
            var retained = 0
            var oldest: ContinuousClock.Instant?
            var writing = false
            var draining = false
            var ticker: Task<Void, Never>?
            var room: [CheckedContinuation<Void, Never>] = []
            var drained: [CheckedContinuation<Void, Never>] = []
        }

        private let index: LibraryIndex
        private let configuration: Configuration
        private let scheduler: WorkScheduler
        private let thumbnails: Thumbnails?
        private let committed: @Sendable (Outcome) -> Void
        private let state = Mutex(State())

        init(
            index: LibraryIndex, configuration: Configuration, scheduler: WorkScheduler, thumbnails: Thumbnails?,
            committed: @escaping @Sendable (Outcome) -> Void,
        ) {
            self.index = index
            self.configuration = configuration
            self.scheduler = scheduler
            self.thumbnails = thumbnails
            self.committed = committed
        }

        func add(_ items: [Item]) async {
            guard !items.isEmpty else { return }
            let (start, tick) = state.withLock { state -> (Bool, Bool) in
                state.pending += items
                state.photos += items.reduce(0) { $0 + $1.photos }
                state.retained += items.reduce(0) { $0 + $1.retained }
                state.oldest = state.oldest ?? .now
                let tick = state.ticker == nil && !state.draining
                return (startIfDue(&state), tick)
            }
            if tick {
                startTicker()
            }
            if start {
                startWriting()
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let full = state.withLock { state -> Bool in
                    guard state.photos >= 3 * configuration.batchSize else { return false }
                    state.room.append(continuation)
                    return true
                }
                if !full {
                    continuation.resume()
                }
            }
        }

        /// Writes everything added, and returns once it's written.
        func drain() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let (start, done, ticker) = state.withLock { state -> (Bool, Bool, Task<Void, Never>?) in
                    state.draining = true
                    let ticker = state.ticker
                    state.ticker = nil
                    if state.pending.count == state.head, !state.writing {
                        return (false, true, ticker)
                    }
                    state.drained.append(continuation)
                    return (startIfDue(&state), false, ticker)
                }
                ticker?.cancel()
                if done {
                    continuation.resume()
                }
                if start {
                    startWriting()
                }
            }
        }

        private func isDue(_ state: State) -> Bool {
            guard state.pending.count > state.head else { return false }
            return state.draining || state.photos >= configuration.batchSize
                || state.retained >= configuration.retainedHeadBytes
                || state.oldest.map { .now - $0 >= configuration.batchInterval } ?? false
        }

        private func startIfDue(_ state: inout State) -> Bool {
            guard !state.writing, isDue(state) else { return false }
            state.writing = true
            return true
        }

        private func startTicker() {
            let interval = configuration.batchInterval / 4
            let ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard let self else { return }
                    if state.withLock({ startIfDue(&$0) }) {
                        startWriting()
                    }
                }
            }
            let stale = state.withLock { state -> Bool in
                guard state.ticker == nil, !state.draining else { return true }
                state.ticker = ticker
                return false
            }
            if stale {
                ticker.cancel()
            }
        }

        private func startWriting() {
            Task {
                while let batch = nextBatch() {
                    await write(batch)
                }
            }
        }

        /// The next batch to write, if one is due; otherwise the writer stops.
        private func nextBatch() -> [Item]? {
            let (batch, waiting) = state.withLock { state -> ([Item]?, [CheckedContinuation<Void, Never>]) in
                guard isDue(state) else {
                    state.writing = false
                    var waiting = state.room
                    state.room = []
                    if state.pending.count == state.head {
                        waiting += state.drained
                        state.drained = []
                    }
                    return (nil, waiting)
                }
                var batch: [Item] = []
                var photos = 0
                while state.head < state.pending.count, photos < configuration.batchSize {
                    let item = state.pending[state.head]
                    state.head += 1
                    photos += item.photos
                    state.retained -= item.retained
                    batch.append(item)
                }
                state.photos -= photos
                if state.head == state.pending.count {
                    state.pending = []
                    state.head = 0
                    state.oldest = nil
                } else {
                    if state.head > 4096 {
                        state.pending.removeFirst(state.head)
                        state.head = 0
                    }
                    state.oldest = .now
                }
                var waiting: [CheckedContinuation<Void, Never>] = []
                if state.photos < 3 * configuration.batchSize {
                    waiting = state.room
                    state.room = []
                }
                return (batch, waiting)
            }
            for continuation in waiting {
                continuation.resume()
            }
            return batch
        }

        private func write(_ batch: [Item]) async {
            var outcome: Outcome
            do {
                outcome = try await index.write { writer in try Self.apply(batch, writer) }
            } catch {
                outcome = Outcome()
                outcome.failure = String(describing: error)
            }
            committed(outcome)
            guard outcome.failure == nil, let thumbnails else { return }
            for item in batch {
                guard case let .photo(photo) = item, let thumbnail = photo.thumbnail else { continue }
                scheduler.submit(.background) {
                    thumbnails(thumbnail.url, thumbnail.key, thumbnail.head)
                }
            }
        }

        /// Writes `batch` in one transaction: folders first, in order, then moves, then photos, then
        /// what's removed, then the folders that are indexed.
        static func apply(_ batch: [Item], _ writer: LibraryIndex.Writer) throws -> Outcome {
            var outcome = Outcome()
            var folders: [String: Int64] = [:]
            func folderID(_ path: String) throws -> Int64? {
                if let id = folders[path] {
                    return id
                }
                let id = try writer.folder(path: path)?.id
                folders[path] = id
                return id
            }
            var photos: [PendingPhoto] = []
            var moves: [PendingMove] = []
            var deleted: [Int64] = []
            var deletedFolders: [String] = []
            var completed: [FolderCompletion] = []
            var offline: [(volume: Int64, key: String)] = []
            for item in batch {
                switch item {
                case let .folder(listing):
                    if let id = try folderID(listing.path) {
                        try writer.setListing(signature: listing.signature, listedAt: listing.listedAt, forFolder: id)
                    } else {
                        let parent = try listing.parent.flatMap { try folderID($0) }
                        folders[listing.path] = try writer.upsertFolder(FolderRecord(
                            root: listing.root, parent: parent, path: listing.path, signature: listing.signature,
                            listedAt: listing.listedAt,
                        ))
                    }
                case let .photo(photo): photos.append(photo)
                case let .move(move): moves.append(move)
                case let .delete(ids): deleted += ids
                case let .deleteFolder(path): deletedFolders.append(path)
                case let .complete(completion): completed.append(completion)
                case let .offline(volume, key): offline.append((volume, key))
                }
            }

            var moving: [(photo: Int64, folder: Int64, name: String)] = []
            var updated = Set<Int64>()
            for move in moves {
                guard let folder = try folderID(move.folder) else { continue }
                moving.append((move.id, folder, move.name))
                updated.insert(move.id)
                if let replacement = move.replacement {
                    photos.append(replacement)
                }
            }
            try writer.movePhotos(moving)
            outcome.updated = moving.map(\.photo)
            outcome.moved = moving.count

            var records: [PhotoRecord] = []
            var written: [PendingPhoto] = []
            for var photo in photos {
                guard let folder = try folderID(photo.folder) else { continue }
                photo.record.folder = folder
                if let camera = photo.camera {
                    photo.record.camera = try writer.cameraID(for: camera.name, make: camera.make, model: camera.model)
                }
                if let lens = photo.lens {
                    photo.record.lens = try writer.lensID(for: lens)
                }
                records.append(photo.record)
                written.append(photo)
            }
            for (photo, id) in try zip(written, writer.upsertPhotos(records)) {
                if let keywords = photo.keywords, !(photo.isNew && keywords.isEmpty) {
                    try writer.setKeywords(keywords, forPhoto: id)
                }
                if photo.isNew {
                    outcome.inserted.append(id)
                } else if updated.insert(id).inserted {
                    outcome.updated.append(id)
                }
            }

            if !deleted.isEmpty {
                try writer.deletePhotos(deleted)
                outcome.removed += deleted
            }
            for path in deletedFolders {
                guard let id = try folderID(path) else { continue }
                outcome.removed += try writer.photoIDs(inSubtreeOf: id)
                try writer.deleteFolder(id)
            }
            for completion in completed {
                guard let id = try folderID(completion.counts.path) else { continue }
                try writer.setIndexedSignature(completion.signature, forFolder: id)
                outcome.completed.append(completion.counts)
            }
            for volume in offline {
                try writer.setOffline(true, onVolume: volume.volume, uuid: volume.key)
                outcome.offline.append(volume.key)
            }
            return outcome
        }
    }
}
