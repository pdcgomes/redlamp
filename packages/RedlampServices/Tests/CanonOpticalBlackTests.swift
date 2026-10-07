import Foundation
import Testing
@testable import RedlampServices

/// Canon's black levels against the masked photosites its files declare (CAM-21).
struct CanonOpticalBlackTests {
    /// A Canon-like readout: masked columns on the left and rows on top, the exposed image beside
    /// them, and the image area LibRaw cuts out inside that.
    private struct Readout {
        static let width = 400
        static let height = 300
        static let activeLeft = 64
        static let activeTop = 40
        static let areas = [
            CanonOpticalBlack.Area(top: 0, left: 0, bottom: height - 1, right: activeLeft - 1),
            CanonOpticalBlack.Area(top: 0, left: activeLeft, bottom: activeTop - 1, right: width - 1),
        ]

        var samples: [UInt16]
        var top = 52
        var left = 76

        /// `black(row, column)` in the masked photosites, with noise of `sigma`.
        init(black: (Int, Int) -> Float, sigma: Float = 1.2, seed: UInt64 = 7) {
            var random = SeededRandom(seed: seed)
            samples = (0 ..< Self.width * Self.height).map { index in
                let row = index / Self.width
                let column = index % Self.width
                let exposed = row >= Self.activeTop && column >= Self.activeLeft
                let level = black(row, column) + (exposed ? Float(1500 + 20 * column + 10 * row) : 0)
                return UInt16(clamping: Int((level + sigma * random.gaussian()).rounded()))
            }
        }

        init(black: Float) {
            self.init(black: { _, _ in black })
        }

        mutating func set(rows: Range<Int>, columns: Range<Int>, to value: UInt16) {
            for row in rows {
                for column in columns {
                    samples[row * Self.width + column] = value
                }
            }
        }

        func measure(areas: [CanonOpticalBlack.Area] = Readout.areas) -> [CanonOpticalBlack.Level]? {
            samples.withUnsafeBufferPointer { raw in
                CanonOpticalBlack.measure(
                    raw: raw.baseAddress!, pitch: Self.width, rawWidth: Self.width, rawHeight: Self.height,
                    top: top, left: left, areas: areas, white: 16383,
                )
            }
        }
    }

    @Test func `a black level misread from the colour data gives way to the masked photosites`() throws {
        let measured = try #require(Readout(black: 512).measure())
        #expect(measured.allSatisfy { abs($0.value - 512) <= 1 }, "\(measured)")
        #expect(CanonOpticalBlack.isWrong([0, 58, 145, 113], measured: measured, white: 16383))
        #expect(CanonOpticalBlack.isWrong([4000, 4000, 4000, 4000], measured: measured, white: 16383))
    }

    @Test func `a stated black the masked photosites agree with stands`() throws {
        let measured = try #require(Readout(black: 512).measure())
        #expect(!CanonOpticalBlack.isWrong([512, 512, 512, 512], measured: measured, white: 16383))
        #expect(!CanonOpticalBlack.isWrong([510.25, 511, 512.5, 511], measured: measured, white: 16383))
        #expect(
            !CanonOpticalBlack.isWrong([440, 440, 440, 440], measured: measured, white: 16383),
            "under 1% of the range, which the camera bench doesn't fail",
        )
    }

    @Test func `each pattern position is measured on its own, from the image's origin`() throws {
        let levels: [Float] = [510, 514, 508, 512]
        var readout = Readout(black: { row, column in
            levels[((row - 53) & 1) << 1 | ((column - 77) & 1)]
        })
        readout.top = 53
        readout.left = 77
        let measured = try #require(readout.measure())
        #expect(zip(measured, levels).allSatisfy { abs($0.value - $1) <= 1 }, "\(measured)")
    }

    @Test func `exposed photosites at the edge of a declared area don't move it`() throws {
        var readout = Readout(black: 512)
        readout.set(rows: 0 ..< Readout.height, columns: Readout.activeLeft - 2 ..< Readout.activeLeft, to: 4000)
        readout.set(rows: Readout.activeTop - 2 ..< Readout.activeTop, columns: 0 ..< Readout.width, to: 4000)
        let measured = try #require(readout.measure())
        #expect(measured.allSatisfy { abs($0.value - 512) <= 1 }, "\(measured)")
    }

    @Test func `reference rows and a strip read at another level don't move it`() throws {
        var readout = Readout(black: { _, column in column < 24 ? 468 : 512 })
        readout.set(rows: 12 ..< 16, columns: 0 ..< Readout.width, to: 4900)
        let measured = try #require(readout.measure())
        #expect(measured.allSatisfy { abs($0.value - 512) <= 1 }, "\(measured)")
    }

    @Test func `padding is not masked photosites`() {
        var readout = Readout(black: 512)
        readout.set(rows: 0 ..< Readout.height, columns: 0 ..< Readout.activeLeft, to: 0)
        readout.set(rows: 0 ..< Readout.activeTop, columns: 0 ..< Readout.width, to: 0)
        #expect(readout.measure() == nil)
    }

    @Test func `areas too small to measure leave the stated black`() {
        let narrow = [CanonOpticalBlack.Area(top: 0, left: 0, bottom: Readout.height - 1, right: 12)]
        #expect(Readout(black: 512).measure(areas: narrow) == nil)
        #expect(Readout(black: 512).measure(areas: []) == nil)
    }

    static let r6MarkIII = DecodeRegressionTests.cameras.first { $0.lastPathComponent == "Canon_EOS-R6-Mark-III.CR3" }

    @Test(.enabled(if: CanonOpticalBlackTests.r6MarkIII != nil))
    func `the R6 Mark III decodes at the black its masked photosites show`() throws {
        let url = try #require(Self.r6MarkIII)
        let decoded = try ImageDecoder.decode(url)
        #expect(decoded.blackLevels.allSatisfy { abs($0 - 512) <= 2 }, "\(decoded.blackLevels)")
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
