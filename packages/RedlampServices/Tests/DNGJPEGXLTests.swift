import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampServices

struct DNGJPEGXLTests {
    /// A lossless 6×5, 16-bit RGB JPEG XL image holding `code(x, y, channel)`.
    static let tile = Data(base64Encoded: """
    AAAADEpYTCANCocKAAAAFGZ0eXBqeGwgAAAAAGp4bCAAAAAJanhsbAoAAACJanhsY/8KICD8QAIIBAEA0AFLGJOOg4NJMNLC\
    MQJ29KAYY4yIwQNiUBhjMMIYY6MjY/DAGByMkZEXCA+gBaDDNI6OzhqF2IaOKyOsZBwQQI4OCNc0AUQEQkTE9VsDPCQCAAAw\
    FQAAsTwWIbQMgFsCAADAOgUAxKQxaCBaROM5imUoANgFAA==
    """)!

    static func code(x: Int, y: Int, channel: Int) -> Int {
        (x * 97 + y * 211 + channel * 33) % 1024
    }

    @Test func `decodes JPEG XL tiles and applies the linearization table`() throws {
        let url = try Self.writeDNG(photometric: 34892)
        let image = try #require(try DNGJPEGXL.decode(url))
        #expect(image.width == 12)
        #expect(image.height == 5)
        let expected = (0 ..< 5).flatMap { y in
            (0 ..< 12).flatMap { x in
                (0 ..< 3).map { UInt16(Self.code(x: x % 6, y: y, channel: $0) * 64) }
            }
        }
        #expect(image.samples == expected)
    }

    @Test func `names JPEG XL mosaics as unsupported`() throws {
        let url = try Self.writeDNG(photometric: 32803)
        #expect(throws: EngineError.self) { try DNGJPEGXL.decode(url) }
    }

    @Test func `ignores DNGs that aren't JPEG XL`() throws {
        let url = try Self.writeDNG(photometric: 34892, compression: 7)
        #expect(try DNGJPEGXL.decode(url) == nil)
    }

    struct Entry {
        var tag: Int
        var type: Int
        var count: Int
        /// The value itself, or the offset to it when it doesn't fit in four bytes.
        var value: Int
    }

    /// A big-endian TIFF with one 12×5 image made of two copies of `tile`, and the
    /// linearization table code → code · 64.
    static func writeDNG(photometric: Int, compression: Int = DNGJPEGXL.compression) throws -> URL {
        var data = Data()
        func append16(_ value: Int) {
            data.append(contentsOf: [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
        }
        func append32(_ value: Int) {
            append16(value >> 16)
            append16(value & 0xFFFF)
        }

        let short = 3, long = 4
        let table = (0 ..< 1024).map { $0 * 64 }
        let entryCount = 12
        let tableOffset = 8 + 2 + entryCount * 12 + 4
        let offsetsOffset = tableOffset + table.count * 2
        let countsOffset = offsetsOffset + 8
        let tileOffset = countsOffset + 8
        let entries = [
            Entry(tag: 254, type: long, count: 1, value: 0),
            Entry(tag: 256, type: long, count: 1, value: 12),
            Entry(tag: 257, type: long, count: 1, value: 5),
            Entry(tag: 259, type: short, count: 1, value: compression),
            Entry(tag: 262, type: short, count: 1, value: photometric),
            Entry(tag: 277, type: short, count: 1, value: photometric == 32803 ? 1 : 3),
            Entry(tag: 322, type: long, count: 1, value: 6),
            Entry(tag: 323, type: long, count: 1, value: 5),
            Entry(tag: 324, type: long, count: 2, value: offsetsOffset),
            Entry(tag: 325, type: long, count: 2, value: countsOffset),
            Entry(tag: 50706, type: 1, count: 4, value: 0x0107_0000),
            Entry(tag: 50712, type: short, count: table.count, value: tableOffset),
        ]
        precondition(entries.count == entryCount)

        data.append(contentsOf: [0x4D, 0x4D])
        append16(42)
        append32(8)
        append16(entries.count)
        for entry in entries {
            append16(entry.tag)
            append16(entry.type)
            append32(entry.count)
            if entry.type == short, entry.count == 1 {
                append16(entry.value)
                append16(0)
            } else {
                append32(entry.value)
            }
        }
        append32(0)
        table.forEach(append16)
        append32(tileOffset)
        append32(tileOffset + tile.count)
        append32(tile.count)
        append32(tile.count)
        data.append(tile)
        data.append(tile)

        let url = FileManager.default.temporaryDirectory.appending(path: "jxl-\(UUID().uuidString).dng")
        try data.write(to: url)
        return url
    }
}
