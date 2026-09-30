import Foundation

/// Work started now on `queue`, whose result is collected later.
final class Prefetch<Value>: @unchecked Sendable {
    // Written once by the work, read only after `done` signals.
    private var result: Result<Value, any Error>?
    private let done = DispatchSemaphore(value: 0)

    init(on queue: DispatchQueue, _ work: @escaping @Sendable () throws -> Value) {
        queue.async { [self] in
            result = Result { try work() }
            done.signal()
        }
    }

    /// Waits for the work and returns its result; call once.
    func value() throws -> Value {
        done.wait()
        return try result!.get()
    }
}

enum Parallel {
    /// `body(0 ..< count)` on every core, results in order.
    static func map<T>(_ count: Int, _ body: @Sendable (Int) -> T) -> [T] {
        let results = UnsafeMutableBufferPointer<T?>.allocate(capacity: count)
        results.initialize(repeating: nil)
        defer { results.deallocate() }
        // Each iteration writes only its own slot.
        nonisolated(unsafe) let slots = results
        DispatchQueue.concurrentPerform(iterations: count) { slots[$0] = body($0) }
        return results.map { $0! }
    }
}
