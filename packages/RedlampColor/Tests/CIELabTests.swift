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

    @Test func `Display P3's white and greys are neutral relative to D50`() {
        let white = CIELab.d50(fromLinearDisplayP3: SIMD3(1, 1, 1))
        #expect(abs(white.x - 100) < 1e-6 && abs(white.y) < 1e-6 && abs(white.z) < 1e-6, "\(white)")
        let grey = CIELab.d50(fromLinearDisplayP3: SIMD3(repeating: 0.184))
        #expect(abs(grey.x - 49.97) < 0.01 && abs(grey.y) < 1e-6 && abs(grey.z) < 1e-6, "\(grey)")
    }

    /// sRGB's primaries in D50 L*a*b* through Bradford, as Lindbloom's calculator and Photoshop give
    /// them; ICC's D50 white differs from his in the fourth digit.
    @Test(arguments: [
        (SIMD3<Double>(1, 0, 0), SIMD3<Double>(54.29, 80.80, 69.89)),
        (SIMD3<Double>(0, 1, 0), SIMD3<Double>(87.82, -79.29, 80.99)),
        (SIMD3<Double>(0, 0, 1), SIMD3<Double>(29.57, 68.30, -112.03)),
    ])
    func `sRGB's primaries read their published D50 values`(srgb: SIMD3<Double>, expected: SIMD3<Double>) {
        let p3 = RGBPrimaries.sRGB.conversion(to: .displayP3) * srgb
        let lab = CIELab.d50(fromLinearDisplayP3: p3)
        #expect(simd_length(lab - expected) < 0.5, "\(lab)")
    }
}
