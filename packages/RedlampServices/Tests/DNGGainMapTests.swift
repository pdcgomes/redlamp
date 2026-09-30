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
