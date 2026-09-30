import Testing
@testable import RedlampServices

/// Clip-spike white levels (CAM-02).
struct WhiteLevelTests {
    private func measured(_ entries: [Int: UInt32], nominal: Float = 16383, total: Int = 20_000_000) -> Float {
        var histogram = [UInt32](repeating: 0, count: 65536)
        for (value, count) in entries {
            histogram[value] = count
        }
        return histogram.withUnsafeBufferPointer { WhiteLevel.measured(histogram: $0, nominal: nominal, total: total) }
    }

    @Test func `a spike at the maximum is the clip point`() {
        #expect(measured([12000: 5000, 16383: 764]) == 16383)
        #expect(measured([12000: 5000, 16300: 900]) == 16300, "below nominal")
        #expect(measured([12000: 5000, 16628: 231]) == 16628, "above nominal, as Sony's data can be")
    }

    @Test func `without a spike the nominal level stands`() {
        #expect(measured([12000: 5000, 13197: 1, 13201: 1]) == 16383, "a stray bright photosite")
        #expect(measured([4000: 5000, 8205: 1]) == 16383, "nothing near clipping")
    }

    @Test func `a spike must stand out from a smooth ramp`() {
        var ramp: [Int: UInt32] = [:]
        for value in 16200 ... 16367 {
            ramp[value] = 800
        }
        #expect(measured(ramp) == 16383, "a dense ramp is data, not clipping")
        ramp[16368] = 148_581
        #expect(measured(ramp) == 16368)
    }
}
