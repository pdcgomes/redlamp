import Foundation
import Synchronization

extension LibraryIndexer {
    /// A photo whose end is still to be read to know whether it ends early (LIB-40): what it was
    /// read as, and where its format's judgement goes on from.
    struct EndCheck: Sendable {
        let folder: String
        let name: String
        let size: Int64
        let modified: Date
        let format: PhotoFormat
        /// An ISO base media file's next top-level box.
        var boxesFrom = 0
    }

    /// How a photo's end read came out, for its health in the index.
    struct EndResult: Sendable {
        let check: EndCheck
        /// Nil when it ends where its data does, or its format doesn't say.
        let damage: PhotoHealth.Damage?
    }

    /// A volume's photos whose ends are to be read: by its readers once its photos are read, so the
    /// photos come first. It's finished once every reader is done with photos and none waits.
    final class EndQueue: Sendable {
        private struct State {
            var checks: [EndCheck] = []
            var next = 0
            /// Readers still reading photos, which may add more.
            var producers: Int
            var closed = false
            var waiters: [CheckedContinuation<EndCheck?, Never>] = []
        }

        private let state: Mutex<State>

        init(producers: Int) {
            state = Mutex(State(producers: producers))
        }

        func add(_ checks: [EndCheck]) {
            guard !checks.isEmpty else { return }
            let handed = state.withLock { state -> [(CheckedContinuation<EndCheck?, Never>, EndCheck)] in
                guard !state.closed else { return [] }
                state.checks += checks
                var handed: [(CheckedContinuation<EndCheck?, Never>, EndCheck)] = []
                while !state.waiters.isEmpty, let check = take(&state) {
                    handed.append((state.waiters.removeFirst(), check))
                }
                return handed
            }
            for (waiter, check) in handed {
                waiter.resume(returning: check)
            }
        }

        /// A reader is done with photos.
        func producerDone() {
            let waiters = state.withLock { state -> [CheckedContinuation<EndCheck?, Never>] in
                state.producers = max(state.producers - 1, 0)
                guard state.producers == 0, state.next == state.checks.count else { return [] }
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
        }

        /// The next end to read, waiting while readers may add more; nil once there are none.
        func next() async -> EndCheck? {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> EndCheck?? in
                    if let check = take(&state) {
                        return .some(check)
                    }
                    if state.closed || state.producers == 0 {
                        return .some(nil)
                    }
                    state.waiters.append(continuation)
                    return nil
                }
                if let ready {
                    continuation.resume(returning: ready)
                }
            }
        }

        /// Stops at once: what waits is dropped.
        func close() {
            let waiters = state.withLock { state -> [CheckedContinuation<EndCheck?, Never>] in
                state.closed = true
                state.checks = []
                state.next = 0
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
        }

        private func take(_ state: inout State) -> EndCheck? {
            guard !state.closed, state.next < state.checks.count else { return nil }
            let check = state.checks[state.next]
            state.next += 1
            if state.next == state.checks.count {
                state.checks = []
                state.next = 0
            }
            return check
        }
    }
}

extension LibraryIndexer.Run {
    /// Reads at most this many parts of a file to judge its end, beyond the head.
    static let endReads = 16

    /// Reads the ends `volume`'s queue holds, at the volume's lower priority, judging each on the
    /// scheduler's background lane. A file that's no longer as it was listed is left for the listing
    /// its change brings; one gone is left alone.
    func readEnds(on volume: LibraryIndexer.VolumeWork) async {
        while let check = await volume.ends.next() {
            if let result = await readEnd(check, on: volume) {
                state.withLock { $0.summary.endsRead += 1 }
                await batcher.add([.end(result)])
            }
        }
    }

    private func readEnd(
        _ check: LibraryIndexer.EndCheck, on volume: LibraryIndexer.VolumeWork,
    ) async -> LibraryIndexer.EndResult? {
        let url = URL(fileURLWithPath: check.folder + "/" + check.name, isDirectory: false)
        let size = Int(check.size)
        var bytes = FileBytes()
        var end = FileEnd.judge(check.format, size: size, bytes: bytes, boxesFrom: check.boxesFrom)
        do {
            var reads = 0
            while case let .needs(range) = end {
                guard reads < Self.endReads else {
                    end = .whole
                    break
                }
                let data = try await volume.io.read(url, range: range, priority: .normal)
                guard data.count == range.count else { return nil }
                bytes.add(data, at: range.lowerBound)
                reads += 1
                let read = bytes
                end = try await indexer.scheduler.run(.background) {
                    FileEnd.judge(check.format, size: size, bytes: read, boxesFrom: check.boxesFrom)
                }
            }
            let entry = try await volume.io.attributes(of: url, priority: .normal)
            guard entry.size == check.size, Self.same(entry.modified, check.modified) else { return nil }
        } catch where VolumeIO.isNotFound(error) || error is CancellationError {
            return nil
        } catch where VolumeIO.isVolumeFailure(error) || !volume.io.isReachable {
            await volumeFailed(volume)
            return nil
        } catch is VolumeOperationTimedOut {
            return nil
        } catch {
            return LibraryIndexer.EndResult(check: check, damage: .unreadable(PhotoHealth.reason(for: error)))
        }
        guard case let .early(missing) = end else { return LibraryIndexer.EndResult(check: check, damage: nil) }
        return LibraryIndexer.EndResult(check: check, damage: .endsEarly(missing: missing))
    }
}
