import Foundation
import Synchronization

/// Keeps Recently Trashed current for those following it (`FileOperations.trashedUpdates()`): the
/// list is made again after each batch, when a Trash folder holding its photos changes, as its
/// volume's events say, and when asked (`FileOperations.checkTrash()`), and handed to each follower
/// when it differs from the last. One list is made at a time; asked again meanwhile, it's made once
/// more after it.
final class TrashWatch: Sendable {
    typealias Make = @Sendable () async throws -> [TrashedPhoto]

    private struct State {
        var followers: [UUID: AsyncStream<[TrashedPhoto]>.Continuation] = [:]
        var make: Make?
        /// The list handed over last.
        var list: [TrashedPhoto]?
        var making = false
        var again = false
        /// The Trash folders followed, by path.
        var folders: [String: any VolumeEventSubscription] = [:]
    }

    let source: (any VolumeEventSource)?
    /// How long a Trash folder's events are gathered before the list is made again.
    let latency: Duration
    private let state = Mutex(State())

    init(source: (any VolumeEventSource)?, latency: Duration = .seconds(1)) {
        self.source = source
        self.latency = latency
    }

    /// The list `make` makes, then each one that differs from it, until the stream is let go. A
    /// follower that's slow gets the newest.
    func follow(_ make: @escaping Make) -> AsyncStream<[TrashedPhoto]> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [TrashedPhoto].self, bufferingPolicy: .bufferingNewest(1),
        )
        let id = UUID()
        let last = state.withLock { state in
            state.followers[id] = continuation
            state.make = make
            return state.list
        }
        if let last {
            continuation.yield(last)
        }
        continuation.onTermination = { [weak self] _ in self?.unfollow(id) }
        changed()
        return stream
    }

    /// Makes the list again, if anyone follows it.
    func changed() {
        let make = state.withLock { state -> Make? in
            guard !state.followers.isEmpty, let make = state.make else { return nil }
            guard !state.making else {
                state.again = true
                return nil
            }
            state.making = true
            return make
        }
        guard let make else { return }
        Task { await self.remake(make) }
    }

    private func remake(_ make: Make) async {
        repeat {
            if let list = try? await make() {
                let followers = state.withLock { state -> [AsyncStream<[TrashedPhoto]>.Continuation] in
                    guard list != state.list else { return [] }
                    state.list = list
                    return Array(state.followers.values)
                }
                followers.forEach { $0.yield(list) }
                watch(Set(list.map(\.trash)))
            }
        } while state.withLock({ state in
            defer { state.again = false }
            state.making = state.again
            return state.again
        })
    }

    private func unfollow(_ id: UUID) {
        let cancelled = state.withLock { state -> [any VolumeEventSubscription] in
            state.followers.removeValue(forKey: id)
            guard state.followers.isEmpty else { return [] }
            defer { state.folders = [:] }
            state.list = nil
            return Array(state.folders.values)
        }
        cancelled.forEach { $0.cancel() }
    }

    /// Follows the events of the Trash folders in `folders`, and of no others.
    private func watch(_ folders: Set<String>) {
        guard let source else { return }
        let (adding, dropped) = state.withLock { state -> ([String], [any VolumeEventSubscription]) in
            guard !state.followers.isEmpty else { return ([], []) }
            let dropped = state.folders.filter { !folders.contains($0.key) }
            dropped.keys.forEach { state.folders.removeValue(forKey: $0) }
            return (folders.filter { state.folders[$0] == nil }.sorted(), Array(dropped.values))
        }
        dropped.forEach { $0.cancel() }
        for folder in adding {
            guard let location = source.locate(folder),
                  let subscription = source.subscribe(
                      device: location.device, paths: [location.path], since: source.currentEvent, latency: latency,
                      handler: { [weak self] events in
                          if events.contains(where: { !$0.flags.contains(.historyDone) }) {
                              self?.changed()
                          }
                      },
                  )
            else { continue }
            let unwanted = state.withLock { state -> (any VolumeEventSubscription)? in
                guard !state.followers.isEmpty, state.folders[folder] == nil else { return subscription }
                state.folders[folder] = subscription
                return nil
            }
            unwanted?.cancel()
        }
    }
}
