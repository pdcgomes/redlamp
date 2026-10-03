import Foundation
import RedlampDocument

/// Writes sidecars one at a time, in the order they were asked for, on a serial queue of its
/// own: coordinated file I/O blocks, so it stays off the main thread and the cooperative pool.
/// A save asked for while an earlier one of the same session still waits replaces it.
final class SaveQueue: @unchecked Sendable {
    enum Write: Sendable {
        /// The photo's whole sidecar, written as `SidecarStore.saveOrRemove` does.
        case sidecar(Sidecar)
        /// A change to the culling metadata of the sidecar as it is on disk then.
        case metadata(@Sendable (inout PhotoMetadata) -> Void)
    }

    static let label = "app.redlamp.saves"

    let store: SidecarStore
    private let queue = DispatchQueue(label: SaveQueue.label, qos: .utility)
    private let lock = NSLock()
    /// Writes not started yet, per photo, oldest first.
    private var waiting: [URL: [Write]] = [:]
    /// Writes asked for and not finished, the one being written included.
    private var unfinished: [URL: Int] = [:]
    private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    init(store: SidecarStore) {
        self.store = store
    }

    func enqueue(_ write: Write, for url: URL) {
        lock.withLock {
            var writes = waiting[url, default: []]
            if case let .sidecar(next) = write, case let .sidecar(last)? = writes.last,
               next.session?.id == last.session?.id {
                var merged = next
                merged.clearsHistory = next.clearsHistory || last.clearsHistory
                writes[writes.count - 1] = .sidecar(merged)
            } else {
                writes.append(write)
                unfinished[url, default: 0] += 1
            }
            waiting[url] = writes
        }
        queue.async { self.writeNext(for: url) }
    }

    /// Returns once every write asked for `url` before the call has finished.
    func wait(for url: URL) async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                guard unfinished[url] != nil else { return true }
                waiters[url, default: []].append(continuation)
                return false
            }
            if done {
                continuation.resume()
            }
        }
    }

    /// Returns once every write asked for before the call has finished.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    /// Runs `body` on the queue, after every write asked for before the call and before any
    /// asked for after it.
    func read<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private func writeNext(for url: URL) {
        let write: Write? = lock.withLock {
            guard var writes = waiting[url], !writes.isEmpty else { return nil }
            let first = writes.removeFirst()
            waiting[url] = writes.isEmpty ? nil : writes
            return first
        }
        guard let write else { return }
        switch write {
        case let .sidecar(sidecar):
            try? store.saveOrRemove(sidecar, for: url)
        case let .metadata(change):
            try? Library.writeMetadata(for: url, store: store, change)
        }
        let done = lock.withLock {
            let left = unfinished[url, default: 1] - 1
            unfinished[url] = left > 0 ? left : nil
            return left > 0 ? [] : waiters.removeValue(forKey: url) ?? []
        }
        done.forEach { $0.resume() }
    }
}
