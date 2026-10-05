import Foundation

/// A random number generator that makes the same numbers from the same seed on every Mac and
/// every version of Swift (SplitMix64), so a seed always makes the same fixture and the same
/// simulated delays. Its bounded numbers are its own, not the standard library's, whose
/// algorithms may change.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    /// One of many independent sequences under `seed`, so photo `n`'s choices don't depend on
    /// how many numbers photo `n - 1` drew, nor on the order photos are made in.
    public init(seed: UInt64, stream: UInt64) {
        state = Self.mix(seed ^ Self.mix(stream &+ 0x632B_E59B_D9B4_E019))
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return Self.mix(state)
    }

    /// A number in `0 ..< bound`; `bound` must be positive.
    public mutating func int(below bound: Int) -> Int {
        Int(next().multipliedFullWidth(by: UInt64(bound)).high)
    }

    public mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + int(below: range.count)
    }

    /// A number in `0 ..< 1`.
    public mutating func unit() -> Double {
        Double(next() >> 11) * 0x1p-53
    }

    public mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }

    public mutating func pick<T>(_ items: [T]) -> T {
        items[int(below: items.count)]
    }

    /// A standard normal number (Box–Muller).
    public mutating func normal() -> Double {
        let u = max(unit(), .leastNormalMagnitude)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * unit())
    }

    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
