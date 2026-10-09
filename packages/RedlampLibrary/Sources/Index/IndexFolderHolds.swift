import Foundation
import Synchronization

/// The folders file batches are changing (LIB-26), between the batches and the indexer, which both go through the
/// index. A batch holds the folders its steps change once the listings of them under way are done, and lets them go
/// once its index is written; the indexer lists a folder held, or one below a folder held whole, only after that. So
/// no listing sees a batch half done: photos it has moved but whose rows it hasn't moved yet, which the indexer would
/// remove as vanished from where they were, their collections and keywords with them, and read afresh where they are,
/// under new IDs.
final class FolderHolds: Sendable {
    /// A folder a batch changes: its own entries, or with everything below it where folders move, are made or go.
    struct Folder: Sendable, Hashable {
        let path: String
        let subtree: Bool

        init(_ path: String, subtree: Bool = false) {
            self.path = path.precomposedStringWithCanonicalMapping
            self.subtree = subtree
        }

        func covers(_ path: String) -> Bool {
            path == self.path || subtree && path.hasPrefix(self.path + "/")
        }
    }

    /// A batch's folders, held until `release`.
    struct Hold: Sendable {
        fileprivate let holds: FolderHolds
        fileprivate let folders: [Folder]

        func release() {
            holds.end { state in
                for folder in folders {
                    state.held[folder, default: 1] -= 1
                    if state.held[folder] == 0 {
                        state.held[folder] = nil
                    }
                }
            }
        }
    }

    /// A listing of a folder under way, until `done`.
    struct Listing: Sendable {
        fileprivate let holds: FolderHolds
        fileprivate let path: String

        func done() {
            holds.end { state in
                state.listing[path, default: 1] -= 1
                if state.listing[path] == 0 {
                    state.listing[path] = nil
                }
            }
        }
    }

    private enum Wait: Sendable {
        case listing(String)
        case hold([Folder])
    }

    private struct Waiter {
        let wait: Wait
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var held: [Folder: Int] = [:]
        var listing: [String: Int] = [:]
        var waiters: [UInt64: Waiter] = [:]
        var cancelled: Set<UInt64> = []
        var last: UInt64 = 0
    }

    private let state = Mutex(State())

    /// Holds `folders` once no listing of one of them is under way.
    func hold(_ folders: Set<Folder>) async -> Hold {
        let folders = Array(folders)
        _ = await begin(.hold(folders), cancellable: false)
        return Hold(holds: self, folders: folders)
    }

    /// Waits while a batch holds `folder`, then counts it as listed until the listing is `done`; throws
    /// `CancellationError` when the task is cancelled while it waits.
    func list(_ folder: String) async throws -> Listing {
        let path = folder.precomposedStringWithCanonicalMapping
        guard await begin(.listing(path), cancellable: true) else { throw CancellationError() }
        return Listing(holds: self, path: path)
    }

    /// The listings waiting for a batch to let their folders go.
    var waitingListings: Int {
        state.withLock { state in
            state.waiters.values.count { waiter in
                if case .listing = waiter.wait {
                    true
                } else {
                    false
                }
            }
        }
    }

    /// Takes what `wait` asks for once it's free, those that waited for the same folders in the order asked; false
    /// when cancelled first.
    private func begin(_ wait: Wait, cancellable: Bool) async -> Bool {
        let id = state.withLock { state in
            state.last += 1
            return state.last
        }
        let waiting = {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let ready = self.state.withLock { state -> Bool? in
                    if state.cancelled.remove(id) != nil {
                        return false
                    }
                    guard Self.isFree(wait, in: state) else {
                        state.waiters[id] = Waiter(wait: wait, continuation: continuation)
                        return nil
                    }
                    Self.take(wait, in: &state)
                    return true
                }
                if let ready {
                    continuation.resume(returning: ready)
                }
            }
        }
        guard cancellable else { return await waiting() }
        return await withTaskCancellationHandler(operation: waiting) {
            let waiter = self.state.withLock { state -> Waiter? in
                guard let waiter = state.waiters.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return waiter
            }
            waiter?.continuation.resume(returning: false)
        }
    }

    /// Ends a hold or a listing with `change`, then starts what waited for it, in the order asked.
    private func end(_ change: (inout State) -> Void) {
        let started = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
            change(&state)
            var started: [CheckedContinuation<Bool, Never>] = []
            for id in state.waiters.keys.sorted() {
                guard let waiter = state.waiters[id], Self.isFree(waiter.wait, in: state) else { continue }
                Self.take(waiter.wait, in: &state)
                state.waiters[id] = nil
                started.append(waiter.continuation)
            }
            return started
        }
        for continuation in started {
            continuation.resume(returning: true)
        }
    }

    private static func isFree(_ wait: Wait, in state: State) -> Bool {
        switch wait {
        case let .listing(path): !state.held.keys.contains { $0.covers(path) }
        case let .hold(folders): !state.listing.keys.contains { path in folders.contains { $0.covers(path) } }
        }
    }

    private static func take(_ wait: Wait, in state: inout State) {
        switch wait {
        case let .listing(path):
            state.listing[path, default: 0] += 1
        case let .hold(folders):
            for folder in folders {
                state.held[folder, default: 0] += 1
            }
        }
    }
}
