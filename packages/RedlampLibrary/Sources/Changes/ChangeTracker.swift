import Foundation
import Synchronization

/// Keeps the index in step with the disks (LIB-08). Each local volume has one event stream (FSEvents,
/// `FSEventStreamCreateRelativeToDevice`) that replays what changed since the last event the index
/// applied, then follows it, naming the folders the indexer lists again. When that history is gone
/// (none recorded, another event database, events dropped, a root moved), the volume's folders are
/// compared by signature instead, in the indexer's order. Network volumes have no event history: the
/// folders on screen are listed every `shownInterval` and the rest compared on a backoff, neither
/// while the app is in the background. A volume that stops answering has its photos marked offline
/// and is compared again once it's back; nothing waits on it longer than its readers' timeout.
///
/// What the tracker asks of the indexer runs one at a time, in order, and what waits for the same
/// volume is merged. The indexer's events are passed on as `Event.indexer`. A volume's event database
/// and last event are recorded in the index once a run has applied them, and `Event.caughtUp` says
/// when its first pass is over.
public final class ChangeTracker: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// How long a volume's events are gathered before they're passed on.
        public var latency: Duration
        /// How often the folders on screen of a network volume are listed again.
        public var shownInterval: Duration
        /// How long the rest of a network volume waits between comparisons: the first, doubling while
        /// nothing changes, up to the last.
        public var pollIntervals: ClosedRange<Duration>

        public init(
            latency: Duration = .milliseconds(300), shownInterval: Duration = .seconds(15),
            pollIntervals: ClosedRange<Duration> = .seconds(30) ... .seconds(900),
        ) {
            self.latency = latency
            self.shownInterval = shownInterval
            self.pollIntervals = pollIntervals
        }
    }

    public enum Event: Sendable, Hashable {
        case indexer(LibraryIndexerEvent)
        /// A volume's changes since the last event the index applied were replayed from its history,
        /// naming this many folders to list again. Volumes are named as the index names them.
        case replayed(volume: String, folders: Int)
        /// A volume's events named this many folders to list again.
        case changed(volume: String, folders: Int)
        /// A volume's folders are compared by signature, for `reason`.
        case reconciled(volume: String, reason: Reason)
        /// A network volume's folders are listed again: those on screen, or all of them.
        case polled(volume: String, shown: Bool)
        /// The volume's first pass is over, after its run's events: its folders compared or its
        /// history replayed to the end, since the tracker began following it or since it answered
        /// again after it stopped. From here its events or polls keep the index current. Once for
        /// each.
        case caughtUp(volume: String)
    }

    public enum Reason: String, Sendable, Hashable {
        /// The index has no history recorded for the volume, or its event database isn't the one
        /// recorded against.
        case historyGone
        /// Events were dropped, or a root moved.
        case mustScan
        /// A volume without an event history, such as a network volume.
        case network
        /// The volume answers again after it stopped, or was found after it wasn't.
        case reconnected
    }

    public let indexer: LibraryIndexer
    public let configuration: Configuration
    let source: (any VolumeEventSource)?
    let state = Mutex(State())

    public convenience init(indexer: LibraryIndexer, configuration: Configuration = Configuration()) {
        #if os(macOS)
            self.init(indexer: indexer, configuration: configuration, source: FSEventsSource())
        #else
            self.init(indexer: indexer, configuration: configuration, source: nil)
        #endif
    }

    /// With `source` nil, local volumes are polled as network volumes are.
    init(indexer: LibraryIndexer, configuration: Configuration, source: (any VolumeEventSource)?) {
        self.indexer = indexer
        self.configuration = configuration
        self.source = source
    }

    struct State {
        var session: UInt64 = 0
        var stopped = true
        var events: AsyncStream<Event>.Continuation?
        var volumes: [String: Followed] = [:]
        var shown: Set<String> = []
        var active = true
        var pending = PendingWork()
        var waiter: CheckedContinuation<Work?, Never>?
        var tasks: [Task<Void, Never>] = []
    }

    /// Starts following `roots`, adding them to the library if they aren't in it, after stopping what
    /// was followed before: what that left going (volumes still being found, its volumes' events and
    /// polls, its worker) follows no volume and runs no work from then on. The stream ends once `stop`
    /// is called.
    public func start(_ roots: [URL]) -> AsyncStream<Event> {
        stop()
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        let session = state.withLock { state -> UInt64 in
            state.session += 1
            state.stopped = false
            state.events = continuation
            state.pending = PendingWork()
            return state.session
        }
        let worker = Task { [self] in
            while let work = await next(in: session) {
                await perform(work, events: continuation)
            }
            continuation.finish()
        }
        let paths = roots.map(LibraryIndexer.path)
        let following = Task { [self] in
            await follow(paths, in: session)
        }
        let current = state.withLock { state in
            guard state.session == session, !state.stopped else { return false }
            state.tasks += [worker, following]
            return true
        }
        if !current {
            worker.cancel()
            following.cancel()
        }
        continuation.onTermination = { [weak self] _ in self?.stop(session: session) }
        return events
    }

    /// Stops following: the stream ends, polling stops, and the run in progress stops once what it
    /// has read is written.
    public func stop() {
        stop(session: nil)
    }

    private func stop(session: UInt64?) {
        let stopped = state.withLock { state -> State? in
            guard !state.stopped, session == nil || session == state.session else { return nil }
            let stopped = state
            state.stopped = true
            state.events = nil
            state.volumes = [:]
            state.tasks = []
            state.waiter = nil
            state.pending = PendingWork()
            return stopped
        }
        guard let stopped else { return }
        for volume in stopped.volumes.values {
            volume.stop()
        }
        for task in stopped.tasks {
            task.cancel()
        }
        stopped.waiter?.resume(returning: nil)
        for work in stopped.pending.items {
            work.done?(nil)
        }
    }

    /// The folders on screen: indexed first, and on network volumes listed every `shownInterval`.
    public func show(_ folders: [URL]) {
        state.withLock { $0.shown = Set(folders.map(LibraryIndexer.path)) }
        indexer.prioritise(folders)
    }

    /// Lists `folders` again, as an event naming them would: for a change the library made to what they hold that the
    /// disk doesn't show, such as a missing photo relinked to a file there (DEC-59), read again from it.
    public func look(at folders: [URL]) {
        let paths = Set(folders.map(LibraryIndexer.path))
        for volume in state.withLock({ Array($0.volumes.values) }) {
            let below = paths.filter { path in volume.roots.contains { path == $0 || path.hasPrefix($0 + "/") } }
            guard !below.isEmpty else { continue }
            enqueue(Work(volume, .update(Dictionary(uniqueKeysWithValues: below.map { ($0, false) }), replayed: false)))
        }
    }

    /// Whether the app is in the foreground: network volumes are polled only while it is, and their
    /// folders on screen are listed as soon as it's back.
    public func setActive(_ active: Bool) {
        let volumes = state.withLock { state -> [Followed]? in
            guard state.active != active else { return nil }
            state.active = active
            return Array(state.volumes.values)
        }
        for volume in volumes ?? [] where volume.isPolled {
            if active {
                startPolling(volume, immediately: true)
            } else {
                volume.stopPolling()
            }
        }
    }

    var isActive: Bool {
        state.withLock { $0.active }
    }

    func emit(_ event: Event) {
        _ = state.withLock { $0.events }?.yield(event)
    }

    // MARK: - Work

    /// What the tracker asks of the indexer for one volume.
    struct Work: Sendable {
        enum Kind: Sendable {
            case reconcile(Reason)
            /// List these folders again, and their subfolders where true.
            case update([String: Bool], replayed: Bool)
            case poll(shown: Bool)
            case offline
        }

        let volume: Followed
        var kind: Kind
        /// Recorded once the work is done: the history it applies.
        var record: VolumeEventHistory?
        /// Called once, with whether the work changed the index; nil when it didn't run to the end.
        var done: (@Sendable (Bool?) -> Void)?

        init(
            _ volume: Followed, _ kind: Kind, record: VolumeEventHistory? = nil,
            done: (@Sendable (Bool?) -> Void)? = nil,
        ) {
            self.volume = volume
            self.kind = kind
            self.record = record
            self.done = done
        }
    }

    /// Work waiting to run, in order. What's added for a volume is merged into what waits for it:
    /// updates into one update, and updates and polls into a reconcile, which lists every folder.
    struct PendingWork: Sendable {
        private(set) var items: [Work] = []

        /// Adds `work`, or merges it; returns the work merged away, whose `done` is the caller's to call.
        mutating func add(_ work: Work) -> [Work] {
            let key = work.volume.key
            func waiting(_ matches: (Work.Kind) -> Bool) -> Int? {
                items.firstIndex { $0.volume.key == key && matches($0.kind) }
            }
            switch work.kind {
            case let .update(changes, replayed):
                if let index = waiting(\.isReconcile) {
                    items[index].record = Self.later(items[index].record, work.record)
                    return [work]
                }
                if let index = waiting(\.isUpdate), case let .update(earlier, wasReplayed) = items[index].kind {
                    items[index].kind = .update(
                        earlier.merging(changes) { $0 || $1 },
                        replayed: wasReplayed || replayed,
                    )
                    items[index].record = Self.later(items[index].record, work.record)
                    return [work]
                }
            case .reconcile:
                if let index = waiting(\.isReconcile) {
                    items[index].record = Self.later(items[index].record, work.record)
                    return [work]
                }
                var merged = work
                var dropped: [Work] = []
                items.removeAll { item in
                    guard item.volume.key == key, item.kind.isUpdate || item.kind.isPoll else { return false }
                    merged.record = Self.later(item.record, merged.record)
                    dropped.append(item)
                    return true
                }
                items.append(merged)
                return dropped
            case let .poll(shown):
                if waiting({ $0.isReconcile || $0.isFullPoll || ($0.isPoll && shown) }) != nil {
                    return [work]
                }
            case .offline:
                if waiting(\.isOffline) != nil {
                    return [work]
                }
            }
            items.append(work)
            return []
        }

        mutating func next() -> Work? {
            items.isEmpty ? nil : items.removeFirst()
        }

        /// The later of two records: the second when they're of different event databases.
        static func later(_ first: VolumeEventHistory?, _ second: VolumeEventHistory?) -> VolumeEventHistory? {
            guard let first, let second else { return first ?? second }
            return first.eventDatabase == second.eventDatabase && first.lastEvent > second.lastEvent ? first : second
        }
    }

    /// Adds `work` to what waits, unless its volume was followed by a session that has stopped.
    func enqueue(_ work: Work) {
        let (handed, dropped) = state.withLock { state -> ((CheckedContinuation<Work?, Never>, Work)?, [Work]) in
            guard !state.stopped, state.session == work.volume.session else { return (nil, [work]) }
            let dropped = state.pending.add(work)
            guard let waiter = state.waiter, let next = state.pending.next() else { return (nil, dropped) }
            state.waiter = nil
            return ((waiter, next), dropped)
        }
        for work in dropped {
            work.done?(nil)
        }
        if let (waiter, work) = handed {
            waiter.resume(returning: work)
        }
    }

    /// The next work of `session`'s worker; nil once the session has stopped, whether or not another has started.
    private func next(in session: UInt64) async -> Work? {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Work?? in
                if state.stopped || state.session != session {
                    return .some(nil)
                }
                if let work = state.pending.next() {
                    return .some(work)
                }
                state.waiter = continuation
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }

    private func perform(_ work: Work, events: AsyncStream<Event>.Continuation) async {
        let volume = work.volume
        var changed: Bool?
        switch work.kind {
        case let .reconcile(reason):
            events.yield(.reconciled(volume: volume.key, reason: reason))
            changed = await run(indexer.index(volume.urls), for: work, events: events)
        case let .update(changes, replayed):
            if replayed {
                events.yield(.replayed(volume: volume.key, folders: changes.count))
            } else if !changes.isEmpty {
                events.yield(.changed(volume: volume.key, folders: changes.count))
            }
            if changes.isEmpty {
                await record(work)
                changed = false
            } else {
                let folders = changes.sorted { $0.key < $1.key }.map { path, recursive in
                    FolderChange(URL(fileURLWithPath: path, isDirectory: true), recursive: recursive)
                }
                changed = await run(indexer.update(folders), for: work, events: events)
            }
        case let .poll(shown):
            events.yield(.polled(volume: volume.key, shown: shown))
            if shown {
                let folders = shownFolders(on: volume).map { FolderChange(URL(fileURLWithPath: $0, isDirectory: true)) }
                changed = await run(indexer.update(folders), for: work, events: events)
            } else {
                changed = await run(indexer.index(volume.urls), for: work, events: events)
            }
        case .offline:
            volume.fellBehind()
            let key = volume.key
            let marked = try? await indexer.index.write { writer -> Bool in
                guard let record = try writer.volume(uuid: key), try !writer.isMarkedOffline(volume: key) else {
                    return false
                }
                try writer.setOffline(true, onVolume: record.id, uuid: key)
                return true
            }
            if marked == true {
                events.yield(.indexer(.volumeOffline(key)))
            }
        }
        if changed != nil, work.kind.catchesUp, !Task.isCancelled, volume.catchUp() {
            events.yield(.caughtUp(volume: volume.key))
        }
        work.done?(changed)
    }

    /// Passes a run's events on, and records the work's history once the run has applied it; returns
    /// whether it changed the index, nil when it didn't run to the end or the volume went.
    private func run(
        _ stream: AsyncStream<LibraryIndexerEvent>, for work: Work, events: AsyncStream<Event>.Continuation,
    ) async -> Bool? {
        var summary: LibraryIndexerSummary?
        for await event in stream {
            if case let .finished(finished) = event {
                summary = finished
            }
            events.yield(.indexer(event))
        }
        guard let summary, !Task.isCancelled, !summary.offlineVolumes.contains(work.volume.key) else { return nil }
        await record(work)
        return summary.photosInserted + summary.photosUpdated + summary.photosMoved + summary.photosRemoved
            + summary.photosMissing + summary.foldersIndexed + summary.foldersRemoved > 0
    }

    private func record(_ work: Work) async {
        guard let record = work.record, !Task.isCancelled else { return }
        let key = work.volume.key
        _ = try? await indexer.index.write { try $0.setEventHistory(record, ofVolume: key) }
    }

    /// The folders on screen that are on `volume`.
    func shownFolders(on volume: Followed) -> [String] {
        state.withLock { $0.shown }.filter { path in
            volume.roots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }.sorted()
    }
}

extension ChangeTracker.Work.Kind {
    var isReconcile: Bool {
        if case .reconcile = self {
            true
        } else {
            false
        }
    }

    var isUpdate: Bool {
        if case .update = self {
            true
        } else {
            false
        }
    }

    var isPoll: Bool {
        if case .poll = self {
            true
        } else {
            false
        }
    }

    var isFullPoll: Bool {
        if case .poll(shown: false) = self {
            true
        } else {
            false
        }
    }

    var isOffline: Bool {
        if case .offline = self {
            true
        } else {
            false
        }
    }

    /// It takes in everything that changed on the volume, so its run leaves the index current: a
    /// comparison, the history replayed, or a poll of every folder.
    var catchesUp: Bool {
        switch self {
        case .reconcile, .update(_, replayed: true), .poll(shown: false): true
        case .update, .poll, .offline: false
        }
    }
}
