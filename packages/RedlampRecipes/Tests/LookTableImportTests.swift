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

    /// Lustre's 10-bit input mesh: `0 64 … 960 1023` for 17 points.
    static func lustreMesh(size: Int) -> [Int] {
        (0 ..< size).map { min($0 * 1024 / (size - 1), 1023) }
    }

    /// A `.3dl` sampled at its mesh points, blue varying fastest, with `bits`-bit output.
    static func threeDL(
        size: Int,
        bits: Int = 12,
        header: [String] = [],
        _ transform: (SIMD3<Float>) -> SIMD3<Float>,
    ) -> String {
        let mesh = lustreMesh(size: size)
        let top = Float(mesh[size - 1])
        let scale = Float((1 << bits) - 1)
        var lines = header + [mesh.map(String.init).joined(separator: " ")]
        for r in 0 ..< size {
            for g in 0 ..< size {
                for b in 0 ..< size {
                    let input = SIMD3(Float(mesh[r]), Float(mesh[g]), Float(mesh[b])) / top
                    let v = (simd_clamp(transform(input), .zero, SIMD3(repeating: 1)) * scale)
                        .rounded(.toNearestOrAwayFromZero)
                    lines.append("\(Int(v.x)) \(Int(v.y)) \(Int(v.z))")
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

struct ThreeDLImportTests {
    /// Written out by hand from the format: rows run with blue fastest and red slowest, and
    /// every corner's output mixes channels, so reading them in another order moves values.
    static let corners = """
    # Lustre 3D LUT
    0 1023
    100 200 300
    1100 200 2300
    100 3200 1000
    1100 3200 3000
    2100 700 300
    3100 700 2300
    2100 3700 1000
    3100 3700 3000
    """

    static func cornerOutput(r: Int, g: Int, b: Int) -> SIMD3<Float> {
        SIMD3(Float(2000 * r + 1000 * b + 100), Float(3000 * g + 500 * r + 200), Float(2000 * b + 700 * g + 300)) / 4095
    }

    @Test func `rows run with blue fastest and red slowest`() throws {
        let table = try LookTableImport.parse3DL(Self.corners, space: .displayRec2020)
        for r in 0 ... 1 {
            for g in 0 ... 1 {
                for b in 0 ... 1 {
                    let corner = SIMD3(Float(r), Float(g), Float(b))
                    #expect(simd_distance(table.sample(corner), Self.cornerOutput(r: r, g: g, b: b)) < 1e-3)
                }
            }
        }
    }

    @Test func `a .3dl imports like a .cube of the same grade`() throws {
        let threeDL = LookTableFixtures.threeDL(size: 17, LookTableFixtures.grade)
        // A .3dl's integers stop at white.
        let cube = LookTableFixtures
            .cube(size: 17) { simd_clamp(LookTableFixtures.grade($0), .zero, SIMD3(repeating: 1)) }
        for space in [ImportedTableSpace.displayRec2020, .sRGB] {
            let a = try LookTableImport.parse3DL(threeDL, space: space)
            let b = try LookTableImport.parseCube(cube, space: space).table
            #expect(a.size == b.size && a.space == b.space)
            let worst = zip(a.values, b.values).map { abs(Float($0) - Float($1)) }.max() ?? 0
            #expect(worst < 3e-3, "\(space): \(worst)")
        }
    }

    @Test(arguments: [17, 33, 65])
    func `the common mesh sizes import, stored at up to 33 points`(size: Int) throws {
        let table = try LookTableImport.parse3DL(LookTableFixtures.threeDL(size: size) { $0 }, space: .displayRec2020)
        #expect(table.size == min(size, LookTableImport.storedSize))
        #expect(table.isIdentity)
    }

    @Test(arguments: [10, 12, 16])
    func `the output bit depth comes from the largest value`(bits: Int) throws {
        let text = LookTableFixtures.threeDL(size: 17, bits: bits) { $0 }
        #expect(try LookTableImport.parse3DL(text, space: .displayRec2020).isIdentity)
    }

    @Test func `a Mesh header gives the output bit depth`() throws {
        // Every value is 1000: white in a 10-bit file, a dark grey in a 12-bit one.
        let dark = LookTableFixtures.threeDL(size: 17, bits: 12) { _ in SIMD3(repeating: 1000 / 4095) }
        let inferred = try LookTableImport.parse3DL(dark, space: .displayRec2020)
        #expect(abs(inferred.sample(SIMD3(repeating: 0.5)).x - 1000 / 1023) < 1e-3)
        let flame = "3DMESH\nMesh 4 12\n\(dark)\nLUT8\ngamma 1.0\n"
        let declared = try LookTableImport.parse3DL(flame, space: .displayRec2020)
        #expect(abs(declared.sample(SIMD3(repeating: 0.5)).x - 1000 / 4095) < 1e-3)
    }

    @Test func `an identity stays an identity through the sRGB conversion`() throws {
        let table = try LookTableImport.parse3DL(LookTableFixtures.threeDL(size: 17) { $0 })
        for probe in [SIMD3<Float>(0.4, 0.5, 0.6), SIMD3(0.1, 0.2, 0.9), SIMD3(0.9, 0.9, 0.9)] {
            #expect(simd_distance(table.sample(probe), probe) < 5e-3)
        }
    }

    @Test func `bad files are rejected with the reason`() {
        let rows = String(repeating: "0 0 0\n", count: 8)
        let cases: [(String, String)] = [
            ("", "no line of input mesh points"),
            ("# just a comment\n3DMESH\n", "no line of input mesh points"),
            ("0 512 1023\n0 0 0\n", "expected 27 rows, found 1"),
            ("1023 0\n" + rows, "the input mesh points must increase"),
            ("0 1023\n0 0\n" + rows, "a row isn't three whole numbers"),
            ("0 1023\n0.5 0 0\n" + rows, "a row isn't three whole numbers"),
            ("0 1023\n" + rows.replacingOccurrences(of: "0 0 0", with: "0 -4 0"), "values can't be negative"),
            ("0 1023\n70000 0 0\n" + rows.dropFirst(6), "values above 65535 aren't 10, 12 or 16-bit"),
            ("Mesh 4 12\n0 1023\n" + rows, "the Mesh line gives 17 points, but the mesh has 2"),
            ("Mesh 0 10\n0 1023\n2000 0 0\n" + rows.dropFirst(6), "a value exceeds the Mesh line's 10 bits"),
            ("Mesh 4\n0 1023\n" + rows, "a Mesh line gives the mesh size and output bits, as in Mesh 4 12"),
        ]
        for (text, reason) in cases {
            #expect(throws: LookTableImportError.notA3DL(reason), "\(reason)") { try LookTableImport.parse3DL(text) }
        }
        let wide = (0 ..< 66).map(String.init).joined(separator: " ")
        #expect(throws: LookTableImportError.unsupportedSize(66)) { try LookTableImport.parse3DL(wide) }
    }

    @Test func `a .3dl becomes a recipe that carries its table`() throws {
        let table = try LookTableImport.parse3DL(LookTableFixtures.threeDL(size: 17, LookTableFixtures.grade))
        let recipe = LookTableImport.recipe(for: table, name: "Lustre Grade")
        let (decoded, issues) = try RecipeValidator.decode(RecipeFile.encode(recipe))
        #expect(issues.isEmpty)
        #expect(try decoded.embeddedBaseLooks.first?.definition().table == table)
    }
}
