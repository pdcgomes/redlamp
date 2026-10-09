import Foundation
import Synchronization

extension ChangeTracker {
    // MARK: - Following volumes

    /// Finds the volumes of `roots` and follows each, while `session` lasts. Roots whose volumes can't be
    /// found have their photos marked offline, and are looked for again with backoff.
    func follow(_ roots: [String], in session: UInt64) async {
        var found: [String: (io: VolumeIO, roots: [String])] = [:]
        var missing: [String] = []
        for root in roots {
            let url = URL(fileURLWithPath: root, isDirectory: true)
            guard let info = try? await indexer.volumes.volume(of: url) else {
                missing.append(root)
                continue
            }
            let key = VolumeIORegistry.key(for: info, probe: url)
            let io = found[key]?.io ?? indexer.volumes.io(for: info, probe: url)
            found[key, default: (io, [])].roots.append(root)
        }
        if !missing.isEmpty {
            await markOffline(missing, except: Set(found.keys))
            look(for: missing, in: session)
        }
        for (key, entry) in found.sorted(by: { $0.key < $1.key }) {
            await follow(Followed(key: key, io: entry.io, roots: entry.roots, session: session), after: nil)
        }
    }

    /// Follows `volume` through its event history, or by polling, unless its session has stopped; `reason`
    /// is why it's followed again.
    private func follow(_ volume: Followed, after reason: Reason?) async {
        let replaced = state.withLock { state -> Followed?? in
            guard !state.stopped, state.session == volume.session else { return nil }
            defer { state.volumes[volume.key] = volume }
            return .some(state.volumes[volume.key])
        }
        guard let replaced else { return }
        replaced?.stop()
        observeReachability(volume)
        if volume.isLocal, let source {
            await stream(volume, from: source, after: reason)
        } else {
            volume.setPolled()
            enqueue(Work(volume, .reconcile(reason ?? .network)))
            startPolling(volume, immediately: false)
        }
    }

    /// Opens the volume's event stream: from the last event the index applied when its history is
    /// still there, else from now, comparing its folders by signature first.
    private func stream(_ volume: Followed, from source: any VolumeEventSource, after reason: Reason?) async {
        let located = volume.roots.compactMap { root in source.locate(root).map { (root: root, location: $0) } }
        guard let device = located.first?.location.device else {
            return enqueue(Work(volume, .reconcile(reason ?? .historyGone)))
        }
        let roots = located.filter { $0.location.device == device }.map { (root: $0.root, onDevice: $0.location.path) }
        let database = source.eventDatabase(of: device)
        let now = source.currentEvent
        let key = volume.key
        let recorded = try? await indexer.index.read { try $0.eventHistory(ofVolume: key) }
        var replay: Followed.Replay?
        if reason == nil, let database, let recorded, recorded.eventDatabase == database, recorded.lastEvent <= now {
            // Folders a run didn't finish are listed again with what the history names.
            let paths = volume.roots
            let unfinished = await (try? indexer.index.read { try $0.foldersToIndex() }) ?? []
            let changes = unfinished.map(\.path).filter { path in
                paths.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
            replay = Followed.Replay(
                since: recorded.lastEvent, changes: Dictionary(changes.map { ($0, false) }) { first, _ in first },
                last: now,
            )
        }
        let generation = volume.started(roots: roots, eventDatabase: database, replay: replay)
        // Before the stream starts, so its events queue behind the comparison.
        if replay == nil {
            enqueue(Work(
                volume, .reconcile(reason ?? .historyGone),
                record: database.map { VolumeEventHistory(eventDatabase: $0, lastEvent: now) },
            ))
        }
        let subscription = source.subscribe(
            device: device, paths: roots.map(\.onDevice), since: replay?.since ?? now, latency: configuration.latency,
        ) { [weak self] events in
            self?.received(events, on: volume, generation: generation)
        }
        guard let subscription else {
            volume.stopFollowing()
            volume.setPolled()
            enqueue(Work(volume, .reconcile(reason ?? .network)))
            return startPolling(volume, immediately: false)
        }
        volume.set(subscription, generation: generation)
    }

    /// A batch of the volume's events: held while its history replays, then passed on as the
    /// folders to list again.
    private func received(_ events: [VolumeEvent], on volume: Followed, generation: Int) {
        let batch = Self.batch(events, roots: volume.roots(generation: generation))
        if let work = volume.collect(batch, generation: generation) {
            enqueue(work)
        }
    }

    /// The folders `events` name below `roots` (each with its path from the device's root), and
    /// whether they say the volume must be compared again.
    static func batch(_ events: [VolumeEvent], roots: [(root: String, onDevice: String)]) -> Followed.Batch {
        var batch = Followed.Batch()
        for event in events {
            batch.last = max(batch.last, event.id)
            if event.flags.contains(.historyDone) {
                batch.historyDone = true
                continue
            }
            if !event.flags.isDisjoint(with: VolumeEvent.Flags.lost) {
                batch.lost = true
                continue
            }
            let recursive = event.flags.contains(.mustScanSubfolders)
            for (root, onDevice) in roots {
                if let below = relative(event.path, to: onDevice) {
                    if recursive, below.isEmpty {
                        batch.lost = true
                    } else {
                        let path = below.isEmpty ? root : root + "/" + below
                        batch.changes[path] = batch.changes[path] == true || recursive
                    }
                } else if recursive, relative(onDevice, to: event.path) != nil {
                    batch.lost = true
                }
            }
        }
        return batch
    }

    /// `path` below `base`, both from the same root: empty when they're the same; nil when `path`
    /// isn't at or below `base`.
    static func relative(_ path: String, to base: String) -> String? {
        if base.isEmpty || path == base {
            return base.isEmpty ? path : ""
        }
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : nil
    }

    // MARK: - Reachability

    private func observeReachability(_ volume: Followed) {
        let changes = volume.io.reachabilityChanges()
        let task = Task { [weak self] in
            for await reachable in changes {
                guard let self else { return }
                if reachable {
                    await reconnected(volume)
                } else {
                    volume.stopFollowing()
                    enqueue(Work(volume, .offline))
                }
            }
        }
        volume.add(task)
    }

    private func reconnected(_ volume: Followed) async {
        if volume.isLocal, !volume.isPolled, let source {
            await stream(volume, from: source, after: .reconnected)
        } else {
            enqueue(Work(volume, .reconcile(.reconnected)))
            startPolling(volume, immediately: false)
        }
    }

    // MARK: - Roots that can't be found

    /// Marks offline the photos of the volumes the index has for `roots`, but those in `found`.
    private func markOffline(_ roots: [String], except found: Set<String>) async {
        let marked = try? await indexer.index.write { writer -> [String] in
            var marked: [String] = []
            for path in roots {
                guard let root = try writer.root(path: path),
                      let volume = try writer.volumes().first(where: { $0.id == root.volume }),
                      !found.contains(volume.uuid), try !writer.isMarkedOffline(volume: volume.uuid)
                else { continue }
                try writer.setOffline(true, onVolume: volume.id, uuid: volume.uuid)
                marked.append(volume.uuid)
            }
            return marked
        }
        for key in marked ?? [] {
            emit(.indexer(.volumeOffline(key)))
        }
    }

    /// Looks for the volumes of `roots` again, with the readers' probe backoff, and follows those
    /// found, while `session` lasts.
    private func look(for roots: [String], in session: UInt64) {
        let intervals = indexer.volumes.configuration.probeIntervals
        let task = Task { [weak self] in
            var waiting = roots
            var delay = intervals.lowerBound
            while !waiting.isEmpty, !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                var found: [String: (io: VolumeIO, roots: [String])] = [:]
                var missing: [String] = []
                for root in waiting {
                    let url = URL(fileURLWithPath: root, isDirectory: true)
                    guard let info = try? await indexer.volumes.volume(of: url) else {
                        missing.append(root)
                        continue
                    }
                    let key = VolumeIORegistry.key(for: info, probe: url)
                    let io = found[key]?.io ?? indexer.volumes.io(for: info, probe: url)
                    found[key, default: (io, [])].roots.append(root)
                }
                for (key, entry) in found.sorted(by: { $0.key < $1.key }) {
                    let roots = (state.withLock { $0.volumes[key]?.roots } ?? []) + entry.roots
                    await follow(Followed(key: key, io: entry.io, roots: roots, session: session), after: .reconnected)
                }
                waiting = missing
                delay = min(delay * 2, intervals.upperBound)
            }
        }
        let current = state.withLock { state in
            guard !state.stopped, state.session == session else { return false }
            state.tasks.append(task)
            return true
        }
        if !current {
            task.cancel()
        }
    }

    // MARK: - Polling

    /// Polls `volume` while the app is active and the volume answers: its folders on screen every
    /// `shownInterval`, at once when `immediately`, and every folder on a backoff.
    func startPolling(_ volume: Followed, immediately: Bool) {
        guard isActive, volume.io.isReachable else { return }
        let shownInterval = configuration.shownInterval
        let intervals = configuration.pollIntervals
        let task = Task { [weak self] in
            let clock = ContinuousClock()
            var nextShown = clock.now + (immediately ? .zero : shownInterval)
            var nextFull = clock.now + volume.pollInterval(intervals)
            while !Task.isCancelled {
                try? await clock.sleep(until: min(nextShown, nextFull))
                guard let self, !Task.isCancelled else { return }
                if clock.now >= nextFull {
                    let changed = await poll(volume, shown: false)
                    volume.polled(changed: changed, intervals: intervals)
                    nextFull = clock.now + volume.pollInterval(intervals)
                    nextShown = clock.now + shownInterval
                } else {
                    if !shownFolders(on: volume).isEmpty, await poll(volume, shown: true) == true {
                        volume.polled(changed: true, intervals: intervals)
                    }
                    nextShown = clock.now + shownInterval
                }
            }
        }
        volume.setPolling(task)
    }

    /// Polls `volume` once the work before it is done; returns whether the poll changed the index.
    private func poll(_ volume: Followed, shown: Bool) async -> Bool? {
        await withCheckedContinuation { continuation in
            enqueue(Work(volume, .poll(shown: shown)) { changed in continuation.resume(returning: changed) })
        }
    }
}

extension ChangeTracker {
    /// A volume the tracker follows, and what it keeps for it.
    final class Followed: Sendable {
        /// What a batch of events names.
        struct Batch: Sendable {
            /// Folders to list again, and whether their subfolders are too.
            var changes: [String: Bool] = [:]
            var last: UInt64 = 0
            /// The volume must be compared folder by folder.
            var lost = false
            var historyDone = false
        }

        /// What the history replayed so far names, held until it's all replayed.
        struct Replay: Sendable {
            let since: UInt64
            var changes: [String: Bool]
            var last: UInt64
            var lost = false
        }

        private struct State {
            /// Each start of the volume's event stream; events of an earlier one are dropped.
            var generation = 0
            var subscription: (any VolumeEventSubscription)?
            var eventDatabase: String?
            var roots: [(root: String, onDevice: String)] = []
            var replay: Replay?
            var polled = false
            var polling: Task<Void, Never>?
            var pollInterval: Duration?
            var tasks: [Task<Void, Never>] = []
            var caughtUp = false
        }

        /// The index's name for the volume.
        let key: String
        let io: VolumeIO
        let roots: [String]
        /// The tracker's session that follows it (`ChangeTracker.start`): its work is dropped once another
        /// starts.
        let session: UInt64
        private let state = Mutex(State())

        init(key: String, io: VolumeIO, roots: [String], session: UInt64) {
            self.key = key
            self.io = io
            self.roots = roots
            self.session = session
        }

        var urls: [URL] {
            roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }

        var isLocal: Bool {
            io.volume.isLocal
        }

        /// Followed by polling, not through an event history.
        var isPolled: Bool {
            state.withLock { $0.polled }
        }

        func setPolled() {
            state.withLock { $0.polled = true }
        }

        /// A new start of the event stream, from `replay.since` when the history is replayed; returns
        /// its generation.
        func started(roots: [(root: String, onDevice: String)], eventDatabase: String?, replay: Replay?) -> Int {
            let (generation, old) = state.withLock { state in
                state.generation += 1
                state.roots = roots
                state.eventDatabase = eventDatabase
                state.replay = replay
                defer { state.subscription = nil }
                return (state.generation, state.subscription)
            }
            old?.cancel()
            return generation
        }

        func set(_ subscription: any VolumeEventSubscription, generation: Int) {
            let current = state.withLock { state in
                guard state.generation == generation else { return false }
                state.subscription = subscription
                return true
            }
            if !current {
                subscription.cancel()
            }
        }

        /// The roots the stream of `generation` follows, with their paths from the device's root.
        func roots(generation: Int) -> [(root: String, onDevice: String)] {
            state.withLock { $0.generation == generation ? $0.roots : [] }
        }

        /// Adds a batch of the stream's events: held while the history replays and passed on, all
        /// together, once it's done; passed on at once after that. Nil when there's nothing to pass
        /// on, or the batch is from an earlier stream.
        func collect(_ batch: Batch, generation: Int) -> Work? {
            state.withLock { state in
                guard state.generation == generation else { return nil }
                let database = state.eventDatabase
                let record = { (last: UInt64) in
                    database.map { VolumeEventHistory(eventDatabase: $0, lastEvent: last) }
                }
                if var replay = state.replay {
                    replay.changes.merge(batch.changes) { $0 || $1 }
                    replay.last = max(replay.last, batch.last)
                    replay.lost = replay.lost || batch.lost
                    guard batch.historyDone else {
                        state.replay = replay
                        return nil
                    }
                    state.replay = nil
                    return replay.lost ? Work(self, .reconcile(.mustScan), record: record(replay.last))
                        : Work(self, .update(replay.changes, replayed: true), record: record(replay.last))
                }
                if batch.lost {
                    return Work(self, .reconcile(.mustScan), record: record(batch.last))
                }
                guard !batch.changes.isEmpty || batch.last > 0 else { return nil }
                return Work(self, .update(batch.changes, replayed: false), record: record(batch.last))
            }
        }

        func setPolling(_ task: Task<Void, Never>?) {
            let old = state.withLock { state in
                defer { state.polling = task }
                return state.polling
            }
            old?.cancel()
        }

        func stopPolling() {
            setPolling(nil)
        }

        /// How long the rest of the volume waits before it's compared again.
        func pollInterval(_ intervals: ClosedRange<Duration>) -> Duration {
            state.withLock { $0.pollInterval ?? intervals.lowerBound }
        }

        /// A comparison is over: the next waits twice as long while nothing changes.
        func polled(changed: Bool?, intervals: ClosedRange<Duration>) {
            state.withLock { state in
                let current = state.pollInterval ?? intervals.lowerBound
                switch changed {
                case true?: state.pollInterval = intervals.lowerBound
                case false?: state.pollInterval = min(current * 2, intervals.upperBound)
                case nil: break
                }
            }
        }

        func add(_ task: Task<Void, Never>) {
            state.withLock { $0.tasks.append(task) }
        }

        /// A pass that takes in everything that changed on the volume has run to the end; returns
        /// whether it's the first since the volume was followed or fell behind.
        func catchUp() -> Bool {
            state.withLock { state in
                defer { state.caughtUp = true }
                return !state.caughtUp
            }
        }

        /// The volume stopped answering: what changed meanwhile waits for its next pass.
        func fellBehind() {
            state.withLock { $0.caughtUp = false }
        }

        /// Stops the event stream and polling, until the volume is followed again.
        func stopFollowing() {
            let subscription = state.withLock { state in
                state.generation += 1
                state.replay = nil
                defer { state.subscription = nil }
                return state.subscription
            }
            subscription?.cancel()
            stopPolling()
        }

        func stop() {
            stopFollowing()
            for task in state.withLock({ $0.tasks }) {
                task.cancel()
            }
        }
    }
}
