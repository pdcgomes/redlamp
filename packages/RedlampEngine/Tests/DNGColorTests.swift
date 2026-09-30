import Foundation
import RedlampColor
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Dual-illuminant DNG colour (CAM-04): calibrations interpolated by colour temperature.
struct DNGColorTests {
    static let calibrated: [(URL, DecodedImage, DNGColorCalibration)] = EngineSmokeTests.fixtures
        .filter { $0.pathExtension.lowercased() == "dng" }
        .compactMap { url in
            guard let decoded = try? ImageDecoder.decode(url), let color = decoded.dngColor else { return nil }
            return (url, decoded, color)
        }

    /// Calibrated files with colour matrices only.
    static let matricesOnly = calibrated.filter { $0.2.calibrations.allSatisfy { $0.forwardMatrix == nil } }

    private static func xyz(_ x: Double, _ y: Double) -> SIMD3<Double> {
        SIMD3(x / y, 1, (1 - x - y) / y)
    }

    private static func maxDifference(_ a: simd_float3x3, _ b: simd_float3x3) -> Float {
        (0 ..< 3).map { abs(a[$0] - b[$0]).max() }.max() ?? 0
    }

    @Test func `weights are linear in inverse temperature`() {
        let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let color = DNGColorCalibration(calibrations: [
            .init(temperature: 2856, colorMatrix: identity, cameraCalibration: identity, forwardMatrix: nil),
            .init(temperature: 6504, colorMatrix: identity, cameraCalibration: identity, forwardMatrix: nil),
        ], analogBalance: [1, 1, 1])
        #expect(color.weight(2000) == 1 && color.weight(2856) == 1)
        #expect(color.weight(6504) == 0 && color.weight(10000) == 0)
        let middle = 1 / ((1 / 2856.0 + 1 / 6504.0) / 2)
        #expect(abs(color.weight(middle) - 0.5) < 1e-9)
    }

    @Test func `McCamy's approximation recovers the standard illuminants`() {
        #expect(abs(DNGColorCalibration.temperature(x: 0.3127, y: 0.3290) - 6504) < 30)
        #expect(abs(DNGColorCalibration.temperature(x: 0.44757, y: 0.40745) - 2856) < 30)
    }

    @Test(.enabled(if: !calibrated.isEmpty))
    func `neutral stays neutral at every temperature`() {
        for (url, _, color) in Self.calibrated {
            for temperature in [2500.0, 2856, 4000, 5500, 6504, 9000] {
                let white = color.cameraToWorking(temperature: temperature) * SIMD3<Float>(1, 1, 1)
                #expect(abs(white - SIMD3(1, 1, 1)).max() < 0.01, "\(url.lastPathComponent) \(temperature) K: \(white)")
            }
            let cool = color.cameraToWorking(temperature: 2856)
            let warm = color.cameraToWorking(temperature: 6504)
            #expect(Self.maxDifference(cool, warm) > 0.01, "\(url.lastPathComponent): calibrations do not differ")
        }
    }

    @Test(.enabled(if: !calibrated.isEmpty))
    func `a camera neutral's temperature round-trips`() {
        for (url, decoded, color) in Self.calibrated {
            for (temperature, white) in [(6504.0, Self.xyz(0.3127, 0.3290)), (2856, Self.xyz(0.44757, 0.40745))] {
                let neutral = color.xyzToCamera(weight: color.weight(temperature)) * white
                let found = color.temperature(ofNeutral: neutral)
                #expect(abs(found - temperature) < 60, "\(url.lastPathComponent): \(found) K for \(temperature) K")
            }
            let neutral = 1 / decoded.asShotMultipliers
            let asShot = color.temperature(ofNeutral: neutral / neutral.y)
            #expect((2000 ... 12000).contains(asShot), "\(url.lastPathComponent) as shot \(asShot) K")
        }
    }

    @Test(.enabled(if: !matricesOnly.isEmpty))
    func `without forward matrices, daylight matches LibRaw's matrix`() {
        for (url, decoded, color) in Self.matricesOnly {
            let ours = color.cameraToWorking(temperature: 6504)
            let libRaw = (ColorMatrices.sRGBToRec2020 * simd_double3x3(rowMajor: decoded.cameraToSRGB)).floatMatrix
            #expect(Self.maxDifference(ours, libRaw) < 0.03, "\(url.lastPathComponent): \(ours) vs \(libRaw)")
        }
    }
}
