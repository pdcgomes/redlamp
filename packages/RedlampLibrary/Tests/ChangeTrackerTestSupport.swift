import Foundation
import Synchronization
@testable import RedlampLibrary

/// A tracker's events, collected as they come, each with when it came.
final class TrackerEvents: Sendable {
    private let state = Mutex<[(event: ChangeTracker.Event, at: ContinuousClock.Instant)]>([])

    init(_ stream: AsyncStream<ChangeTracker.Event>) {
        Task { [self] in
            for await event in stream {
                state.withLock { $0.append((event, .now)) }
            }
        }
    }

    var all: [ChangeTracker.Event] {
        state.withLock { $0.map(\.event) }
    }

    /// When each event `matching` came.
    func times(of matching: (ChangeTracker.Event) -> Bool) -> [ContinuousClock.Instant] {
        state.withLock { $0 }.filter { matching($0.event) }.map(\.at)
    }

    /// Waits until `condition` holds for the events so far; false when it doesn't within `timeout`.
    func wait(timeout: Duration = .seconds(30), until condition: ([ChangeTracker.Event]) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(all) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(all)
    }

    /// Waits for the run that follows the first event `matching`, and returns its summary.
    func summary(
        after matching: @escaping (ChangeTracker.Event) -> Bool, timeout: Duration = .seconds(30),
    ) async -> LibraryIndexerSummary? {
        _ = await wait(timeout: timeout) { $0.summary(after: matching) != nil }
        return all.summary(after: matching)
    }
}

extension [ChangeTracker.Event] {
    /// The summary of the first run to finish after the first event `matching`.
    func summary(after matching: (ChangeTracker.Event) -> Bool) -> LibraryIndexerSummary? {
        guard let start = firstIndex(where: matching) else { return nil }
        for case let .indexer(.finished(summary)) in self[start...] {
            return summary
        }
        return nil
    }

    func count(of matching: (ChangeTracker.Event) -> Bool) -> Int {
        count(where: matching)
    }
}

extension ChangeTracker.Configuration {
    static let testing = Self(latency: .milliseconds(50))
}

/// An event history a test writes: every path on one device whose root is `/`.
final class ScriptedEvents: VolumeEventSource {
    private struct Subscriber {
        let paths: [String]
        let handler: @Sendable ([VolumeEvent]) -> Void
    }

    private struct State {
        var database: String? = "SCRIPTED"
        var history: [VolumeEvent] = []
        var current: UInt64 = 1000
        var subscribers: [Int: Subscriber] = [:]
        var next = 0
        /// The event each subscription asked to start after.
        var since: [UInt64] = []
    }

    private struct Subscription: VolumeEventSubscription {
        let id: Int
        let source: ScriptedEvents

        func cancel() {
            source.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
    }

    private let state = Mutex(State())

    var database: String? {
        get { state.withLock { $0.database } }
        set { state.withLock { $0.database = newValue } }
    }

    var since: [UInt64] {
        state.withLock { $0.since }
    }

    var subscriptions: Int {
        state.withLock { $0.subscribers.count }
    }

    /// `path`, a file system path, as the device's history names it.
    static func onDevice(_ path: String) -> String {
        VolumeEventStream.trimmed(path)
    }

    func locate(_ path: String) -> VolumeLocation? {
        FileManager.default.fileExists(atPath: path) ? VolumeLocation(device: 1, path: Self.onDevice(path)) : nil
    }

    func eventDatabase(of _: Int64) -> String? {
        database
    }

    var currentEvent: UInt64 {
        state.withLock { $0.current }
    }

    func subscribe(
        device _: Int64, paths: [String], since: UInt64, latency _: Duration,
        handler: @escaping @Sendable ([VolumeEvent]) -> Void,
    ) -> (any VolumeEventSubscription)? {
        let (id, replay) = state.withLock { state -> (Int, [VolumeEvent]) in
            state.next += 1
            state.subscribers[state.next] = Subscriber(paths: paths, handler: handler)
            state.since.append(since)
            let replayed = state.history.filter { $0.id > since && Self.covers(paths, $0.path) }
            let done = VolumeEvent(
                path: paths.first ?? "", flags: .historyDone, id: max(since, replayed.map(\.id).max() ?? since),
            )
            return (state.next, replayed + [done])
        }
        DispatchQueue.global().async {
            handler(replay)
        }
        return Subscription(id: id, source: self)
    }

    /// Adds events to the history, numbered after the last, as changes made while no one followed.
    func record(_ events: [(path: String, flags: VolumeEvent.Flags)]) {
        state.withLock { state in
            for event in events {
                state.current += 1
                state.history.append(VolumeEvent(
                    path: Self.onDevice(event.path),
                    flags: event.flags,
                    id: state.current,
                ))
            }
        }
    }

    /// Adds events to the history and delivers them to the subscriptions following their paths.
    func send(_ events: [(path: String, flags: VolumeEvent.Flags)]) {
        let deliveries = state.withLock { state -> [(@Sendable ([VolumeEvent]) -> Void, [VolumeEvent])] in
            var sent: [VolumeEvent] = []
            for event in events {
                state.current += 1
                sent.append(VolumeEvent(path: Self.onDevice(event.path), flags: event.flags, id: state.current))
            }
            state.history += sent
            return state.subscribers.values.map { subscriber in
                (subscriber.handler, sent.filter { Self.covers(subscriber.paths, $0.path) })
            }
        }
        for (handler, events) in deliveries where !events.isEmpty {
            handler(events)
        }
    }

    private static func covers(_ paths: [String], _ path: String) -> Bool {
        paths.contains { $0.isEmpty || path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
    }
}
