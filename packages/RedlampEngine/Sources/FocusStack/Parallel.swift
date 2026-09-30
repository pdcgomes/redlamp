import Foundation

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
