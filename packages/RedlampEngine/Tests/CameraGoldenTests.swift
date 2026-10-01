import CoreGraphics
import Foundation
import RedlampColor
import RedlampEngine
import RedlampEngineAPI
import Testing

/// Every supported camera's sample, developed at the default edit, keeps its colour: a grid of
/// patch colours (CIELAB) compared by CIEDE2000 with `tests/golden/cameras`. After an intended
/// colour change, record them again and review the diff in the commit:
/// `TEST_RUNNER_REDLAMP_UPDATE_CAMERA_GOLDEN=1 mise run test`.
struct CameraGoldenTests {
    struct Golden: Codable, Equatable {
        var width: Int
        var height: Int
        var columns: Int
        var rows: Int
        /// Patch means in L*a*b*, row-major.
        var lab: [[Double]]
    }

    static let longEdge = 512
    static let columns = 24
    static let rows = 16
    /// Mean and worst patch, in CIEDE2000.
    static let meanLimit = 0.5
    static let worstLimit = 2.0

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let folder = root.appending(path: "tests/golden/cameras")
    static let updating = ProcessInfo.processInfo.environment["REDLAMP_UPDATE_CAMERA_GOLDEN"] == "1"

    /// The supported cameras' samples: those in the decode regression record.
    static let samples: [URL] = {
        let record = root.appending(path: "tests/decode/cameras.json")
        guard let data = try? Data(contentsOf: record),
              let names = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }
        return EngineSmokeTests.fixtures.filter { names[$0.lastPathComponent] != nil }
    }()

    static func goldenURL(_ sample: URL) -> URL {
        folder.appending(path: sample.lastPathComponent + ".json")
    }

    @Test(.enabled(if: EngineSmokeTests.canRender && !updating), arguments: samples)
    func `develops in the recorded colours`(sample: URL) async throws {
        let data = try #require(
            try? Data(contentsOf: Self.goldenURL(sample)),
            "no golden for \(sample.lastPathComponent); record it",
        )
        let golden = try JSONDecoder().decode(Golden.self, from: data)
        let measured = try await Self.measure(sample)
        try #require(measured.lab.count == golden.lab.count, "the patch grid changed")
        let differences = zip(measured.lab, golden.lab).map { a, b in
            CIELab.deltaE2000(SIMD3(a[0], a[1], a[2]), SIMD3(b[0], b[1], b[2]))
        }
        let mean = differences.reduce(0, +) / Double(differences.count)
        let worst = differences.max() ?? 0
        #expect(
            mean < Self.meanLimit && worst < Self.worstLimit,
            "\(sample.lastPathComponent): mean ΔE2000 \(mean), worst \(worst)",
        )
    }

    @Test(.enabled(if: EngineSmokeTests.canRender && updating))
    func `record goldens`() async throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for sample in Self.samples {
            try await encoder.encode(Self.measure(sample)).write(to: Self.goldenURL(sample), options: .atomic)
        }
    }

    /// The default develop, exported at `longEdge`, as patch means.
    static func measure(_ sample: URL) async throws -> Golden {
        let engine = try RedlampEngine()
        _ = try await engine.open(sample)
        let image = try await engine.renderStill(StillRequest(
            recipe: EditRecipe(), maxLongEdge: longEdge, colorSpace: .sRGB, bitsPerComponent: 16, purpose: .export,
        ))
        let (width, height) = (image.width, image.height)
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 32,
                bytesPerRow: width * 16, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue,
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        var lab: [[Double]] = []
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                var sum = SIMD3<Double>.zero
                let ys = row * height / rows ..< (row + 1) * height / rows
                let xs = column * width / columns ..< (column + 1) * width / columns
                for y in ys {
                    for x in xs {
                        let index = (y * width + x) * 4
                        sum += SIMD3(Double(pixels[index]), Double(pixels[index + 1]), Double(pixels[index + 2]))
                    }
                }
                let value = CIELab.fromLinearSRGB(sum / Double(ys.count * xs.count))
                lab.append([value.x, value.y, value.z].map { ($0 * 1000).rounded() / 1000 })
            }
        }
        return Golden(width: width, height: height, columns: columns, rows: rows, lab: lab)
    }
}
