import Foundation
import RedlampEngineAPI
import RedlampServices
import Testing

/// Decodes every sample file in `tests/fixtures/raw` (CC0 files from raw.pixls.us) and compares
/// everything development depends on with `tests/decode/cameras.json`: layout, crop, black and
/// white levels, as-shot white balance, color matrix, orientation, baseline exposure and a
/// checksum of the sensor data.
///
/// A camera counts as supported only once it has a sample here. After an intended decoder change
/// (a LibRaw update, a fix), regenerate the file and review its diff:
/// `TEST_RUNNER_REDLAMP_UPDATE_DECODE_GOLDEN=1 mise run test`.
struct DecodeRegressionTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let goldenURL = root.appending(path: "tests/decode/cameras.json")
    static let updating = ProcessInfo.processInfo.environment["REDLAMP_UPDATE_DECODE_GOLDEN"] == "1"

    static let fixtures: [URL] = {
        let folder = root.appending(path: "tests/fixtures/raw")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter(SupportedFormats.isRaw).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    static func loadGolden() throws -> [String: DecodeSummary] {
        let data = try Data(contentsOf: goldenURL)
        return try JSONDecoder().decode([String: DecodeSummary].self, from: data)
    }

    @Test(.enabled(if: !fixtures.isEmpty && !updating), arguments: fixtures)
    func `decodes like the golden record`(url: URL) throws {
        let golden = try #require(
            try Self.loadGolden()[url.lastPathComponent],
            "no golden record for \(url.lastPathComponent); regenerate tests/decode/cameras.json",
        )
        let decoded = try DecodeSummary(ImageDecoder.decode(url))
        #expect(decoded == golden)
    }

    @Test(.enabled(if: !fixtures.isEmpty && !updating))
    func `every golden record has its sample`() throws {
        let names = Set(Self.fixtures.map(\.lastPathComponent))
        #expect(try Set(Self.loadGolden().keys).subtracting(names).isEmpty)
    }

    @Test(.enabled(if: updating))
    func `regenerate golden records`() throws {
        var golden: [String: DecodeSummary] = [:]
        for url in Self.fixtures {
            golden[url.lastPathComponent] = try DecodeSummary(ImageDecoder.decode(url))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(
            at: Self.goldenURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try encoder.encode(golden).write(to: Self.goldenURL, options: .atomic)
    }
}

/// What a decode produced, rounded so float noise doesn't matter but any real change does.
struct DecodeSummary: Codable, Equatable {
    var make: String?
    var model: String?
    var width: Int
    var height: Int
    var layout: String
    var blackLevels: [Double]
    var whiteLevel: Double
    var asShotMultipliers: [Double]
    var xyzToCamera: [Double]?
    var orientation: Int
    var baselineExposure: Double
    /// FNV-1a over every sample, so any change to the decoded sensor data shows up.
    var sampleChecksum: String

    init(_ image: DecodedImage) {
        func rounded(_ value: Double) -> Double {
            (value * 10000).rounded() / 10000
        }
        make = image.info.make
        model = image.info.model
        width = image.width
        height = image.height
        layout = switch image.layout {
        case let .mosaic(pattern): pattern.description
        case .linearRGB: "linear RGB"
        case .linearSRGBHalf: "linear sRGB half"
        }
        blackLevels = image.blackLevels.map { rounded(Double($0)) }
        whiteLevel = rounded(Double(image.whiteLevel))
        asShotMultipliers = [image.asShotMultipliers.x, image.asShotMultipliers.y, image.asShotMultipliers.z]
            .map(rounded)
        xyzToCamera = image.xyzToCamera?.map(rounded)
        orientation = image.orientation
        baselineExposure = rounded(image.baselineExposure)
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for sample in image.samples {
            hash = (hash ^ UInt64(sample & 0xFF)) &* 0x0000_0100_0000_01B3
            hash = (hash ^ UInt64(sample >> 8)) &* 0x0000_0100_0000_01B3
        }
        sampleChecksum = String(hash, radix: 16)
    }
}
