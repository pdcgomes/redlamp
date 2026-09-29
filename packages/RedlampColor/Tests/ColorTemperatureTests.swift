import RedlampColor
import RedlampEngineAPI
import simd
import Testing

struct ColorTemperatureTests {
    @Test func `d 65 is about 6500 K`() {
        let value = ColorTemperature.whiteBalance(for: RGBPrimaries.d65)
        #expect(abs(value.temperature - 6504) < 30)
        #expect(abs(value.tint) < 15)
    }

    @Test(arguments: [2500.0, 3200, 4000, 5500, 6500, 8000, 12000])
    func `round trips`(kelvin: Double) {
        for tint in [-40.0, 0, 25] {
            let xy = ColorTemperature.chromaticity(for: WhiteBalanceValue(temperature: kelvin, tint: tint))
            let back = ColorTemperature.whiteBalance(for: xy)
            #expect(abs(back.temperature - kelvin) / kelvin < 0.005)
            #expect(abs(back.tint - tint) < 0.5)
        }
    }

    @Test func `SRGB white maps to XYZ white`() {
        let white = RGBPrimaries.sRGB.toXYZ * SIMD3<Double>(1, 1, 1)
        #expect(abs(white.y - 1) < 1e-9)
        #expect(abs(white.x - 0.9505) < 1e-3)
    }

    @Test func `camera model round trips multipliers`() throws {
        // Adobe ColorMatrix for a typical Sony body (XYZ -> camera), scaled.
        let model = try #require(CameraColorModel(xyzToCameraRowMajor: [
            0.7374, -0.2389, -0.0551,
            -0.5435, 1.3162, 0.2519,
            -0.1006, 0.1795, 0.6552,
        ]))
        let setting = WhiteBalanceValue(temperature: 4300, tint: 8)
        let multipliers = model.multipliers(for: setting)
        let back = model.whiteBalance(forMultipliers: multipliers)
        #expect(abs(back.temperature - 4300) < 25)
        #expect(abs(back.tint - 8) < 1)
    }
}
