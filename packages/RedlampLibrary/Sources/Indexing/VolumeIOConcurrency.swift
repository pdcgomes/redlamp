import Foundation

/// How many operations a volume's readers keep in flight, from what the volume does with them
/// (docs/plans/2026-10-05-library-design.md, Indexing): one more while that raises throughput, one
/// fewer while that doesn't lower it.
///
/// Operations are measured in windows of at least `minimumOperations` (and twice the width) and
/// `minimumDuration`. A window where operations didn't wait for a place in flight changes nothing:
/// the readers' demand set its pace, not the volume. Once settled, the width is tried one higher,
/// then one lower, every `probeAfter` windows: a reader added stays while throughput keeps rising,
/// a reader taken away stays away while throughput holds, so the readers settle at the fewest that
/// get the most from the volume. Each change of width starts a new generation, and operations
/// started under an older one aren't counted.
///
/// A library's files differ in size, so two windows' bytes a second differ with what they read as
/// much as with their widths. Throughput is compared by Little's law instead: the volume moves its
/// width's operations every latency, so a width's gain over another is their ratio over the ratio of
/// their latencies, taken between operations of the same size. A disk with one head, or a network's
/// bandwidth, makes each operation wait for the others, and its latency grows with the width; a
/// volume that serves operations side by side keeps its latency.
struct VolumeConcurrency: Sendable, Hashable {
    /// What one window measured.
    struct Window: Sendable, Hashable {
        var width: Int
        /// Bytes a second, each operation counting at least `minimumBytes`.
        var throughput: Double
        var operationsPerSecond: Double
        /// The mean time from an operation's start to its end.
        var latency: Duration
        /// The median latency of the operations of each size, by the size's power of two.
        var latencies: [Int: Duration] = [:]
        var counts: [Int: Int] = [:]
        /// At least a quarter of the operations waited for a place in flight.
        var saturated: Bool

        /// How much more this window's width gets from the volume than `other`'s: their ratio over
        /// their latencies', weighting each size by the operations both windows had of it; their
        /// throughputs' ratio when they had no size in common.
        func gain(over other: Window) -> Double {
            var logRatio = 0.0
            var weights = 0.0
            for (size, latency) in latencies {
                guard let theirs = other.latencies[size], latency > .zero, theirs > .zero else { continue }
                let weight = Double(min(counts[size] ?? 0, other.counts[size] ?? 0))
                logRatio += weight * log(latency.seconds / theirs.seconds)
                weights += weight
            }
            guard weights > 0 else {
                return other.throughput > 0 ? throughput / other.throughput : 1
            }
            return Double(width) / Double(other.width) / exp(logRatio / weights)
        }
    }

    private enum Probe: Hashable {
        case none
        /// Trying one reader more than the width `from` was measured at.
        case up(from: Window)
        case down(from: Window)
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

    private var started: Duration?
    private var ended = Duration.zero
    private var operations = 0
    private var bytes = 0
    private var latencies: [Int: [Duration]] = [:]
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
        let counted = max(count, Self.minimumBytes)
        bytes += counted
        latencies[Int.bitWidth - counted.leadingZeroBitCount, default: []].append(max(end - start, .zero))
        waited += didWait ? 1 : 0
        let elapsed = ended - (started ?? ended)
        let enough = operations >= max(Self.minimumOperations, 2 * width) && elapsed >= Self.minimumDuration
        guard enough || elapsed >= Self.maximumDuration else { return }
        let seconds = max(elapsed.seconds, 1e-6)
        let all = latencies.values.joined()
        let window = Window(
            width: width, throughput: Double(bytes) / seconds, operationsPerSecond: Double(operations) / seconds,
            latency: all.reduce(.zero, +) / operations,
            latencies: latencies.mapValues { $0.sorted()[$0.count / 2] }, counts: latencies.mapValues(\.count),
            saturated: waited * 4 >= operations,
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
        case let .up(from):
            let gain = window.gain(over: from)
            if gain > 1.05, width < range.upperBound {
                probe = .up(from: window)
                set(width + 1)
            } else {
                settle(gain > 1.05 ? width : from.width)
            }
        case let .down(from):
            let gain = window.gain(over: from)
            if gain >= 0.95, width > range.lowerBound {
                probe = .down(from: window)
                set(width - 1)
            } else {
                settle(gain >= 0.95 ? width : from.width)
            }
        case .none:
            probeIfDue(window)
        }
    }

    private mutating func probeIfDue(_ window: Window) {
        settled += 1
        guard settled >= (probes == 0 ? 1 : Self.probeAfter), range.count > 1 else { return }
        probes += 1
        let up = width == range.lowerBound || (width < range.upperBound && probes % 2 == 1)
        probe = up ? .up(from: window) : .down(from: window)
        set(up ? width + 1 : width - 1)
    }

    private mutating func settle(_ proposed: Int) {
        probe = .none
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
        latencies = [:]
        waited = 0
    }
}
