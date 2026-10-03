import Foundation
import Testing
@testable import RedlampServices

/// DNG OpcodeList2 gain maps (CAM-03).
struct DNGGainMapTests {
    private func bigEndian(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private func bigEndian(_ value: Double) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.bigEndian) { Array($0) }
    }

    private func bigEndian(_ value: Float) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.bigEndian) { Array($0) }
    }

    @Test func `parses a gain map and skips other opcodes`() {
        var body: [UInt8] = []
        for value: UInt32 in [0, 1, 100, 200, 0, 1, 2, 2, 2, 3] {
            body += bigEndian(value)
        }
        for value in [1.0, 0.5, 0, 0] {
            body += bigEndian(value)
        }
        body += bigEndian(UInt32(1))
        for gain: Float in [1, 1.5, 2, 1.1, 1.6, 2.1] {
            body += bigEndian(gain)
        }
        let other: [UInt8] = bigEndian(UInt32(1)) + bigEndian(UInt32(0x0103_0000)) + bigEndian(UInt32(0))
            + bigEndian(UInt32(4)) + [0, 0, 0, 0]
        let gainMap = bigEndian(DNGGainMaps.gainMapOpcode) + bigEndian(UInt32(0x0103_0000)) + bigEndian(UInt32(0))
            + bigEndian(UInt32(body.count)) + body
        let list = bigEndian(UInt32(2)) + other + gainMap
        let maps = list.withUnsafeBytes { DNGGainMaps.parse($0) }
        #expect(maps.count == 1)
        let map = maps[0]
        #expect(map.left == 1 && map.bottom == 100 && map.right == 200 && map.rowPitch == 2)
        #expect(map.pointsV == 2 && map.pointsH == 3 && map.spacingH == 0.5)
        #expect(map.gains == [1, 1.5, 2, 1.1, 1.6, 2.1])
    }

    /// A valid map's fields, for a test to damage one.
    private struct Fields {
        var area: [UInt32] = [0, 0, 100, 200]
        var planes: [UInt32] = [0, 1]
        var pitch: [UInt32] = [2, 2]
        var points: [UInt32] = [2, 3]
        var placement = [1.0, 0.5, 0, 0]
        var mapPlanes: UInt32 = 1
        var gains: [Float] = [1, 1.5, 2, 1.1, 1.6, 2.1]
    }

    /// An opcode list holding a gain map for each of `maps`.
    private func list(_ maps: [Fields]) -> [UInt8] {
        var list = bigEndian(UInt32(maps.count))
        for map in maps {
            var body: [UInt8] = []
            for value in map.area + map.planes + map.pitch + map.points {
                body += bigEndian(value)
            }
            for value in map.placement {
                body += bigEndian(value)
            }
            body += bigEndian(map.mapPlanes)
            for gain in map.gains {
                body += bigEndian(gain)
            }
            list += bigEndian(DNGGainMaps.gainMapOpcode) + bigEndian(UInt32(0x0103_0000)) + bigEndian(UInt32(0))
                + bigEndian(UInt32(body.count)) + body
        }
        return list
    }

    private func parse(_ maps: [Fields]) -> [GainMap] {
        list(maps).withUnsafeBytes { DNGGainMaps.parse($0) }
    }

    /// One field damaged in an otherwise valid map.
    private static let damaged: [(String, @Sendable (inout Fields) -> Void)] = [
        ("top below bottom", { $0.area = [200, 0, 100, 200] }),
        ("left right of right", { $0.area = [0, 300, 100, 200] }),
        ("origin V NaN", { $0.placement[2] = .nan }),
        ("origin H infinite", { $0.placement[3] = .infinity }),
        ("origin V minus infinity", { $0.placement[2] = -.infinity }),
        ("spacing NaN", { $0.placement[0] = .nan }),
        ("a grid whose size overflows", { $0.points = [0xFFFF_FFFF, 0xFFFF_FFFF] }),
        ("top past 32 bits", { $0.area = [0x8000_0000, 0, 0x8000_0001, 200] }),
        ("row pitch past 32 bits", { $0.pitch = [0x8000_0000, 2] }),
        ("plane past 32 bits", { $0.planes = [0x8000_0000, 1] }),
    ]

    @Test(arguments: damaged.indices)
    func `a damaged map drops the photo's whole set`(index: Int) {
        let (name, damage) = Self.damaged[index]
        var bad = Fields()
        damage(&bad)
        #expect(parse([bad]).isEmpty, "\(name)")
        #expect(parse([Fields(), bad]).isEmpty, "\(name), after a valid one")
    }

    @Test func `an empty area is valid and never applies`() throws {
        var empty = Fields()
        empty.area = [100, 0, 100, 200]
        let map = try #require(parse([empty]).first)
        #expect(map.isValid)
        #expect(map.gain(x: 0, y: 100, plane: 0, width: 200, height: 200) == nil)
    }

    @Test func `an invalid map gives no gain and doesn't decode`() throws {
        let valid = try #require(parse([Fields()]).first)
        var invalid = valid
        invalid.top = 200
        invalid.rowPitch = 0
        #expect(!invalid.isValid)
        #expect(invalid.gain(x: 0, y: 0, plane: 0, width: 200, height: 200) == nil)
        var short = valid
        short.gains.removeLast()
        #expect(short.gain(x: 199, y: 98, plane: 0, width: 200, height: 200) == nil)

        let decoded = try JSONDecoder().decode(GainMap.self, from: JSONEncoder().encode(valid))
        #expect(decoded == valid)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GainMap.self, from: JSONEncoder().encode(invalid))
        }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(GainMap.self, from: JSONEncoder().encode(short))
        }
    }

    @Test(.enabled(if: DecodeRegressionTests.fixtures.contains { $0.lastPathComponent.hasPrefix("PXL_") }))
    func `reads the Pixel's lens shading`() throws {
        let url = try #require(DecodeRegressionTests.fixtures.first { $0.lastPathComponent.hasPrefix("PXL_") })
        let decoded = try ImageDecoder.decode(url)
        #expect(decoded.gainMaps.count == 4)
        for map in decoded.gainMaps {
            #expect(map.rowPitch == 2 && map.columnPitch == 2 && map.pointsV == 30 && map.pointsH == 40)
            #expect(map.gains[0] > 3 && map.gains[15 * 40 + 20] < 1.1, "corner \(map.gains[0])")
        }
    }
}
