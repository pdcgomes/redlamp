import Foundation
import RedlampDocument

/// Writes sidecars one at a time, in the order they were asked for, on a serial queue of its
/// own: coordinated file I/O blocks, so it stays off the main thread and the cooperative pool.
/// A save asked for while an earlier one of the same session still waits replaces it. A photo
/// being tracked is saved over its base, so what another writer saved since isn't lost.
final class SaveQueue: @unchecked Sendable {
    enum Write: Sendable {
        /// The photo's whole sidecar, written as `SidecarStore.saveOrRemove` does.
        case sidecar(Sidecar)
        /// A change to the culling metadata of the sidecar as it is on disk then.
        case metadata(@Sendable (inout PhotoMetadata) -> Void)
        /// From now on the photo's saves go over `base` (nil: the sidecar as it is then);
        /// `opened` is the editor's state when it took it, to tell what changed here. A photo
        /// still tracked whose last save failed keeps the base it had: a newer one would hide
        /// what another writer saved since.
        case track(SidecarBase?, opened: Sidecar)
        /// The photo's saves no longer look for another writer's, from when its last save has
        /// gone through: one that failed is tried again over the same base.
        case forget

        /// Writes to the photo's sidecar, rather than telling the queue how to.
        var isSave: Bool {
            switch self {
            case .sidecar, .metadata: true
            case .track, .forget: false
            }
        }
    }

    enum Outcome: Sendable {
        case saved
        /// Another writer's edit is on disk, merged with what changed here or as they left it,
        /// for the editor to show. Until it is tracked again, its saves go over the old base, or,
        /// when the edit here won the merge, are merged into what was written.
        case replaced(SidecarBase)
        /// `merged`: another writer saved since the base, and this is the edit the save would
        /// have left, for the editor to show until a save goes through and merges again.
        case failed(any Error, merged: Sidecar?)
    }

    /// A tracked save that failed after another writer had saved.
    private struct FailedOverOtherWriter: Error {
        let error: any Error
        let merged: Sidecar
    }

    static let label = "app.redlamp.saves"

    let store: SidecarStore
    private let queue = DispatchQueue(label: SaveQueue.label, qos: .utility)
    private let lock = NSLock()
    /// Writes not started yet, per photo, oldest first.
    private var waiting: [URL: [Write]] = [:]
    /// Saves asked for and not finished, the one being written included.
    private var unfinished: [URL: Int] = [:]
    private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    /// A save's result, and whether a later save of the photo was waiting when it finished.
    typealias Report = @MainActor @Sendable (URL, Write, Outcome, _ superseded: Bool) -> Void
    private var report: Report?
    /// Photos whose last save failed, but for a rating on one that must be left as it is.
    private var failing: Set<URL> = []
    /// A tracked photo's saves.
    private struct Tracked {
        /// What the next save goes over.
        var base: SidecarBase
        /// The editor's state when it took `base`, or when `merged` was written.
        var opened: Sidecar
        /// What a merge the edit here won wrote, until the editor shows it. Each save is merged
        /// into it as into another writer's edit, so what only it has (their snapshots and
        /// metadata, the older edit kept as a snapshot) stays, and the clash isn't found again.
        var merged: Sidecar?
        /// The editor has left the photo while its last save had failed: once a save goes
        /// through, it isn't tracked.
        var isLeft = false
    }

    /// Only the queue uses it.
    private var tracking: [URL: Tracked] = [:]

    init(store: SidecarStore) {
        self.store = store
    }

    /// Tells `report`, on the main actor and in order, how each save went.
    func reportResults(to report: @escaping Report) {
        lock.withLock { self.report = report }
    }

    /// The photos whose last save failed.
    var failedPhotos: Set<URL> {
        lock.withLock { failing }
    }

    /// Whether a save asked for `url` hasn't finished.
    func isPending(_ url: URL) -> Bool {
        lock.withLock { unfinished[url] != nil }
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
                if write.isSave {
                    unfinished[url, default: 0] += 1
                }
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

    /// Blocks until every write asked for before the call has finished, or `limit` has passed;
    /// false if it ran out. Only for quitting: writes never need the calling thread.
    func flush(waitingAtMost limit: Duration) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        let (seconds, attoseconds) = limit.components
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        return done.wait(timeout: .now() + .nanoseconds(nanoseconds)) == .success
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
        let outcome: Outcome?
        do {
            outcome = try perform(write, for: url)
        } catch let failure as FailedOverOtherWriter {
            outcome = .failed(failure.error, merged: failure.merged)
        } catch {
            outcome = .failed(error, merged: nil)
        }
        guard write.isSave, let outcome else { return }
        var report: Report?
        var superseded = false
        let done: [CheckedContinuation<Void, Never>] = lock.withLock {
            switch (outcome, write) {
            case let (.failed(error, _), .metadata) where error is SidecarStoreError: break
            case (.failed, _): failing.insert(url)
            default: failing.remove(url)
            }
            let left = unfinished[url, default: 1] - 1
            unfinished[url] = left > 0 ? left : nil
            superseded = waiting[url]?.contains(where: \.isSave) ?? false
            report = self.report
            return left > 0 ? [] : waiters.removeValue(forKey: url) ?? []
        }
        if let report {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { report(url, write, outcome, superseded) }
            }
        }
        done.forEach { $0.resume() }
    }

    /// Nil for what isn't a save.
    private func perform(_ write: Write, for url: URL) throws -> Outcome? {
        switch write {
        case let .sidecar(sidecar):
            guard let tracked = tracking[url] else {
                try store.saveOrRemove(sidecar, for: url)
                return .saved
            }
            let outcome = try save(sidecar, over: tracked, for: url)
            if tracked.isLeft {
                tracking[url] = nil
            }
            return outcome
        case let .metadata(change):
            try Library.writeMetadata(for: url, store: store, change)
            return .saved
        case let .track(base, opened):
            if tracking[url] != nil, lock.withLock({ failing.contains(url) }) {
                tracking[url]?.isLeft = false
            } else {
                tracking[url] = Tracked(base: base ?? store.base(for: url), opened: opened)
            }
            return nil
        case .forget:
            if lock.withLock({ failing.contains(url) }) {
                tracking[url]?.isLeft = true
            } else {
                tracking[url] = nil
            }
            return nil
        }
    }

    private func save(_ asked: Sidecar, over tracked: Tracked, for url: URL) throws -> Outcome {
        var sidecar = asked
        if let merged = tracked.merged {
            sidecar = SidecarStore.merge(asked, merged, base: tracked.opened, opened: tracked.opened)
            sidecar.clearsHistory = asked.clearsHistory
        }
        let opened = tracked.merged ?? tracked.opened
        let saved: SidecarSaveOutcome
        do {
            saved = try store.saveOrRemove(sidecar, for: url, over: tracked.base, opened: opened)
        } catch where !(error is SidecarStoreError) {
            guard let merged = store.mergedWithOtherWriter(sidecar, for: url, over: tracked.base, opened: opened)
            else { throw error }
            throw FailedOverOtherWriter(error: error, merged: merged)
        }
        switch saved {
        case let .saved(base):
            guard tracked.merged != nil else {
                tracking[url] = Tracked(base: base, opened: sidecar)
                return .saved
            }
            tracking[url] = Tracked(base: base, opened: asked, merged: sidecar)
            return .replaced(base)
        case let .merged(base) where base.sidecar?.recipe == asked.recipe:
            tracking[url] = Tracked(base: base, opened: asked, merged: base.sidecar)
            return .replaced(base)
        case let .theirs(base), let .merged(base):
            return .replaced(base)
        }
    }
}
