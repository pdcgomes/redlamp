import RedlampColor
import simd
import Testing

struct CIELabTests {
    /// Pairs from Sharma, Wu and Dalal's CIEDE2000 test data, with their published differences.
    @Test(arguments: [
        (SIMD3(50, 2.6772, -79.7751), SIMD3(50, 0, -82.7485), 2.0425),
        (SIMD3(50, 0, 0), SIMD3(50, -1, 2), 2.3669),
        (SIMD3(50, 2.5, 0), SIMD3(73, 25, -18), 27.1492),
        (SIMD3(60.2574, -34.0099, 36.2677), SIMD3(60.4626, -34.1751, 39.4387), 1.2644),
    ])
    func `matches the published CIEDE2000 test data`(first: SIMD3<Double>, second: SIMD3<Double>, expected: Double) {
        #expect(abs(CIELab.deltaE2000(first, second) - expected) < 1e-4)
        #expect(abs(CIELab.deltaE2000(second, first) - expected) < 1e-4)
    }

    @Test func `white is L 100 and neutral`() {
        let white = CIELab.fromLinearSRGB(SIMD3(1, 1, 1))
        #expect(abs(white.x - 100) < 1e-9 && abs(white.y) < 1e-9 && abs(white.z) < 1e-9)
        let grey = CIELab.fromLinearSRGB(SIMD3(repeating: 0.18))
        #expect(abs(grey.x - 49.496) < 0.01 && abs(grey.y) < 1e-9)
    }
}
