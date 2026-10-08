import Foundation

/// Holds the threads that reach it, from `hold` until `release`, as a decode service or a model
/// catalogue that is busy holds its callers; `Gate` does the same for tasks. The main thread
/// passes, as waiting there would stop the test that releases it, and a thread waits 30 s at
/// most: with few cores, the held threads can leave Swift concurrency none to wake that test.
final class BlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = false

    /// Threads from now on wait for `release`.
    func hold() {
        condition.withLock { held = true }
    }

    func release() {
        condition.withLock {
            held = false
            condition.broadcast()
        }
    }

    func pass() {
        guard !Thread.isMainThread else { return }
        let deadline = Date.now.addingTimeInterval(30)
        condition.withLock {
            while held, condition.wait(until: deadline) {}
        }
    }
}
