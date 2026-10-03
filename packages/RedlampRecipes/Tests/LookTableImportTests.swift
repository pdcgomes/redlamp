import CoreGraphics
import Foundation
import RedlampEngineAPI
import RedlampRecipes
import simd
import Testing

/// Look tables written in the tests, in the formats Redlamp imports.
enum LookTableFixtures {
    /// An asymmetric grade, so a swapped channel or axis shows.
    static func grade(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(c.x * c.x * 0.9 + 0.05, c.y.squareRoot() * 0.8 + 0.1 * c.z, 1 - 0.7 * c.z + 0.1 * c.x)
    }

    static func cube(size: Int, header: [String] = [], _ transform: (SIMD3<Float>) -> SIMD3<Float>) -> String {
        var lines = header + ["LUT_3D_SIZE \(size)"]
        let scale = 1 / Float(size - 1)
        for b in 0 ..< size {
            for g in 0 ..< size {
                for r in 0 ..< size {
                    let v = transform(SIMD3(Float(r), Float(g), Float(b)) * scale)
                    lines.append(String(format: "%.6f %.6f %.6f", v.x, v.y, v.z))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func gradedHald() throws -> CGImage {
        let identity = try #require(LookTableImport.haldIdentity(level: 4))
        var pixels = try #require(PixelImage(identity, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
        for y in 0 ..< pixels.height {
            for x in 0 ..< pixels.width {
                pixels[x, y] = grade(pixels[x, y])
            }
        }
        return try #require(pixels.cgImage())
    }
}

/// What `.cube` and HaldCLUT imports produced before `.3dl` and camera log spaces, pinned so
/// those imports stay as they were. Values rather than hashes: libm may round differently on
/// another OS release.
struct ExistingLookTableImportTests {
    static let probes: [SIMD3<Float>] = [
        SIMD3(0.1, 0.5, 0.9), SIMD3(0.33, 0.33, 0.33), SIMD3(0.8, 0.2, 0.4), SIMD3(0.05, 0.9, 0.6),
        SIMD3(1, 1, 1), SIMD3(0, 0, 0),
    ]

    private func expect(_ table: LookTable, size: Int, mean: Float, samples: [SIMD3<Float>]) {
        #expect(table.size == size)
        #expect(table.space == .displayRec2020)
        let actualMean = table.values.reduce(0) { $0 + Float($1) } / Float(table.values.count)
        #expect(abs(actualMean - mean) < 2e-5, "mean \(actualMean)")
        for (probe, expected) in zip(Self.probes, samples) {
            let actual = table.sample(probe)
            #expect(simd_distance(actual, expected) < 1e-3, "\(probe) gave \(actual)")
        }
    }

    @Test func `an sRGB cube imports as before`() throws {
        let table = try LookTableImport.parseCube(LookTableFixtures.cube(size: 5, LookTableFixtures.grade)).table
        expect(table, size: 17, mean: 0.563803, samples: [
            SIMD3(0.21104, 0.63740, 0.38237), SIMD3(0.36008, 0.47725, 0.77502), SIMD3(0.76611, 0.19985, 0.78447),
            SIMD3(0.00000, 0.78682, 0.61992), SIMD3(0.91797, 0.89990, 0.48779), SIMD3(0.23694, 0.10992, 0.95264),
        ])
    }

    @Test func `a cube in Redlamp's space imports as before`() throws {
        let text = LookTableFixtures.cube(size: 5, LookTableFixtures.grade)
        let table = try LookTableImport.parseCube(text, space: .displayRec2020).table
        expect(table, size: 17, mean: 0.541835, samples: [
            SIMD3(0.07251, 0.65566, 0.37998), SIMD3(0.16023, 0.48605, 0.80211), SIMD3(0.63506, 0.35996, 0.80000),
            SIMD3(0.06127, 0.81719, 0.58506), SIMD3(0.95020, 0.89990, 0.39990), SIMD3(0.04999, 0.00000, 1.00000),
        ])
    }

    @Test func `a cube with a domain imports as before`() throws {
        let text = LookTableFixtures.cube(
            size: 9,
            header: ["DOMAIN_MIN -0.1 0 0", "DOMAIN_MAX 1.1 1 2"],
            LookTableFixtures.grade,
        )
        expect(try LookTableImport.parseCube(text).table, size: 17, mean: 0.598776, samples: [
            SIMD3(0.19541, 0.59531, 0.66934), SIMD3(0.37187, 0.46926, 0.88533), SIMD3(0.66396, 0.13594, 0.90791),
            SIMD3(0.00000, 0.76162, 0.80039), SIMD3(0.82031, 0.84619, 0.75293), SIMD3(0.24060, 0.11157, 0.96094),
        ])
    }

    @Test func `a 1D cube imports as before`() throws {
        let text = ["LUT_1D_SIZE 5", "0 0 0", "0.3 0.2 0.1", "0.55 0.5 0.4", "0.8 0.75 0.7", "1 0.95 0.9"]
            .joined(separator: "\n")
        expect(try LookTableImport.parseCube(text).table, size: 33, mean: 0.473475, samples: [
            SIMD3(0.03340, 0.49785, 0.81826), SIMD3(0.34864, 0.30189, 0.21144), SIMD3(0.80039, 0.19888, 0.29497),
            SIMD3(0.00000, 0.86016, 0.52227), SIMD3(0.97998, 0.95312, 0.90625), SIMD3(0.00000, 0.00000, 0.00000),
        ])
    }

    @Test func `a large cube is stored at 33 points, as before`() throws {
        let table = try LookTableImport.parseCube(LookTableFixtures.cube(size: 40, LookTableFixtures.grade)).table
        expect(table, size: 33, mean: 0.566308, samples: [
            SIMD3(0.21138, 0.63857, 0.38232), SIMD3(0.36009, 0.48296, 0.77488), SIMD3(0.76445, 0.19849, 0.78477),
            SIMD3(0.00000, 0.78799, 0.62002), SIMD3(0.91797, 0.89990, 0.48779), SIMD3(0.23694, 0.10992, 0.95264),
        ])
    }

    @Test func `a graded HaldCLUT imports as before`() throws {
        expect(try LookTableImport.parseHald(LookTableFixtures.gradedHald()), size: 16, mean: 0.562847, samples: [
            SIMD3(0.21191, 0.63794, 0.38269), SIMD3(0.36012, 0.48301, 0.77471), SIMD3(0.76562, 0.19946, 0.78467),
            SIMD3(0.00000, 0.78760, 0.62000), SIMD3(0.91797, 0.89990, 0.48779), SIMD3(0.23694, 0.10992, 0.95264),
        ])
        let native = try LookTableImport.parseHald(LookTableFixtures.gradedHald(), space: .displayRec2020)
        expect(native, size: 16, mean: 0.542789, samples: [
            SIMD3(0.06000, 0.65552, 0.38000), SIMD3(0.14822, 0.49235, 0.80181), SIMD3(0.62598, 0.39771, 0.79980),
            SIMD3(0.05302, 0.81885, 0.58484), SIMD3(0.95020, 0.89990, 0.39990), SIMD3(0.05002, 0.00000, 1.00000),
        ])
    }
}
