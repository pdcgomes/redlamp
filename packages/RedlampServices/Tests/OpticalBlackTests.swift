import Foundation
import Testing
@testable import RedlampServices

/// Row and column banding from the optical-black margins (DN-03).
struct OpticalBlackTests {
    /// `lines` margin lines of `count` samples: noise of `sigma` on top of each line's `offsets`.
    private func margin(_ offsets: [Float], count: Int, sigma: Float, seed: UInt64 = 3) -> [[Float]] {
        var random = SeededRandom(seed: seed)
        return offsets.map { offset in (0 ..< count).map { _ in offset + sigma * random.gaussian() } }
    }

    @Test func `banding is recovered with less error than the raw line means`() throws {
        var random = SeededRandom(seed: 11)
        let truth = (0 ..< 2000).map { _ in 1.5 * random.gaussian() }
        let lines = margin(truth, count: 64, sigma: 6)
        let offsets = try #require(OpticalBlack.lineOffsets(lines))
        let means = lines.map { $0.reduce(0, +) / Float($0.count) }
        func error(_ estimate: [Float]) -> Float {
            zip(estimate, truth).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / Float(truth.count)
        }
        let variance = truth.map { $0 * $0 }.reduce(0, +) / Float(truth.count)
        #expect(error(offsets) < error(means))
        #expect(error(offsets) < 0.5 * variance, "error \(error(offsets)) of variance \(variance)")
    }

    @Test func `noise alone is not banding`() {
        let lines = margin([Float](repeating: 0, count: 2000), count: 64, sigma: 6)
        #expect(OpticalBlack.lineOffsets(lines) == nil)
    }

    @Test func `a hot photosite doesn't band its line`() throws {
        var random = SeededRandom(seed: 5)
        var lines = margin((0 ..< 1000).map { _ in 2 * random.gaussian() }, count: 64, sigma: 3)
        lines[500][10] = 4000
        let offsets = try #require(OpticalBlack.lineOffsets(lines))
        let others = lines[500].enumerated().filter { $0.offset != 10 }.map(\.element)
        let clean = others.reduce(0, +) / Float(others.count)
        #expect(abs(offsets[500] - clean) < 1.5, "offset \(offsets[500]), line level \(clean)")
    }

    @Test func `margins away from the black level aren't masked`() {
        let dummy = margin([Float](repeating: -187, count: 100), count: 32, sigma: 4)
        #expect(!OpticalBlack.isBlack(dummy, white: 16383))
        let masked = margin([Float](repeating: 0.1, count: 100), count: 32, sigma: 4)
        #expect(OpticalBlack.isBlack(masked, white: 16383))
    }

    @Test(.enabled(if: DecodeRegressionTests.fixtures.contains { $0.lastPathComponent.hasPrefix("Canon_EOS_R6") }))
    func `the R6's margins measure small banding`() throws {
        let url = try #require(DecodeRegressionTests.fixtures.first { $0.lastPathComponent.hasPrefix("Canon_EOS_R6") })
        let decoded = try ImageDecoder.decode(url)
        let banding = try #require(decoded.banding)
        #expect(banding.rows.count == decoded.height)
        #expect(banding.columns.isEmpty || banding.columns.count == decoded.width)
        let largest = (banding.rows + banding.columns).map(abs).max() ?? 0
        #expect(largest > 0 && largest < 3, "largest offset \(largest) DN")
    }

    @Test func `cameras without masked margins get no correction`() throws {
        for url in DecodeRegressionTests.fixtures where !url.lastPathComponent.hasPrefix("Canon_EOS_R6") {
            #expect(try ImageDecoder.decode(url).banding == nil, "\(url.lastPathComponent)")
        }
    }
}

/// xorshift64* with Box–Muller, so tests are reproducible.
private struct SeededRandom {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }

    mutating func uniform() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    mutating func gaussian() -> Float {
        let u1 = max(uniform(), 1e-7)
        let u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
