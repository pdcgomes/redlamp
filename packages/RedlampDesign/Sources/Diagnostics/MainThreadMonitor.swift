import CoreFoundation
import Foundation

/// Measures how long each main run-loop iteration keeps the main thread busy. A slider
/// drag feels smooth only if iterations stay well under one display frame (8.3 ms at 120 Hz).
@MainActor
public final class MainThreadMonitor {
    public struct Summary: Sendable {
        public var iterations: Int
        /// Share of the measured time the main thread was busy, 0...1.
        public var busy: Double
        public var p50: Double
        public var p95: Double
        public var p99: Double
        public var max: Double
        public var overFrame: Int
        public var overTwoFrames: Int
    }

    private var observer: CFRunLoopObserver?
    private var iterationStart: CFAbsoluteTime = 0
    private var started: CFAbsoluteTime = 0
    public private(set) var durations: [Double] = []
    /// When each of `durations`' iterations began.
    public private(set) var starts: [CFAbsoluteTime] = []

    public init() {}

    public func start() {
        durations.removeAll()
        starts.removeAll()
        started = CFAbsoluteTimeGetCurrent()
        let observer = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            0,
        ) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CFAbsoluteTimeGetCurrent()
                if activity == .afterWaiting {
                    self.iterationStart = now
                } else if self.iterationStart > 0 {
                    self.durations.append((now - self.iterationStart) * 1000)
                    self.starts.append(self.iterationStart)
                    self.iterationStart = 0
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    public func stop() {
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        observer = nil
    }

    public func summary(seconds: Double? = nil) -> Summary? {
        let sorted = durations.sorted()
        guard !sorted.isEmpty else { return nil }
        let elapsed = seconds ?? (CFAbsoluteTimeGetCurrent() - started)
        func percentile(_ p: Double) -> Double {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        return Summary(
            iterations: sorted.count,
            busy: sorted.reduce(0, +) / (elapsed * 1000),
            p50: percentile(0.5),
            p95: percentile(0.95),
            p99: percentile(0.99),
            max: sorted.last ?? 0,
            overFrame: sorted.count(where: { $0 > 8.3 }),
            overTwoFrames: sorted.count(where: { $0 > 16.7 }),
        )
    }

    public func report(_ label: String, seconds: Double) -> String {
        guard let summary = summary(seconds: seconds) else { return "\(label): no samples" }
        return String(
            format: "%@: %d iterations, busy %.0f%% of %.1fs, p50 %.2f ms, p95 %.2f ms, p99 %.2f ms, max %.1f ms, >8.3 ms: %d, >16.7 ms: %d",
            label, summary.iterations, summary.busy * 100, seconds, summary.p50, summary.p95, summary.p99,
            summary.max, summary.overFrame, summary.overTwoFrames,
        )
    }
}
