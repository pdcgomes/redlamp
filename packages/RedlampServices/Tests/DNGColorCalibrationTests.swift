import Foundation
import Testing
@testable import RedlampServices

/// DNG colour calibration tags (CAM-04).
struct DNGColorCalibrationTests {
    private static func fixture(_ prefix: String) -> URL? {
        DecodeRegressionTests.fixtures.first { $0.lastPathComponent.hasPrefix(prefix) }
    }

    @Test(.enabled(if: fixture("PXL_") != nil))
    func `reads the Pixel's two calibrations with forward matrices`() throws {
        let url = try #require(Self.fixture("PXL_"))
        let color = try #require(DNGColorCalibration.read(url))
        #expect(color.calibrations.map(\.temperature) == [2856, 6504])
        #expect(color.calibrations.allSatisfy { $0.forwardMatrix != nil })
        #expect(color.analogBalance == [1, 1, 1])
        #expect(color.calibrations[0].colorMatrix != color.calibrations[1].colorMatrix)
    }

    @Test(.enabled(if: fixture("IMG_1361") != nil))
    func `reads colour matrices without forward matrices`() throws {
        let url = try #require(Self.fixture("IMG_1361"))
        let color = try #require(DNGColorCalibration.read(url))
        #expect(color.calibrations.map(\.temperature) == [2856, 6504])
        #expect(color.calibrations.allSatisfy { $0.forwardMatrix == nil })
        #expect(color.calibrations.allSatisfy { $0.colorMatrix.contains { $0 < 0 } })
    }

    @Test func `ignores files that are not DNG`() {
        #expect(DNGColorCalibration.read(URL(fileURLWithPath: "/tmp/missing.nef")) == nil)
    }
}
