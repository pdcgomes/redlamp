import Foundation
import Synchronization

/// A list as `LibraryLive` hands it over: the list, and how it changed since the one handed over
/// before.
public struct PhotoListUpdate: Sendable, Equatable {
    public let list: PhotoList
    /// From the list handed over before; `reset` for the first.
    public let diff: PhotoListDiff

    public init(list: PhotoList, diff: PhotoListDiff) {
        self.list = list
        self.diff = diff
    }
}

/// Keeps open photo lists current as the library changes (LIB-10). The indexer's and change
/// tracking's events, and the changes Redlamp makes itself, are gathered for `latency` and applied to
/// the query engine's column store together, so a burst of thousands of files makes a few changes
/// rather than thousands. Then every open list is made again from the store, off the main thread,
/// and each one that changed hands over its new list with its diff. What it does runs one step at a
/// time, in the order it's asked for.
///
/// A list hands over one update at a time: one the view hasn't taken when the list changes again is
/// replaced by one from the list the view took last, so a busy view is never more than one behind
/// and never applies a diff on the main thread that's longer than the one it needs.
public final class LibraryLive: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// How long changes are gathered before they're applied.
        public var latency: Duration

        public init(latency: Duration = .milliseconds(100)) {
            self.latency = latency
        }
    }

    public let engine: QueryEngine
    public let configuration: Configuration
    private let state = Mutex(State())

    private struct State {
        var lists: [UUID: Open] = [:]
        /// Photos changed since changes were last applied.
        var changed = Set<Int64>()
        /// Folders were indexed since: their names are read again.
        var names = false
        var scheduled = false
        /// The last step asked for, which the next waits for.
        var last: Task<Void, Never>?
    }

    private struct Open {
        let source: PhotoSource
        let sort: QuerySort
        /// The list the view took last.
        var taken: PhotoList?
        /// Counts the updates the view has taken.
        var version = 0
        /// The update the view hasn't taken yet.
        var waiting: PhotoListUpdate?
        /// The photos changed since `taken`, while an update waits.
        var changed = Set<Int64>()
        var waiter: CheckedContinuation<PhotoListUpdate?, Never>?
    }

    public init(engine: QueryEngine, configuration: Configuration = Configuration()) {
        self.engine = engine
        self.configuration = configuration
    }

    // MARK: - Lists

    /// Opens `source`'s list in `sort`'s order: the first update is the list (its diff resets),
    /// each after it the list after a change that touched it. It stays open until `close` is called
    /// on the updates, or the task waiting for the next one is cancelled.
    public func open(_ source: PhotoSource, sort: QuerySort = QuerySort()) -> PhotoListUpdates {
        let id = UUID()
        state.withLock { $0.lists[id] = Open(source: source, sort: sort) }
        enqueue { [self] in await refresh(id, changed: []) }
        return PhotoListUpdates(live: self, id: id)
    }

    /// The list's next update, waiting for one; nil once it's closed.
    func next(for id: UUID) async -> PhotoListUpdate? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PhotoListUpdate?, Never>) in
                let ready = state.withLock { state -> PhotoListUpdate?? in
                    guard var open = state.lists[id] else { return .some(nil) }
                    guard let update = open.waiting else {
                        open.waiter = continuation
                        state.lists[id] = open
                        return nil
                    }
                    open.taken = update.list
                    open.version += 1
                    open.waiting = nil
                    open.changed = []
                    state.lists[id] = open
                    return .some(update)
                }
                if let ready {
                    continuation.resume(returning: ready)
                }
            }
        } onCancel: {
            close(id)
        }
    }

    func close(_ id: UUID) {
        let waiter = state.withLock { $0.lists.removeValue(forKey: id)?.waiter }
        waiter?.resume(returning: nil)
    }

    /// Makes list `id` again from the store, and hands it over if it changed since the list the view
    /// took, `changed` naming the photos changed since the store was last read for it.
    private func refresh(_ id: UUID, changed: Set<Int64>) async {
        guard let (source, sort) = state.withLock({ state in state.lists[id].map { ($0.source, $0.sort) } }),
              let list = try? await engine.list(source, sort: sort)
        else { return }
        while true {
            guard let (taken, version, waitingChanged) = state.withLock({ state in
                state.lists[id].map { ($0.taken, $0.version, $0.changed) }
            }) else { return }
            let changes = waitingChanged.union(changed)
            let diff = taken.map { PhotoListDiff(from: $0, to: list, changed: changes) } ?? PhotoListDiff(reset: true)
            let outcome = state.withLock { state -> (
                handed: Bool,
                waiter: CheckedContinuation<PhotoListUpdate?, Never>?
            ) in
                guard var open = state.lists[id] else { return (true, nil) }
                guard open.version == version else { return (false, nil) }
                defer { state.lists[id] = open }
                guard !diff.isEmpty else {
                    open.waiting = nil
                    open.changed = []
                    return (true, nil)
                }
                let update = PhotoListUpdate(list: list, diff: diff)
                guard let waiter = open.waiter else {
                    open.waiting = update
                    open.changed = changes
                    return (true, nil)
                }
                open.waiter = nil
                open.taken = list
                open.version += 1
                open.waiting = nil
                open.changed = []
                return (true, waiter)
            }
            if let waiter = outcome.waiter {
                waiter.resume(returning: PhotoListUpdate(list: list, diff: diff))
            }
            if outcome.handed {
                return
            }
        }
    }

    // MARK: - Changes

    /// What the indexer reported: photos added, changed and removed, and folders indexed.
    public func receive(_ event: LibraryIndexerEvent) {
        switch event {
        case let .photosInserted(ids), let .photosUpdated(ids), let .photosRemoved(ids):
            photosChanged(ids)
        case .folderIndexed:
            gather { $0.names = true }
        case .volumeOffline, .volumeOnline, .failed, .finished:
            break
        }
    }

    /// What change tracking reported: the indexer's events among it.
    public func receive(_ event: ChangeTracker.Event) {
        if case let .indexer(event) = event {
            receive(event)
        }
    }

    /// Photos whose rows Redlamp changed itself, once the changes are committed: ratings, flags,
    /// labels and marks set from the grid, say.
    public func photosChanged(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        gather { $0.changed.formUnion(ids) }
    }

    /// Applies what's been gathered now, and returns once every open list that changed has its
    /// update waiting or taken.
    public func settle() async {
        await enqueue { [self] in await apply() }.value
    }

    private func gather(_ change: (inout State) -> Void) {
        let schedule = state.withLock { state -> Bool in
            change(&state)
            defer { state.scheduled = true }
            return !state.scheduled
        }
        guard schedule else { return }
        let latency = configuration.latency
        Task { [weak self] in
            try? await Task.sleep(for: latency)
            self?.enqueue { [weak self] in await self?.apply() }
        }
    }

    /// Applies the changes gathered to the store, then refreshes every open list.
    private func apply() async {
        let (changed, names) = state.withLock { state in
            defer {
                state.changed = []
                state.names = false
                state.scheduled = false
            }
            return (state.changed, state.names)
        }
        do {
            if !changed.isEmpty {
                try await engine.update(photos: Array(changed))
            } else if names {
                try await engine.updateNames()
            } else {
                return
            }
        } catch {
            return
        }
        let lists = state.withLock { Array($0.lists.keys) }
        await withTaskGroup(of: Void.self) { group in
            for id in lists {
                group.addTask { await self.refresh(id, changed: changed) }
            }
        }
    }

    @discardableResult
    private func enqueue(_ step: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        state.withLock { state in
            let previous = state.last
            let task = Task {
                await previous?.value
                await step()
            }
            state.last = task
            return task
        }
    }
}

/// The updates of a list `LibraryLive` keeps current (`LibraryLive.open`).
public struct PhotoListUpdates: AsyncSequence, Sendable {
    public typealias Element = PhotoListUpdate

    let live: LibraryLive
    let id: UUID

    public func makeAsyncIterator() -> Iterator {
        Iterator(live: live, id: id)
    }

    /// Stops keeping the list current: the next update is nil.
    public func close() {
        live.close(id)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let live: LibraryLive
        let id: UUID

        public mutating func next() async -> PhotoListUpdate? {
            await live.next(for: id)
        }
    }
}
