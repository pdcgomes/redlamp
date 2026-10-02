import Dispatch
import Foundation
import Synchronization

/// Runs bulk work (listings, sidecar probes, thumbnail decodes, warming, stack detection) on all
/// of the machine's cores, by priority, without ever blocking the caller.
///
/// Work waits in one of three lanes, each as wide as the cores that should run it. Jobs run on
/// GCD threads, since they block on I/O, which Swift's cooperative pool must not. A job with a key
/// can be promoted to a busier lane (a thumbnail whose cell scrolled into view) or dropped before
/// it starts (its cell scrolled away). Background work waits while anything on screen does, and
/// pauses in Low Power Mode or when the Mac is hot.
public final class WorkScheduler: Sendable {
    public enum Lane: Int, Sendable, CaseIterable, Comparable {
        /// What the user is waiting for: the visible thumbnails, the open folder's listing.
        case onScreen
        /// What they'll want next: prefetched cells, badges, the folder tree's counts.
        case lookAhead
        /// Warming caches nobody is waiting for, on the efficiency cores.
        case background

        public static func < (lhs: Lane, rhs: Lane) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var qos: DispatchQoS.QoSClass {
            switch self {
            case .onScreen: .userInitiated
            case .lookAhead: .utility
            case .background: .background
            }
        }
    }

    /// How many jobs each lane runs at once.
    public struct Widths: Sendable, Equatable {
        public var onScreen: Int
        public var lookAhead: Int
        public var background: Int

        public init(onScreen: Int, lookAhead: Int, background: Int) {
            self.onScreen = max(onScreen, 1)
            self.lookAhead = max(lookAhead, 1)
            self.background = max(background, 1)
        }

        /// On screen as wide as the performance cores, look-ahead half as wide, background as
        /// wide as the efficiency cores.
        public static var machine: Widths {
            let performance = CoreCounts.performance
            return Widths(
                onScreen: performance,
                lookAhead: max(performance / 2, 2),
                background: max(CoreCounts.efficiency, 2),
            )
        }

        subscript(lane: Lane) -> Int {
            switch lane {
            case .onScreen: onScreen
            case .lookAhead: lookAhead
            case .background: background
            }
        }
    }

    /// A submitted job: cancelling it drops it if it hasn't started.
    public struct Ticket: Sendable {
        fileprivate let id: UInt64
        fileprivate let scheduler: WorkScheduler

        public func cancel() {
            scheduler.cancel(id: id)
        }
    }

    /// The scheduler the app shares, sized to this Mac.
    public static let shared = WorkScheduler()

    public let widths: Widths
    private let canRunBackground: @Sendable () -> Bool
    private let state = Mutex(State())

    public init(widths: Widths = .machine, canRunBackground: @escaping @Sendable () -> Bool = WorkScheduler.isRelaxed) {
        self.widths = widths
        self.canRunBackground = canRunBackground
    }

    /// Whether background work may run: not in Low Power Mode, nor while the Mac is hot.
    public static func isRelaxed() -> Bool {
        let info = ProcessInfo.processInfo
        return !info.isLowPowerModeEnabled && info.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    // MARK: - Submitting

    /// Queues `work`. A key names the job for `promote` and `cancel`; a new job with the key of
    /// one still waiting replaces it.
    @discardableResult
    public func submit(
        _ lane: Lane, key: String? = nil, onCancel: (@Sendable () -> Void)? = nil,
        _ work: @escaping @Sendable () -> Void,
    ) -> Ticket {
        let (id, replaced) = state.withLock { state -> (UInt64, Job?) in
            state.nextID += 1
            let id = state.nextID
            let replaced = key.flatMap { state.byKey[$0] }.flatMap { state.remove($0) }
            state.add(id, Job(lane: lane, key: key, work: work, onCancel: onCancel))
            return (id, replaced)
        }
        replaced?.onCancel?()
        pump()
        return Ticket(id: id, scheduler: self)
    }

    /// Runs `work` in `lane` and returns its result. Cancelling the calling task drops the job if
    /// it hasn't started (throwing `CancellationError`); once started it runs to the end.
    public func run<T: Sendable>(
        _ lane: Lane, key: String? = nil, _ work: @escaping @Sendable () throws -> T,
    ) async throws -> T {
        let ticket = Mutex<Ticket?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                let resumed = Mutex(false)
                let resume: @Sendable (Result<T, any Error>) -> Void = { result in
                    guard resumed.withLock({ done in
                        defer { done = true }
                        return !done
                    }) else { return }
                    continuation.resume(with: result)
                }
                let submitted = submit(
                    lane, key: key,
                    onCancel: { resume(.failure(CancellationError())) },
                    { resume(Result { try work() }) },
                )
                ticket.withLock { $0 = submitted }
                if Task.isCancelled {
                    submitted.cancel()
                }
            }
        } onCancel: {
            ticket.withLock { $0 }?.cancel()
        }
    }

    // MARK: - Changing what waits

    /// Moves the waiting job with `key` to `lane` if that lane runs sooner.
    public func promote(_ key: String, to lane: Lane) {
        let moved = state.withLock { state -> Bool in
            guard let id = state.byKey[key], let job = state.pending[id], lane < job.lane,
                  let removed = state.remove(id) else { return false }
            var promoted = removed
            promoted.lane = lane
            state.add(id, promoted)
            return true
        }
        if moved {
            pump()
        }
    }

    /// Drops the waiting job with `key`.
    public func cancel(_ key: String) {
        let job = state.withLock { state in state.byKey[key].flatMap { state.remove($0) } }
        job?.onCancel?()
    }

    /// Drops every waiting job whose key starts with `prefix` (a folder's or a generation's).
    public func cancel(prefix: String) {
        let jobs = state.withLock { state -> [Job] in
            state.byKey.filter { $0.key.hasPrefix(prefix) }.values.compactMap { state.remove($0) }
        }
        for job in jobs {
            job.onCancel?()
        }
    }

    /// Jobs waiting and running, by lane (for tests and measurements).
    public func load() -> (waiting: [Lane: Int], running: [Lane: Int]) {
        state.withLock { state in
            (
                Dictionary(uniqueKeysWithValues: Lane.allCases.map { ($0, state.waiting[$0.rawValue]) }),
                Dictionary(uniqueKeysWithValues: Lane.allCases.map { ($0, state.running[$0.rawValue]) }),
            )
        }
    }

    private func cancel(id: UInt64) {
        let job = state.withLock { $0.remove(id) }
        job?.onCancel?()
    }

    // MARK: - Running

    private struct Job {
        var lane: Lane
        let key: String?
        let work: @Sendable () -> Void
        let onCancel: (@Sendable () -> Void)?
    }

    private struct State {
        var nextID: UInt64 = 0
        var pending: [UInt64: Job] = [:]
        var byKey: [String: UInt64] = [:]
        /// Ids in submission order, per lane. Ids no longer pending (or pending in another lane)
        /// are skipped when they come up.
        var queues = Lane.allCases.map { _ in Queue() }
        var waiting = Lane.allCases.map { _ in 0 }
        var running = Lane.allCases.map { _ in 0 }
        var backgroundRecheckScheduled = false

        mutating func add(_ id: UInt64, _ job: Job) {
            pending[id] = job
            queues[job.lane.rawValue].append(id)
            waiting[job.lane.rawValue] += 1
            if let key = job.key {
                byKey[key] = id
            }
        }

        /// Takes a waiting job out; its id stays in its lane's queue and is skipped there.
        mutating func remove(_ id: UInt64) -> Job? {
            guard let job = pending.removeValue(forKey: id) else { return nil }
            waiting[job.lane.rawValue] -= 1
            if let key = job.key, byKey[key] == id {
                byKey.removeValue(forKey: key)
            }
            return job
        }

        /// The next job of `lane` that is still waiting there.
        mutating func next(in lane: Lane) -> Job? {
            while let id = queues[lane.rawValue].popFirst() {
                if pending[id]?.lane == lane {
                    return remove(id)
                }
            }
            return nil
        }
    }

    /// Starts as many waiting jobs as the lanes have room for.
    private func pump() {
        let relaxed = canRunBackground()
        var recheck = false
        let starting = state.withLock { state -> [(Lane, Job)] in
            var starting: [(Lane, Job)] = []
            for lane in Lane.allCases {
                if lane == .background {
                    guard relaxed, state.waiting[Lane.onScreen.rawValue] == 0 else {
                        if !relaxed, !state.backgroundRecheckScheduled, state.waiting[lane.rawValue] > 0 {
                            state.backgroundRecheckScheduled = true
                            recheck = true
                        }
                        continue
                    }
                }
                while state.running[lane.rawValue] < widths[lane], let job = state.next(in: lane) {
                    state.running[lane.rawValue] += 1
                    starting.append((lane, job))
                }
            }
            return starting
        }
        for (lane, job) in starting {
            DispatchQueue.global(qos: lane.qos).async { [self] in
                job.work()
                state.withLock { $0.running[lane.rawValue] -= 1 }
                pump()
            }
        }
        if recheck {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.state.withLock { $0.backgroundRecheckScheduled = false }
                self?.pump()
            }
        }
    }
}

/// A first-in, first-out queue of ids that doesn't shift its storage on every pop.
private struct Queue {
    private var items: [UInt64] = []
    private var head = 0

    var isEmpty: Bool {
        head == items.count
    }

    mutating func append(_ id: UInt64) {
        items.append(id)
    }

    mutating func popFirst() -> UInt64? {
        guard head < items.count else { return nil }
        let id = items[head]
        head += 1
        if head > 1024, head * 2 > items.count {
            items.removeFirst(head)
            head = 0
        }
        return id
    }
}

/// The machine's cores, by kind.
public enum CoreCounts {
    /// Performance cores (all cores on a Mac without efficiency cores).
    public static let performance: Int = sysctl("hw.perflevel0.logicalcpu")
        ?? ProcessInfo.processInfo.activeProcessorCount

    /// Efficiency cores, 0 when there are none.
    public static let efficiency: Int = sysctl("hw.perflevel1.logicalcpu") ?? 0

    private static func sysctl(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }
}
