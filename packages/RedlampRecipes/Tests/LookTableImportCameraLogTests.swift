import Foundation
import RedlampEngineAPI
import RedlampRecipes
import simd
import Testing

/// The camera log curves and gamuts against the values their makers publish.
struct CameraLogSpaceTests {
    @Test func `each curve puts black, middle grey and white where its maker does`() {
        // Sony's 10-bit code values: 0% reflectance at 95, 18% at 420, 90% at 598.
        let sLog3 = CameraLogSpace.sLog3SGamut3Cine
        #expect(abs(sLog3.encode(0) * 1023 - 95) < 0.01)
        #expect(abs(sLog3.encode(0.18) * 1023 - 420) < 0.01)
        #expect(abs(sLog3.encode(0.9) * 1023 - 598) < 0.5)
        #expect(CameraLogSpace.sLog3SGamut3.encode(0.18) == sLog3.encode(0.18))
        // ARRI at EI 800: black at f = 0.092809, 18% at 0.391.
        #expect(abs(CameraLogSpace.logC3.encode(0) - 0.092809) < 1e-6)
        #expect(abs(CameraLogSpace.logC3.encode(0.18) - 0.391007) < 1e-5)
        // Panasonic's 10-bit code values: 0% at 128, 18% at 433, 90% at 602.
        #expect(abs(CameraLogSpace.vLog.encode(0) * 1023 - 128) < 0.5)
        #expect(abs(CameraLogSpace.vLog.encode(0.18) * 1023 - 433) < 0.5)
        #expect(abs(CameraLogSpace.vLog.encode(0.9) * 1023 - 602) < 0.5)
        // Apple's formula: 0% at c·R₀², 18% at γ·log₂(0.18 + β) + δ.
        #expect(abs(CameraLogSpace.appleLog.encode(0) - 0.150476) < 1e-5)
        #expect(abs(CameraLogSpace.appleLog.encode(0.18) - 0.488272) < 1e-5)
        #expect(CameraLogSpace.appleLog.encode(-0.1) == 0)
    }

    @Test(arguments: CameraLogSpace.allCases)
    func `each curve round trips`(space: CameraLogSpace) {
        for linear: Float in [-0.01, 0, 0.001, 0.005, 0.0105, 0.0115, 0.05, 0.18, 0.5, 0.9, 2, 8] {
            let back = space.decode(space.encode(linear))
            #expect(abs(back - linear) <= 1e-5 * max(abs(linear), 0.1), "\(linear) came back as \(back)")
        }
        for signal in stride(from: Float(0), through: 1, by: 0.05) {
            #expect(abs(space.encode(space.decode(signal)) - signal) < 1e-5, "\(signal)")
        }
    }

    @Test func `each curve's pieces meet`() {
        let joins: [(CameraLogSpace, Float)] = [
            (.sLog3SGamut3Cine, 0.01125), (.logC3, 0.010591), (.vLog, 0.01), (.appleLog, 0.01),
        ]
        for (space, x) in joins {
            #expect(abs(space.encode(x.nextUp) - space.encode(x.nextDown)) < 1e-6, "\(space)")
            #expect(abs(space.decode(space.encode(x)) - x) < 1e-7, "\(space)")
        }
    }

    @Test(arguments: CameraLogSpace.allCases)
    func `each gamut keeps white and inverts`(space: CameraLogSpace) {
        let white = SIMD3<Float>(repeating: 1)
        #expect(simd_distance(space.toRec2020 * white, white) < 1e-5)
        #expect(simd_distance(space.fromRec2020 * white, white) < 1e-5)
        let product = space.toRec2020 * space.fromRec2020
        for column in 0 ..< 3 {
            #expect(simd_distance(product[column], matrix_identity_float3x3[column]) < 1e-5)
        }
    }

    @Test(arguments: CameraLogSpace.allCases)
    func `middle grey enters each camera space as middle grey`(space: CameraLogSpace) {
        let signal = space.encode(space.fromRec2020 * SIMD3(repeating: 0.18))
        #expect(simd_distance(signal, SIMD3(repeating: space.encode(0.18))) < 1e-5)
    }

    /// The gamuts are derived from the makers' primaries; these are the matrices they print.
    @Test func `each gamut matches its maker's published matrix`() {
        // ITU-R BT.2020's RGB to XYZ.
        let rec2020ToXYZ = simd_float3x3(rows: [
            SIMD3(0.6369580483, 0.1446169036, 0.1688809752),
            SIMD3(0.2627002120, 0.6779980715, 0.0593017165),
            SIMD3(0, 0.0280726930, 1.0609850577),
        ])
        let toXYZ: [(CameraLogSpace, simd_float3x3)] = [
            (.sLog3SGamut3Cine, simd_float3x3(rows: [
                SIMD3(0.5990839208, 0.2489255161, 0.1024464902),
                SIMD3(0.2150758201, 0.8850685017, -0.1001443219),
                SIMD3(-0.0320658495, -0.0276583907, 1.1487819910),
            ])),
            (.sLog3SGamut3, simd_float3x3(rows: [
                SIMD3(0.7064827132, 0.1288010498, 0.1151721641),
                SIMD3(0.2709796708, 0.7866064112, -0.0575860820),
                SIMD3(-0.0096778454, 0.0046000375, 1.0941355587),
            ])),
            (.logC3, simd_float3x3(rows: [
                SIMD3(0.638008, 0.214704, 0.097744),
                SIMD3(0.291954, 0.823841, -0.115795),
                SIMD3(0.002798, -0.067034, 1.153294),
            ])),
            (.vLog, simd_float3x3(rows: [
                SIMD3(0.679644, 0.152211, 0.118600),
                SIMD3(0.260686, 0.774894, -0.035580),
                SIMD3(-0.009310, -0.004612, 1.102980),
            ])),
            (.appleLog, rec2020ToXYZ),
        ]
        for (space, published) in toXYZ {
            let derived = rec2020ToXYZ * space.toRec2020
            for column in 0 ..< 3 {
                #expect(simd_distance(derived[column], published[column]) < 2e-6, "\(space)")
            }
        }
        // ARRI and Panasonic also print their gamuts' conversions to linear Rec.709.
        let to709: [(CameraLogSpace, simd_float3x3)] = [
            (.logC3, simd_float3x3(rows: [
                SIMD3(1.617523, -0.537287, -0.080237),
                SIMD3(-0.070573, 1.334613, -0.26404),
                SIMD3(-0.021102, -0.226954, 1.248056),
            ])),
            (.vLog, simd_float3x3(rows: [
                SIMD3(1.806576, -0.695697, -0.110879),
                SIMD3(-0.170090, 1.305955, -0.135865),
                SIMD3(-0.025206, -0.154468, 1.179674),
            ])),
        ]
        for (space, published) in to709 {
            let derived = ColorMath.rec2020ToRec709 * space.toRec2020
            for column in 0 ..< 3 {
                #expect(simd_distance(derived[column], published[column]) < 1e-5, "\(space)")
            }
        }
    }

    @Test func `Rec.709 output decodes with BT.1886's 2.4 gamma, and sRGB with its own curve`() {
        let rec709 = LookTableOutput.rec709.decode(SIMD3(0.5, -0.1, 1))
        #expect(abs(rec709.x - pow(0.5, 2.4)) < 1e-6)
        #expect(rec709.y == 0 && rec709.z == 1)
        let half = SIMD3<Float>(repeating: 0.5)
        #expect(LookTableOutput.sRGB.decode(half) == ColorMath.srgbDecode(half))
    }
}
