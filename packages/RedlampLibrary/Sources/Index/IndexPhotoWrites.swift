import Foundation
import Synchronization

/// The photos the library's batches are writing (LIB-07): a batch gives them their fields in the index first, then
/// writes their sidecars and records the sidecars' dates, so meanwhile the index is ahead of their files. What the
/// indexer read of one of them before the batch is done is older than the index: it isn't written, and the indexer
/// reads the photo again once the batch is.
final class PhotoWrites: Sendable {
    /// A batch's photos, being written until `end`.
    struct Writing: Sendable {
        fileprivate let writes: PhotoWrites
        fileprivate let photos: [Int64]

        func end() {
            writes.end(photos)
        }
    }

    private struct Waiter {
        let photos: Set<Int64>
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var writing: [Int64: Int] = [:]
        var waiters: [UInt64: Waiter] = [:]
        var cancelled: Set<UInt64> = []
        var last: UInt64 = 0

        func isWriting(any photos: Set<Int64>) -> Bool {
            photos.contains { writing[$0] != nil }
        }
    }

    private let state = Mutex(State())

    func begin(_ photos: some Sequence<Int64>) -> Writing {
        let photos = Array(photos)
        state.withLock { state in
            for photo in photos {
                state.writing[photo, default: 0] += 1
            }
        }
        return Writing(writes: self, photos: photos)
    }

    func isWriting(_ photo: Int64) -> Bool {
        state.withLock { $0.writing[photo] != nil }
    }

    /// The runs waiting for batches to finish writing photos they read.
    var waiting: Int {
        state.withLock { $0.waiters.count }
    }

    /// Returns once no batch is writing any of `photos`, or the task is cancelled.
    func idle(_ photos: Set<Int64>) async {
        let waiter = state.withLock { state -> UInt64? in
            guard state.isWriting(any: photos) else { return nil }
            state.last += 1
            return state.last
        }
        guard let id = waiter else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = self.state.withLock { state -> Bool in
                    guard state.cancelled.remove(id) == nil, state.isWriting(any: photos) else { return true }
                    state.waiters[id] = Waiter(photos: photos, continuation: continuation)
                    return false
                }
                if ready {
                    continuation.resume()
                }
            }
        } onCancel: {
            let waiter = self.state.withLock { state -> Waiter? in
                guard let waiter = state.waiters.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return waiter
            }
            waiter?.continuation.resume()
        }
    }

    private func end(_ photos: [Int64]) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            for photo in photos {
                state.writing[photo, default: 1] -= 1
                if state.writing[photo] == 0 {
                    state.writing[photo] = nil
                }
            }
            var ready: [CheckedContinuation<Void, Never>] = []
            for (id, waiter) in state.waiters where !state.isWriting(any: waiter.photos) {
                state.waiters[id] = nil
                ready.append(waiter.continuation)
            }
            return ready
        }
        for continuation in ready {
            continuation.resume()
        }
    }
}
