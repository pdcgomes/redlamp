import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampServices

/// The lens corrections raw files carry (LNS-02).
struct LensCorrectionReaderTests {
    private static func fixture(_ prefix: String) -> URL? {
        DecodeRegressionTests.fixtures.first { $0.lastPathComponent.hasPrefix(prefix) }
    }

    private static func read(_ url: URL) throws -> LensCorrection? {
        try LensCorrectionReader.read(Data(contentsOf: url), url: url, orientation: 0)
    }

    @Test(.enabled(if: fixture("PXL_") != nil))
    func `the Pixel's identity warp is no correction`() throws {
        let url = try #require(Self.fixture("PXL_"))
        #expect(try Self.read(url) == nil)
    }

    @Test func `reads DNG warp and vignetting opcodes`() throws {
        let data = Self.dng(opcodes: Self.warp([1, -0.05, 0.01, 0], center: [0.4, 0.5]) + Self.vignette([
            0.3,
            0.1,
            0,
            0,
            0,
        ]))
        let lens = try #require(LensCorrectionReader.read(
            data,
            url: URL(fileURLWithPath: "/tmp/t.dng"),
            orientation: 0,
        ))
        #expect(lens.source == .dng && lens.center == SIMD2(0.4, 0.5))
        for r in [0.0, 0.3, 0.7, 1.0] {
            let expected = 1 - 0.05 * r * r + 0.01 * pow(r, 4)
            #expect(abs(lens.interpolate(lens.distortion, at: r).y - expected) < 2e-4, "f(\(r))")
            #expect(
                abs(lens.interpolate(lens.vignetting, at: r) - (1 + 0.3 * r * r + 0.1 * pow(r, 4))) < 2e-3,
                "g(\(r))",
            )
        }
        // A photo turned a quarter: the centre turns with it.
        let turned = try #require(LensCorrectionReader.read(
            data,
            url: URL(fileURLWithPath: "/tmp/t.dng"),
            orientation: 6,
        ))
        #expect(turned.center == SIMD2(0.5, 0.4))
    }

    /// One WarpRectilinear opcode, big-endian: one coefficient set, no tangential terms.
    private static func warp(_ k: [Double], center: [Double]) -> Data {
        var parameters = Data()
        parameters.append(be: UInt32(1))
        for value in k + [0, 0] + center {
            parameters.append(be: value.bitPattern)
        }
        return opcode(id: 1, parameters)
    }

    private static func vignette(_ k: [Double]) -> Data {
        var parameters = Data()
        for value in k + [0.5, 0.5] {
            parameters.append(be: value.bitPattern)
        }
        return opcode(id: 3, parameters)
    }

    private static func opcode(id: UInt32, _ parameters: Data) -> Data {
        var data = Data()
        data.append(be: id)
        data.append(contentsOf: [1, 3, 0, 0])
        data.append(be: UInt32(1))
        data.append(be: UInt32(parameters.count))
        return data + parameters
    }

    /// A little-endian TIFF whose only tag is OpcodeList3.
    private static func dng(opcodes: Data) -> Data {
        var list = Data()
        list.append(be: UInt32(opcodes.isEmpty ? 0 : 2))
        list += opcodes
        var data = Data("II".utf8)
        func append(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt16(42))
        append(UInt32(8))
        append(UInt16(1))
        append(UInt16(0xC74E))
        append(UInt16(7))
        append(UInt32(list.count))
        append(UInt32(8 + 2 + 12 + 4))
        append(UInt32(0))
        return data + list
    }

    @Test(.enabled(if: fixture("_DSC0009") != nil))
    func `reads Sony's correction tags`() throws {
        let url = try #require(Self.fixture("_DSC0009"))
        let lens = try #require(try Self.read(url))
        #expect(lens.source == .sony && lens.radii.count == 16)
        #expect(lens.distortion.allSatisfy { abs($0.y - 1) < 0.1 }, "distortion \(lens.distortion.map(\.y))")
        #expect(lens.vignetting.allSatisfy { $0 >= 0.99 && $0 < 4 }, "vignetting gains \(lens.vignetting)")
        #expect(try #require(lens.vignetting.last) > lens.vignetting.first!, "the corners need more light")
    }

    @Test func `files without corrections have none`() throws {
        for prefix in ["DSC_0750", "IMG_1361"] {
            guard let url = Self.fixture(prefix) else { continue }
            #expect(try Self.read(url) == nil, "\(prefix)")
        }
    }
}

private extension Data {
    mutating func append(be value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
