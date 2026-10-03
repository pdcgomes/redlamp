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
        #expect(profile.gainTableMap == nil)
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
        let map = try #require(profile.gainTableMap)
        #expect(map.rows == 6 && map.columns == 8 && map.points == 257)
        #expect(map.gains[0] > 1 && map.gains[map.points - 1] < 1, "shadows lifted, highlights held back")
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

    @Test(arguments: [1, 2])
    func `reads a profile gain table map`(version: Int) throws {
        let data = Self.profileFile(
            name: "Test", dims: [4, 2, 1], entries: Array(repeating: 0, count: 24),
            gainTableMap: Self.gainTableMap(version: version, rows: 2, columns: 3, points: 2),
        )
        let profile = try #require(DNGProfile.read(data, url: URL(fileURLWithPath: "/tmp/test.dcp")))
        let map = try #require(profile.gainTableMap)
        #expect(map.rows == 2 && map.columns == 3 && map.points == 2)
        #expect(map.gains == Array(repeating: 1, count: 12))
    }

    /// Rows, columns and points.
    @Test(arguments: [1, 2], [[UInt32.max, UInt32.max, 2], [2, 2, UInt32.max], [0, 3, 2]])
    func `a gain table map with impossible counts is dropped, and the rest of the profile read`(
        version: Int, counts: [UInt32],
    ) throws {
        let data = Self.profileFile(
            name: "Test", dims: [4, 2, 1], entries: Array(repeating: 0, count: 24),
            gainTableMap: Self.gainTableMap(version: version, rows: counts[0], columns: counts[1], points: counts[2]),
        )
        let profile = try #require(DNGProfile.read(data, url: URL(fileURLWithPath: "/tmp/test.dcp")))
        #expect(profile.name == "Test" && profile.hueSatMaps.count == 1)
        #expect(profile.gainTableMap == nil)
    }

    @Test func `an invalid gain table map isn't made, nor decoded`() throws {
        func map(rows: Int = 1, points: Int = 2, origin: Double = 0, count: Int? = nil) -> DNGProfile.GainTableMap? {
            DNGProfile.GainTableMap(
                rows: rows, columns: 1, spacing: SIMD2(1, 1), origin: SIMD2(origin, 0), points: points,
                weights: [1, 0, 0, 0, 0], gamma: 1, gains: Array(repeating: 1, count: count ?? rows * points),
            )
        }
        #expect(map() != nil)
        #expect(map(rows: Int(UInt32.max), points: Int(UInt32.max), count: 2) == nil)
        #expect(map(rows: Int.max, count: 2) == nil)
        #expect(map(origin: .nan) == nil)
        #expect(map(count: 3) == nil)

        let valid = try #require(map())
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        json["gains"] = [1, 1, 1]
        let damaged = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DNGProfile.GainTableMap.self, from: damaged) }
    }

    /// A ProfileGainTableMap (version 1, 64-byte header) or ProfileGainTableMap2 (version 2, 80
    /// bytes, float gains), big-endian, with gains of 1 for as many tables as the counts state,
    /// at most 64.
    private static func gainTableMap(version: Int, rows: UInt32, columns: UInt32, points: UInt32) -> (UInt16, Data) {
        var data = Data()
        func append(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        append(rows)
        append(columns)
        for value in [0.5, 0.5, 0, 0] {
            append(value.bitPattern)
        }
        append(points)
        for weight: Float in [1, 0, 0, 0, 0] {
            append(weight.bitPattern)
        }
        if version == 2 {
            append(UInt32(3))
            for value: Float in [1, 0, 1] {
                append(value.bitPattern)
            }
        }
        let count = min(Double(rows) * Double(columns) * Double(points), 64)
        for _ in 0 ..< Int(count) {
            append(Float(1).bitPattern)
        }
        return (version == 2 ? 0xCD40 : 0xCD2D, data)
    }

    /// A little-endian DCP with ProfileName, ProfileHueSatMapDims and ProfileHueSatMapData1, and a
    /// gain table map tag when given one.
    private static func profileFile(
        name: String, dims: [UInt32], entries: [Float], gainTableMap: (tag: UInt16, bytes: Data)? = nil,
    ) -> Data {
        var data = Data("IIRC".utf8)
        func append(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(8))
        let tagCount = gainTableMap == nil ? 3 : 4
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
        var tags: [(UInt16, UInt16, Int, Int)] = [
            (0xC6F8, 2, name.utf8.count + 1, values), (0xC6F9, 4, dims.count, dimsOffset),
            (0xC6FA, 11, entries.count, entriesOffset),
        ]
        if let gainTableMap {
            tags.append((gainTableMap.tag, 7, gainTableMap.bytes.count, values + payload.count))
            payload += gainTableMap.bytes
        }
        append(UInt16(tagCount))
        for (tag, type, count, offset) in tags {
            append(tag)
            append(type)
            append(UInt32(count))
            append(UInt32(offset))
        }
        append(UInt32(0))
        return data + payload
    }
}
