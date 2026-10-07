import Foundation
import RedlampColor
import simd
import Testing

struct TransferFunctionTests {
    /// Every Float the sweep covers, from below black to above white.
    static let sweep: [Float] = (-1024 ... 20480).map { Float($0) / 16384 }
        + (0 ... 255).map { Float($0) / 255 }

    /// The expressions each copy outside RedlampColor wrote before it was shared, kept here so
    /// the shared functions stay bit for bit what they replaced.
    static func formerDecode(_ x: Float) -> Float {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    static func formerEncode(_ x: Float) -> Float {
        x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    static func formerClampedEncode(_ x: Float) -> Float {
        x <= 0.0031308 ? 12.92 * max(x, 0) : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    static func formerSkyOKLab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let r = formerDecode(c.x)
        let g = formerDecode(c.y)
        let b = formerDecode(c.z)
        let l = cbrt(max(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 0))
        let m = cbrt(max(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 0))
        let s = cbrt(max(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 0))
        return SIMD3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
        )
    }

    static var developMetal: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("RedlampKernels/Sources/Shaders/Develop.metal")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test func `sRGB decoding is bit for bit what its copies computed`() {
        for x in Self.sweep {
            #expect(SRGB.decode(x).bitPattern == Self.formerDecode(x).bitPattern, "\(x)")
        }
        #expect(SRGB.decode(SIMD3<Float>(0.2, 0.5, 0.9)) == SIMD3(
            Self.formerDecode(0.2),
            Self.formerDecode(0.5),
            Self.formerDecode(0.9),
        ))
    }

    @Test func `sRGB encoding is bit for bit what its copies computed, clamped or not`() {
        for x in Self.sweep {
            #expect(SRGB.encode(x).bitPattern == Self.formerEncode(x).bitPattern, "\(x)")
            #expect(SRGB.encode(max(x, 0)).bitPattern == Self.formerClampedEncode(x).bitPattern, "\(x)")
        }
    }

    @Test func `sRGB's transfer functions meet the published values`() {
        #expect(SRGB.decode(Float(0)) == 0)
        #expect(SRGB.decode(Float(1)) == 1)
        #expect(abs(SRGB.decode(Float(0.5)) - 0.21404114) < 1e-6)
        #expect(abs(SRGB.decode(0.5 as Double) - 0.214041140482232) < 1e-12)
        #expect(abs(SRGB.encode(Float(0.18)) - 0.46135613) < 1e-6)
        for x in Self.sweep where x >= 0 && x <= 1 {
            #expect(abs(SRGB.encode(SRGB.decode(x)) - x) < 1e-5)
        }
    }

    @Test func `the sky's OKLab is bit for bit what it computed`() {
        for r in stride(from: Float(0), through: 1, by: 0.0625) {
            for g in stride(from: Float(0), through: 1, by: 0.0625) {
                for b in stride(from: Float(0), through: 1, by: 0.0625) {
                    let c = SIMD3(r, g, b)
                    let shared = OKLab.fromLinearSRGB(SRGB.decode(c))
                    #expect(shared == Self.formerSkyOKLab(c), "\(c)")
                }
            }
        }
    }

    @Test func `OKLab of white is white, and Rec.2020 makes the round trip`() {
        let white = OKLab.fromLinearRec2020(SIMD3(repeating: 1))
        #expect(abs(white.x - 1) < 1e-4 && abs(white.y) < 1e-4 && abs(white.z) < 1e-4)
        let srgbWhite = OKLab.fromLinearSRGB(SIMD3<Float>(repeating: 1))
        #expect(abs(srgbWhite.x - 1) < 1e-4 && abs(srgbWhite.y) < 1e-4 && abs(srgbWhite.z) < 1e-4)
        for c in [SIMD3<Float>(0.18, 0.18, 0.18), SIMD3(0.8, 0.2, 0.1), SIMD3(0.05, 0.4, 0.9)] {
            let back = OKLab.toLinearRec2020(OKLab.fromLinearRec2020(c))
            #expect(simd_length(back - c) < 1e-4, "\(c)")
        }
    }

    @Test func `the constants are the develop kernel's`() throws {
        let metal = try Self.developMetal
        #expect(metal.contains("kRec2020Luma = float3(0.2627f, 0.6780f, 0.0593f)"))
        #expect(Luma.rec2020 == SIMD3<Float>(0.2627, 0.6780, 0.0593))
        #expect(Luma.rec2020Double == SIMD3<Double>(0.2627, 0.6780, 0.0593))
        #expect(metal.contains("float3(0.2126f, 0.7152f, 0.0722f)"))
        #expect(Luma.rec709 == SIMD3<Float>(0.2126, 0.7152, 0.0722))
        #expect(metal.contains("x <= 0.0031308f ? 12.92f * x : 1.055f * pow(x, 1.0f / 2.4f) - 0.055f"))
        #expect(metal.contains("x <= 0.04045f ? x / 12.92f : pow((x + 0.055f) / 1.055f, 2.4f)"))
        for coefficient in [
            "0.6167557872f", "0.3601983994f", "0.0230458134f",
            "0.2104542553f", "0.7936177850f", "0.0040720468f",
            "0.3963377774f", "0.2158037573f", "2.1399067357f", "1.2463895088f", "0.1064827730f",
        ] {
            #expect(metal.contains(coefficient), "\(coefficient)")
        }
    }
}
