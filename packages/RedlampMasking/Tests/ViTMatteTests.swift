import Testing
@testable import RedlampMasking

struct ViTMatteTests {
    /// Tiles cover a side whole, the last flush with its end, and a side shorter than a tile is one.
    @Test func `tiles cover every side whole`() {
        #expect(ViTMatte.starts(4096) == [0, 896, 1792, 2688, 3072])
        #expect(ViTMatte.starts(1024) == [0])
        #expect(ViTMatte.starts(600) == [0])
        for length in [1025, 2731, 4096] {
            let starts = ViTMatte.starts(length)
            #expect(starts.last.map { $0 + ViTMatte.tile } == length)
            #expect(zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 <= ViTMatte.tile - ViTMatte.overlap })
        }
    }

    /// A tile's weight is full inside, and falls to nearly nothing at its edges across the overlap.
    @Test func `a tile blends in across the overlap`() {
        #expect(ViTMatte.ramp(512, 1024) == 1)
        #expect(ViTMatte.ramp(ViTMatte.overlap, 1024) == 1)
        #expect(ViTMatte.ramp(0, 1024) < 0.01)
        #expect(ViTMatte.ramp(1023, 1024) < 0.01)
        #expect(abs(ViTMatte.ramp(63, 1024) - 0.5) < 0.01)
    }

    /// ViTMatte's band reaches 5% of the long side outside the coarse edge, closed-form's 2%.
    @Test func `the trimap's outer band is as wide as asked`() {
        let (width, height) = (200, 1)
        let mask = (0 ..< width).map { Float($0 < 100 ? 1 : 0) }
        let narrow = ClosedFormMatte.trimap(mask, width: width, height: height)
        let wide = ClosedFormMatte.trimap(
            mask,
            width: width,
            height: height,
            inner: ViTMatte.inner,
            outer: ViTMatte.outer,
        )
        #expect(narrow[106] == 0 && wide[106] == 0.5)
        #expect(wide[112] == 0)
    }
}
