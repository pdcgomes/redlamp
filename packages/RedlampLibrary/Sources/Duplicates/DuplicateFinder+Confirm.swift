import Foundation
import RedlampDocument
import Synchronization

public extension DuplicateFinder {
    /// Compares the candidates by their files' full SHA-256: each read through its volume's
    /// readers, a volume's in folder order, and those whose recorded hash still stands not read
    /// again (each is checked on its disk first, as a read one is, for its size and modification
    /// date). Offline and missing photos, and those whose files changed since they were indexed,
    /// are left unconfirmed; so is a photo with no other in its group to compare it with. With
    /// `readingFiles` false, no disk is touched: what the index's recorded hashes say is all there is.
    ///
    /// `progress` is called from any thread as candidates are done. Cancelling the calling task
    /// stops it once the files being read are done, keeping their hashes, and throws
    /// `CancellationError`.
    func confirm(
        _ candidates: DuplicateCandidates, readingFiles: Bool = true, progress: (@Sendable (Progress) -> Void)? = nil,
    ) async throws -> DuplicateConfirmation {
        let started = ContinuousClock.now
        let photos = candidates.groups.flatMap(\.photos)
        let (rows, recorded) = try await index.read { reader in
            try (reader.duplicateRows(photos), reader.photoHashes(photos))
        }
        let run = ConfirmationRun(finder: self, recorded: recorded, progress: progress)
        var unread: [DuplicateRow] = []
        for group in candidates.groups {
            var readable: [DuplicateRow] = []
            for photo in group.photos {
                guard let row = rows[photo] else {
                    run.resolve(photo, .unconfirmed(.missing))
                    continue
                }
                let state = row.record.state
                if state.contains(.offline) {
                    run.resolve(photo, .unconfirmed(.offline))
                } else if state.contains(.missing) {
                    run.resolve(photo, .unconfirmed(.missing))
                } else if state.contains(.settling) {
                    run.resolve(photo, .unconfirmed(.changed))
                } else {
                    readable.append(row)
                }
            }
            if readable.count < 2 {
                readable.forEach { run.resolve($0.record.id, .unconfirmed(.alone)) }
            } else if readingFiles {
                unread += readable
            } else {
                for row in readable {
                    if let hash = recorded[row.record.id], hash.stands(for: row.record) {
                        run.resolve(row.record.id, .hashed(hash.sha256), reused: true)
                    } else {
                        run.resolve(row.record.id, .unconfirmed(.notRead))
                    }
                }
            }
        }
        run.start(unread)

        if readingFiles {
            try await index.write { try $0.removeOrphanedPhotoHashes() }
            let byVolume = Dictionary(grouping: unread) { $0.volume }
            await withTaskGroup(of: Void.self) { group in
                for (volume, rows) in byVolume {
                    group.addTask { await run.check(rows, onVolume: volume) }
                }
            }
            await run.flush(all: true)
            try run.checkWrites()
        }
        try Task.checkCancellation()
        return run.confirmation(candidates, checkedFiles: readingFiles, elapsed: ContinuousClock.now - started)
    }
}

/// Candidates, or a plan's files, handed out one at a time to the tasks reading a volume.
final class DuplicateQueue<Element: Sendable>: Sendable {
    private let elements: Mutex<ArraySlice<Element>>

    init(_ elements: [Element]) {
        self.elements = Mutex(elements[...])
    }

    func next() -> Element? {
        elements.withLock { $0.popFirst() }
    }
}

/// One confirmation: what each candidate has come to, and the hashes waiting to be written.
final class ConfirmationRun: Sendable {
    enum Resolved: Sendable, Hashable {
        case hashed(Data)
        case unconfirmed(DuplicateConfirmation.Unconfirmed)
    }

    private struct State {
        var resolved: [Int64: Resolved] = [:]
        var progress = DuplicateFinder.Progress()
        var hashed = 0
        var unwritten: [PhotoHash] = []
        var writeError: (any Error)?
    }

    let finder: DuplicateFinder
    let recorded: [Int64: PhotoHash]
    let report: (@Sendable (DuplicateFinder.Progress) -> Void)?
    private let state = Mutex(State())

    init(
        finder: DuplicateFinder, recorded: [Int64: PhotoHash],
        progress: (@Sendable (DuplicateFinder.Progress) -> Void)?,
    ) {
        self.finder = finder
        self.recorded = recorded
        report = progress
    }

    func resolve(_ photo: Int64, _ resolved: Resolved, reused: Bool = false) {
        state.withLock { state in
            state.resolved[photo] = resolved
            state.progress.reused += reused ? 1 : 0
        }
    }

    /// Counts `rows` as the candidates left to compare, and the bytes of those without a hash that stands.
    func start(_ rows: [DuplicateRow]) {
        let bytes = rows.filter { recorded[$0.record.id]?.stands(for: $0.record) != true }
            .reduce(0) { $0 + $1.record.size }
        let progress = state.withLock { state in
            state.progress.candidates = state.resolved.count + rows.count
            state.progress.done = state.resolved.count
            state.progress.bytes = bytes
            return state.progress
        }
        report?(progress)
    }

    /// Checks and hashes `rows`, all on the volume the index names `volume`.
    func check(_ rows: [DuplicateRow], onVolume volume: String) async {
        guard let first = rows.first, let io = await finder.io(forVolume: volume, root: first.root) else {
            rows.forEach { done($0, .unconfirmed(.offline)) }
            return
        }
        let queue = DuplicateQueue(rows.sorted { lhs, rhs in
            lhs.folder != rhs.folder ? lhs.folder < rhs.folder : FileOrder.precedes(lhs.record.name, rhs.record.name)
        })
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< DuplicateFinder.filesAtOnce(on: io) {
                group.addTask {
                    while !Task.isCancelled, let row = queue.next() {
                        await self.check(row, on: io)
                    }
                }
            }
        }
    }

    /// The candidate's file as it is on its disk: the size and modification date its row has, and
    /// either a recorded hash that stands for it or a new one.
    private func check(_ row: DuplicateRow, on io: VolumeIO) async {
        let url = row.url
        do {
            let entry = try await io.attributes(of: url)
            guard entry.size == row.record.size, LibraryIndexer.Run.same(entry.modified, row.record.modified) else {
                return done(row, .unconfirmed(.changed))
            }
            if let hash = recorded[row.record.id], hash.stands(for: row.record) {
                return done(row, .hashed(hash.sha256), reused: true)
            }
            let sha256 = try await DuplicateFinder.sha256(of: url, size: Int(row.record.size), on: io) { bytes in
                self.read(bytes)
            }
            state.withLock { state in
                state.hashed += 1
                state.unwritten.append(PhotoHash(row.record, sha256: sha256))
            }
            done(row, .hashed(sha256))
            await flush(all: false)
        } catch is CancellationError {
            return
        } catch where VolumeIO.isNotFound(error) {
            done(row, .unconfirmed(.missing))
        } catch is DuplicateFinder.FileChanged {
            done(row, .unconfirmed(.changed))
        } catch where VolumeIO.isVolumeFailure(error) || !io.isReachable {
            done(row, .unconfirmed(.offline))
        } catch {
            done(row, .unconfirmed(.unreadable))
        }
    }

    private func read(_ bytes: Int) {
        let progress = state.withLock { state in
            state.progress.bytesRead += Int64(bytes)
            return state.progress
        }
        report?(progress)
    }

    private func done(_ row: DuplicateRow, _ resolved: Resolved, reused: Bool = false) {
        let progress = state.withLock { state in
            state.resolved[row.record.id] = resolved
            state.progress.done += 1
            state.progress.reused += reused ? 1 : 0
            return state.progress
        }
        report?(progress)
    }

    /// Writes the hashes waiting, once there are a batch of them, or all of them.
    func flush(all: Bool) async {
        let batch = state.withLock { state -> [PhotoHash] in
            guard !state.unwritten.isEmpty, all || state.unwritten.count >= DuplicateFinder.hashBatch else { return [] }
            defer { state.unwritten = [] }
            return state.unwritten
        }
        guard !batch.isEmpty else { return }
        do {
            try await finder.index.write { try $0.setPhotoHashes(batch) }
        } catch {
            state.withLock { $0.writeError = $0.writeError ?? error }
        }
    }

    /// Throws the first write of hashes that failed.
    func checkWrites() throws {
        if let error = state.withLock({ $0.writeError }) {
            throw error
        }
    }

    /// Each candidate group's photos as they came out: copies of one file where two or more full
    /// hashes agree, different where a hash agrees with none of the others read, and unconfirmed
    /// where there was nothing to compare.
    func confirmation(
        _ candidates: DuplicateCandidates, checkedFiles: Bool, elapsed: Duration,
    ) -> DuplicateConfirmation {
        let (resolved, progress, hashed) = state.withLock { ($0.resolved, $0.progress, $0.hashed) }
        let groups = candidates.groups.map { group in
            var hashes: [Int64: Data] = [:]
            for photo in group.photos {
                if case let .hashed(sha256) = resolved[photo] {
                    hashes[photo] = sha256
                }
            }
            var counts: [Data: Int] = [:]
            for sha256 in hashes.values {
                counts[sha256, default: 0] += 1
            }
            return DuplicateConfirmation.Group(
                contentKey: group.contentKey, size: group.size,
                candidates: group.photos.map { photo in
                    let status: DuplicateConfirmation.Status = switch resolved[photo] {
                    case let .hashed(sha256) where counts[sha256, default: 0] >= 2: .duplicate(sha256: sha256)
                    case let .hashed(sha256) where hashes.count >= 2: .different(sha256: sha256)
                    case .hashed: .unconfirmed(.alone)
                    case let .unconfirmed(reason): .unconfirmed(reason)
                    case nil: .unconfirmed(.notRead)
                    }
                    return DuplicateConfirmation.Candidate(photo: photo, status: status)
                },
            )
        }
        return DuplicateConfirmation(
            groups: groups, checkedFiles: checkedFiles, hashed: hashed, reused: progress.reused,
            bytesRead: progress.bytesRead, elapsed: elapsed,
        )
    }
}
