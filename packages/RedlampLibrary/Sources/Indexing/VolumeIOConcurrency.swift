import Foundation

/// How many operations a volume's readers keep in flight, from what the volume does with them
/// (docs/plans/2026-10-05-library-design.md, Indexing): additive increase while throughput rises
/// with each reader added, multiplicative decrease when latency climbs without it.
///
/// Operations are measured in windows of at least `minimumOperations` (and twice the width) and
/// `minimumDuration`. A window where operations didn't wait for a place in flight changes nothing:
/// the readers' demand set its pace, not the volume. Once settled, the width is tried one higher,
/// then one lower, every `probeAfter` windows: a reader added stays while throughput keeps rising,
/// a reader taken away stays away while throughput holds, so the readers settle at the fewest that
/// get the most from the volume. Each change of width starts a new generation, and operations
/// started under an older one aren't counted.
struct VolumeConcurrency: Sendable, Hashable {
    /// What one window measured.
    struct Window: Sendable, Hashable {
        var width: Int
        /// Bytes a second, each operation counting at least `minimumBytes`.
        var throughput: Double
        var operationsPerSecond: Double
        /// The mean time from an operation's start to its end.
        var latency: Duration
        /// At least a quarter of the operations waited for a place in flight.
        var saturated: Bool
    }

    private enum Probe: Hashable {
        case none
        /// Trying more readers than `from`, which had `throughput`.
        case up(from: Int, throughput: Double)
        case down(from: Int, throughput: Double)
    }

    static let minimumOperations = 8
    static let minimumDuration = Duration.milliseconds(50)
    static let maximumDuration = Duration.seconds(1)
    /// What a listing or an attribute costs the volume, as a small read would.
    static let minimumBytes = 4096
    /// Settled windows before the width is tried one higher or lower.
    static let probeAfter = 8

    let range: ClosedRange<Int>
    private(set) var width: Int
    private(set) var generation = 0
    private(set) var last: Window?

    private var probe = Probe.none
    private var probes = 0
    private var settled = 0
    /// The settled width's throughput and latency, from its first window.
    private var steady: Window?

    private var started: Duration?
    private var ended = Duration.zero
    private var operations = 0
    private var bytes = 0
    private var latencies = Duration.zero
    private var waited = 0

    init(initial: Int, range: ClosedRange<Int>) {
        self.range = range
        width = min(max(initial, range.lowerBound), range.upperBound)
    }

    /// Bytes a second over the last window; 0 before the first.
    var throughput: Double {
        last?.throughput ?? 0
    }

    /// Counts an operation of `generation` that ran from `start` to `end` and moved `count` bytes,
    /// and closes the window when it's long enough.
    mutating func record(generation: Int, start: Duration, end: Duration, bytes count: Int, waited didWait: Bool) {
        guard generation == self.generation else { return }
        started = min(started ?? start, start)
        ended = max(ended, end)
        operations += 1
        bytes += max(count, Self.minimumBytes)
        latencies += max(end - start, .zero)
        waited += didWait ? 1 : 0
        let elapsed = ended - (started ?? ended)
        let enough = operations >= max(Self.minimumOperations, 2 * width) && elapsed >= Self.minimumDuration
        guard enough || elapsed >= Self.maximumDuration else { return }
        let seconds = max(elapsed.seconds, 1e-6)
        let window = Window(
            width: width, throughput: Double(bytes) / seconds, operationsPerSecond: Double(operations) / seconds,
            latency: latencies / operations, saturated: waited * 4 >= operations,
        )
        last = window
        startWindow()
        adapt(window)
    }

    private mutating func adapt(_ window: Window) {
        guard window.saturated else {
            settled = 0
            return
        }
        switch probe {
        case let .up(from, before):
            if window.throughput > before * 1.05, width < range.upperBound {
                probe = .up(from: width, throughput: window.throughput)
                set(width + 1)
            } else {
                settle(window.throughput > before * 1.05 ? width : from)
            }
        case let .down(from, before):
            if window.throughput >= before * 0.95, width > range.lowerBound {
                probe = .down(from: width, throughput: window.throughput)
                set(width - 1)
            } else {
                settle(window.throughput >= before * 0.95 ? width : from)
            }
        case .none:
            guard let steady else {
                steady = window
                return probeIfDue(window)
            }
            if window.latency.seconds > 2 * steady.latency.seconds, window.throughput <= steady.throughput * 1.05 {
                settle(width / 2)
            } else {
                probeIfDue(window)
            }
        }
    }

    private mutating func probeIfDue(_ window: Window) {
        settled += 1
        guard settled >= (probes == 0 ? 1 : Self.probeAfter), range.count > 1 else { return }
        probes += 1
        let up = width == range.lowerBound || (width < range.upperBound && probes % 2 == 1)
        probe = up ? .up(from: width, throughput: window.throughput) : .down(from: width, throughput: window.throughput)
        set(up ? width + 1 : width - 1)
    }

    private mutating func settle(_ proposed: Int) {
        probe = .none
        steady = nil
        settled = 0
        set(proposed)
    }

    private mutating func set(_ proposed: Int) {
        let clamped = min(max(proposed, range.lowerBound), range.upperBound)
        guard clamped != width else { return }
        width = clamped
        generation += 1
    }

    private mutating func startWindow() {
        started = nil
        ended = .zero
        operations = 0
        bytes = 0
        latencies = .zero
        waited = 0
    }
}
