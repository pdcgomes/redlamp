import Dispatch
import Foundation
import RedlampDocument
import Synchronization

/// The readers of one volume. Every file operation the library makes on the volume goes through
/// them: as many at once as the volume serves best (`VolumeConcurrency`), the listings and the
/// photos on screen first, and none waiting on the volume longer than `timeout` from when it's
/// sent. A volume that fails as gone, or doesn't answer in time, is unreachable: what waits and
/// what's asked next fails at once, while a probe asks every so often whether it's back. Waiting for
/// a place in flight doesn't count towards the timeout: a volume that answers slowly is only slow.
///
/// Operations run on GCD's threads, since they block on the volume, which Swift's cooperative pool
/// must not. A caller that stops waiting (its timeout passed) leaves the thread to finish alone.
public final class VolumeIO: Sendable {
    public enum Priority: Int, Sendable, Hashable, CaseIterable, Comparable {
        /// Listings and the photos of folders on screen.
        case high
        case normal

        public static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public struct Statistics: Sendable, Hashable {
        public var width: Int
        /// Bytes a second over the last window measured; 0 before the first.
        public var throughput: Double
        public var operationsPerSecond: Double
        public var operations: Int
        public var bytes: Int
        /// The longest any caller waited for an answer, queueing included.
        public var longestWait: Duration
        /// The longest an operation was in flight before it was answered or given up on.
        public var longestOperation: Duration
        public var timeouts: Int
        public var isReachable: Bool
    }

    public let volume: VolumeInfo
    public let fileSystem: any LibraryFileSystem
    /// What the probe asks about while the volume is unreachable: one of its roots.
    public let probe: URL
    public let timeout: Duration
    private let probeIntervals: ClosedRange<Duration>
    private let clock: any SimulationClock
    private let state: Mutex<State>
    private let watchdog = DispatchQueue(label: "app.redlamp.library.volume-io", qos: .utility)

    /// Readers for `volume` with the width its kind starts at: a network volume's 4, an internal
    /// disk's performance cores, an external disk's 2; adapting within 1 to the performance cores.
    public init(
        volume: VolumeInfo, fileSystem: any LibraryFileSystem, probe: URL, timeout: Duration = .seconds(10),
        probeIntervals: ClosedRange<Duration> = .seconds(1) ... .seconds(30),
        clock: any SimulationClock = SystemClock(),
        maximumWidth: Int = CoreCounts.performance,
    ) {
        self.volume = volume
        self.fileSystem = fileSystem
        self.probe = probe
        self.timeout = timeout
        self.probeIntervals = probeIntervals
        self.clock = clock
        let maximum = max(maximumWidth, 1)
        state = Mutex(State(
            concurrency: VolumeConcurrency(initial: Self.initialWidth(for: volume), range: 1 ... maximum),
            probeDelay: probeIntervals.lowerBound,
        ))
    }

    /// The width a volume's readers start at, by what it is.
    public static func initialWidth(for volume: VolumeInfo) -> Int {
        guard volume.isLocal else { return 4 }
        return volume.isInternal ? CoreCounts.performance : 2
    }

    /// Operations the volume is asked to serve at once.
    public var width: Int {
        state.withLock { $0.concurrency.width }
    }

    /// Bytes a second over the last window measured.
    public var throughput: Double {
        state.withLock { $0.concurrency.throughput }
    }

    public var isReachable: Bool {
        state.withLock { $0.reachable }
    }

    public var statistics: Statistics {
        state.withLock { state in
            Statistics(
                width: state.concurrency.width, throughput: state.concurrency.throughput,
                operationsPerSecond: state.concurrency.last?.operationsPerSecond ?? 0, operations: state.operations,
                bytes: state.bytes, longestWait: state.longestWait, longestOperation: state.longestOperation,
                timeouts: state.timeouts, isReachable: state.reachable,
            )
        }
    }

    // MARK: - Operations

    public func contentsOfDirectory(at url: URL, priority: Priority = .high) async throws -> [FileEntry] {
        try await perform(url, priority: priority, bytes: { $0.count * SimulatedFileSystem.entryBytes }) {
            try $0.contentsOfDirectory(at: url)
        }
    }

    public func attributes(of url: URL, priority: Priority = .normal) async throws -> FileEntry {
        try await perform(url, priority: priority, bytes: { _ in SimulatedFileSystem.entryBytes }) {
            try $0.attributes(of: url)
        }
    }

    public func read(_ url: URL, range: Range<Int>, priority: Priority = .normal) async throws -> Data {
        try await perform(url, priority: priority, bytes: \.count) { try $0.read(url, range: range) }
    }

    /// Runs `operation` on the volume's file system as one of its operations, about `url`. It holds
    /// a place in flight until it returns; with `measured` false the width isn't adapted by it, for
    /// work that isn't only the volume's.
    public func perform<T: Sendable>(
        _ url: URL, priority: Priority = .normal, measured: Bool = true,
        bytes: @escaping @Sendable (T) -> Int = { _ in 0 },
        _ operation: @escaping @Sendable (any LibraryFileSystem) throws -> T,
    ) async throws -> T {
        let call = Call<T>(submitted: clock.now)
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                call.set(continuation)
                guard !Task.isCancelled else {
                    finish(call, with: .failure(CancellationError()))
                    return
                }
                let fileSystem = fileSystem
                let clock = clock
                let job = Job(
                    priority: priority,
                    run: { [self] generation, waited in
                        let start = clock.now
                        let result = Result { try operation(fileSystem) }
                        let end = clock.now
                        var failure: (any Error)?
                        if case let .failure(error) = result {
                            failure = error
                        }
                        completed(
                            id, generation: generation, start: start, end: end,
                            bytes: (try? result.get()).map(bytes) ?? 0, waited: waited, measured: measured,
                            failure: failure,
                        )
                        finish(call, with: result)
                    },
                    fail: { [self] error in finish(call, with: .failure(error)) },
                    url: url,
                )
                submit(id, job)
            }
        } onCancel: {
            cancel(id)
        }
    }

    // MARK: - Reachability

    /// Each change of reachability, from now on: false when the volume goes, true when it's back.
    public func reachabilityChanges() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        let key = state.withLock { state -> UInt64 in
            state.nextID += 1
            state.observers[state.nextID] = continuation
            return state.nextID
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: key) }
        }
        return stream
    }

    /// Returns once the volume is reachable, at once if it is.
    public func waitUntilReachable() async {
        let changes = reachabilityChanges()
        guard !isReachable else { return }
        for await reachable in changes where reachable {
            return
        }
    }

    /// Treats the volume as gone, as when its root can no longer be found: fails what waits, and
    /// probes until it's back.
    public func markUnreachable() {
        let failed = state.withLock { state -> [Job] in
            guard state.reachable else { return [] }
            state.reachable = false
            return state.takeQueued()
        }
        for job in failed {
            job.fail(LibraryFileSystemError.unreachable(job.url))
        }
        notify()
        scheduleProbe()
    }

    // MARK: - Running

    private struct Job: Sendable {
        let priority: Priority
        let run: @Sendable (_ generation: Int, _ waited: Bool) -> Void
        let fail: @Sendable (any Error) -> Void
        let url: URL
    }

    private struct Tracked {
        var job: Job
        var waited: Bool
        /// When it was sent to the volume, by the clock and by its deadline's; nil while it waits.
        var started: Duration?
        var deadline: DispatchTime?
        var expired = false
    }

    private struct State {
        var concurrency: VolumeConcurrency
        var probeDelay: Duration
        var nextID: UInt64 = 0
        var tracked: [UInt64: Tracked] = [:]
        var queues: [[UInt64]] = Priority.allCases.map { _ in [] }
        var heads: [Int] = Priority.allCases.map { _ in 0 }
        var running = 0
        /// Operations whose callers gave up on them, still blocking their threads.
        var stuck = 0
        var reachable = true
        var probing = false
        var watching = false
        var observers: [UInt64: AsyncStream<Bool>.Continuation] = [:]
        var operations = 0
        var bytes = 0
        var longestWait = Duration.zero
        var longestOperation = Duration.zero
        var timeouts = 0

        mutating func next() -> (UInt64, Tracked)? {
            for priority in Priority.allCases {
                let lane = priority.rawValue
                while heads[lane] < queues[lane].count {
                    let id = queues[lane][heads[lane]]
                    heads[lane] += 1
                    if heads[lane] > 1024, heads[lane] * 2 > queues[lane].count {
                        queues[lane].removeFirst(heads[lane])
                        heads[lane] = 0
                    }
                    if let tracked = tracked[id], tracked.started == nil {
                        return (id, tracked)
                    }
                }
            }
            return nil
        }

        /// The jobs that haven't started, taken out.
        mutating func takeQueued() -> [Job] {
            let queued = tracked.filter { $0.value.started == nil }
            for id in queued.keys {
                tracked.removeValue(forKey: id)
            }
            queues = Priority.allCases.map { _ in [] }
            heads = Priority.allCases.map { _ in 0 }
            return queued.values.map(\.job)
        }
    }

    private func submit(_ id: UInt64, _ job: Job) {
        let refused = state.withLock { state -> Bool in
            guard state.reachable else { return true }
            let waited = state.running >= state.concurrency.width
            state.tracked[id] = Tracked(job: job, waited: waited)
            state.queues[job.priority.rawValue].append(id)
            return false
        }
        if refused {
            job.fail(LibraryFileSystemError.unreachable(job.url))
            return
        }
        pump()
        watch()
    }

    private func pump() {
        let now = clock.now
        let deadline = DispatchTime.now() + timeout.seconds
        let starting = state.withLock { state -> [(Job, Int, Bool)] in
            var starting: [(Job, Int, Bool)] = []
            while state.running < state.concurrency.width, let (id, tracked) = state.next() {
                state.tracked[id]?.started = now
                state.tracked[id]?.deadline = deadline
                state.running += 1
                starting.append((tracked.job, state.concurrency.generation, tracked.waited))
            }
            return starting
        }
        for (job, generation, waited) in starting {
            DispatchQueue.global(qos: job.priority == .high ? .userInitiated : .utility).async {
                job.run(generation, waited)
            }
        }
    }

    private func completed(
        _ id: UInt64, generation: Int, start: Duration, end: Duration, bytes: Int, waited: Bool, measured: Bool,
        failure: (any Error)?,
    ) {
        let gone = failure.map(Self.isVolumeFailure) ?? false
        state.withLock { state in
            guard let tracked = state.tracked.removeValue(forKey: id) else { return }
            if tracked.expired {
                state.stuck -= 1
                return
            }
            state.running -= 1
            state.operations += 1
            state.bytes += bytes
            state.longestOperation = max(state.longestOperation, end - (tracked.started ?? start))
            if measured, failure == nil {
                state.concurrency.record(generation: generation, start: start, end: end, bytes: bytes, waited: waited)
            }
        }
        if gone {
            markUnreachable()
        }
        pump()
    }

    private func cancel(_ id: UInt64) {
        let job = state.withLock { state -> Job? in
            guard let tracked = state.tracked[id], tracked.started == nil else { return nil }
            state.tracked.removeValue(forKey: id)
            return tracked.job
        }
        job?.fail(CancellationError())
    }

    private func finish<T>(_ call: Call<T>, with result: Result<T, any Error>) {
        guard call.resume(with: result) else { return }
        let waited = clock.now - call.submitted
        state.withLock { $0.longestWait = max($0.longestWait, waited) }
    }

    /// Checks the deadlines of the operations in flight, as long as any wait or run.
    private func watch() {
        let start = state.withLock { state -> Bool in
            guard !state.watching else { return false }
            state.watching = true
            return true
        }
        if start {
            scheduleCheck()
        }
    }

    private var checkInterval: Duration {
        min(max(timeout / 20, .milliseconds(5)), .milliseconds(100))
    }

    private func scheduleCheck() {
        let interval = checkInterval
        watchdog.asyncAfter(deadline: .now() + interval.seconds) { [weak self] in
            self?.checkDeadlines()
        }
    }

    private func checkDeadlines() {
        let now = DispatchTime.now()
        let clockNow = clock.now
        let (expired, again) = state.withLock { state -> ([Job], Bool) in
            var expired: [Job] = []
            for (id, tracked) in state.tracked {
                guard !tracked.expired, let deadline = tracked.deadline, deadline <= now else { continue }
                expired.append(tracked.job)
                state.tracked[id]?.expired = true
                state.running -= 1
                state.stuck += 1
                state.timeouts += 1
                state.longestOperation = max(state.longestOperation, clockNow - (tracked.started ?? clockNow))
            }
            let again = state.tracked.contains { !$0.value.expired }
            state.watching = again
            return (expired, again)
        }
        for job in expired {
            job.fail(LibraryFileSystemError.timedOut(job.url))
        }
        if !expired.isEmpty {
            markUnreachable()
            pump()
        }
        if again {
            scheduleCheck()
        }
    }

    private func notify() {
        let (reachable, observers) = state.withLock { ($0.reachable, Array($0.observers.values)) }
        for observer in observers {
            observer.yield(reachable)
        }
    }

    private func scheduleProbe() {
        let delay = state.withLock { state -> Duration? in
            guard !state.reachable, !state.probing else { return nil }
            state.probing = true
            let delay = state.probeDelay
            state.probeDelay = min(state.probeDelay * 2, probeIntervals.upperBound)
            return delay
        }
        guard let delay else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay.seconds) { [weak self] in
            self?.runProbe()
        }
    }

    private func runProbe() {
        let answered = DispatchSemaphore(value: 0)
        let found = Mutex(false)
        let fileSystem = fileSystem
        let probe = probe
        DispatchQueue.global(qos: .utility).async {
            let reached = (try? fileSystem.attributes(of: probe)) != nil
            found.withLock { $0 = reached }
            answered.signal()
        }
        let back = answered.wait(timeout: .now() + timeout.seconds) == .success && found.withLock { $0 }
        let changed = state.withLock { state -> Bool in
            state.probing = false
            guard back, !state.reachable else { return false }
            state.reachable = true
            state.probeDelay = probeIntervals.lowerBound
            return true
        }
        if changed {
            notify()
        } else if !back {
            scheduleProbe()
        }
    }

    // MARK: - Errors

    /// Whether `error` says the volume is gone, rather than one file: the volume's own errors, and
    /// the network's.
    static func isVolumeFailure(_ error: any Error) -> Bool {
        if error is LibraryFileSystemError {
            return true
        }
        let codes: Set<Int> = [
            Int(ETIMEDOUT), Int(ENOTCONN), Int(EHOSTDOWN), Int(EHOSTUNREACH), Int(ENETDOWN), Int(ENETUNREACH),
            Int(ENXIO), Int(ENODEV), Int(ESTALE),
        ]
        return posixCode(of: error).map(codes.contains) ?? false
    }

    /// Whether `error` says a file or folder isn't there.
    static func isNotFound(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError {
            return true
        }
        return posixCode(of: error).map { $0 == Int(ENOENT) || $0 == Int(ENOTDIR) } ?? false
    }

    private static func posixCode(of error: any Error) -> Int? {
        if let error = error as? POSIXError {
            return Int(error.code.rawValue)
        }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            return error.code
        }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap(posixCode)
    }
}

/// One caller's wait: resumed once, by the operation's end, its timeout or its cancellation,
/// whichever comes first.
private final class Call<T: Sendable>: Sendable {
    let submitted: Duration
    private let continuation = Mutex<CheckedContinuation<T, any Error>?>(nil)

    init(submitted: Duration) {
        self.submitted = submitted
    }

    func set(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation.withLock { $0 = continuation }
    }

    /// Whether this was the first: later ones are dropped.
    func resume(with result: Result<T, any Error>) -> Bool {
        guard let continuation = continuation.withLock({ $0.take() }) else { return false }
        continuation.resume(with: result)
        return true
    }
}
