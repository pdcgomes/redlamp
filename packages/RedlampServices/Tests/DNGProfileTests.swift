import Foundation
import Testing
@testable import RedlampServices

/// DNG camera profile tables and tone curves (TON-09).
struct DNGProfileTests {
    private static func fixture(_ prefix: String) -> URL? {
        DecodeRegressionTests.fixtures.first { $0.lastPathComponent.hasPrefix(prefix) }
    }

    @Test(.enabled(if: fixture("PXL_") != nil))
    func `reads the Pixel's embedded Adobe Standard`() throws {
        let url = try #require(Self.fixture("PXL_"))
        let profile = try #require(DNGProfile.read(url))
        #expect(profile.name == "Adobe Standard")
        #expect(profile.cameraModel == "Google Pixel 4a")
        #expect(profile.embedPolicy == 0)
        let sizes: [[Int]] = profile.hueSatMaps.map { [$0.hues, $0.saturations, $0.values] }
        #expect(sizes == [[90, 30, 1], [90, 30, 1]])
        #expect(profile.hueSatMaps[0] != profile.hueSatMaps[1])
        let look = try #require(profile.lookTable)
        let size: [Int] = [look.hues, look.saturations, look.values]
        #expect(size == [36, 8, 16])
        #expect(profile.toneCurve == nil)
    }

    @Test(.enabled(if: fixture("IMG_1361") != nil))
    func `reads an iPhone's embedded tone curve`() throws {
        let url = try #require(Self.fixture("IMG_1361"))
        let profile = try #require(DNGProfile.read(url))
        #expect(profile.name == "Apple Embedded Color Profile")
        #expect(profile.hueSatMaps.isEmpty && profile.lookTable == nil)
        let curve = try #require(profile.toneCurve)
        #expect(curve.count == 257)
        #expect(curve.first == SIMD2<Float>(0, 0))
        #expect(curve.last == SIMD2<Float>(1, 1))
    }

    @Test func `reads a .dcp file`() throws {
        let entries = Array(repeating: Float(0), count: 4 * 2 * 1 * 3)
        let data = Self.profileFile(name: "Test", dims: [4, 2, 1], entries: entries)
        let profile = try #require(DNGProfile.read(data, url: URL(fileURLWithPath: "/tmp/test.dcp")))
        #expect(profile.name == "Test")
        #expect(profile.hueSatMaps.count == 1)
        #expect(profile.hueSatMaps[0].entries == entries)
    }

    @Test func `drops a map whose data doesn't match its size`() {
        let data = Self.profileFile(name: "Test", dims: [4, 2, 1], entries: [0, 1, 2])
        #expect(DNGProfile.read(data, url: URL(fileURLWithPath: "/tmp/test.dcp")) == nil)
    }

    /// A little-endian DCP with ProfileName, ProfileHueSatMapDims and ProfileHueSatMapData1.
    private static func profileFile(name: String, dims: [UInt32], entries: [Float]) -> Data {
        var data = Data("IIRC".utf8)
        func append(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(8))
        let tagCount = 3
        let values = 8 + 2 + tagCount * 12 + 4
        var payload = Data(name.utf8) + [0]
        let dimsOffset = values + payload.count
        for dim in dims {
            withUnsafeBytes(of: dim.littleEndian) { payload.append(contentsOf: $0) }
        }
        let entriesOffset = values + payload.count
        for entry in entries {
            withUnsafeBytes(of: entry.bitPattern.littleEndian) { payload.append(contentsOf: $0) }
        }
        append(UInt16(tagCount))
        for (tag, type, count, offset): (UInt16, UInt16, Int, Int) in [
            (0xC6F8, 2, name.utf8.count + 1, values), (0xC6F9, 4, dims.count, dimsOffset),
            (0xC6FA, 11, entries.count, entriesOffset),
        ] {
            append(tag)
            append(type)
            append(UInt32(count))
            append(UInt32(offset))
        }
        append(UInt32(0))
        return data + payload
    }
}
