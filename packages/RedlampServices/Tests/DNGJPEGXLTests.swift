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

    static let rawSize = PixelSize(width: 12, height: 5)

    @Test func `decodes JPEG XL tiles and applies the linearization table`() throws {
        let url = try Self.writeDNG(photometric: 34892)
        let image = try #require(try DNGJPEGXL.decode(url, rawSize: Self.rawSize))
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
        let error = #expect(throws: EngineError.self) { try DNGJPEGXL.decode(url, rawSize: Self.rawSize) }
        #expect(error?.notSupportedYetTracker == "CAM-10")
    }

    @Test func `ignores DNGs that aren't JPEG XL`() throws {
        let url = try Self.writeDNG(photometric: 34892, compression: 7)
        #expect(try DNGJPEGXL.decode(url, rawSize: Self.rawSize) == nil)
    }

    @Test func `ignores a JPEG XL directory whose size isn't LibRaw's`() throws {
        let url = try Self.writeDNG(photometric: 34892)
        let rawSize = PixelSize(width: 6, height: 5)
        #expect(try DNGJPEGXL.decode(url, rawSize: rawSize) == nil)
    }

    /// Width, height, tile width and tile height, each with one tile.
    @Test(arguments: [[0xFFFF_FFFF, 0xFFFF_FFFF, 1, 1], [0x7FFF_FFFF, 0x7FFF_FFFF, 0x7FFF_FFFF, 0x7FFF_FFFF]])
    func `a JPEG XL directory with an impossible size isn't read`(size: [Int]) throws {
        let url = try Self.writeDNG(
            photometric: 34892, width: size[0], height: size[1], tileWidth: size[2], tileHeight: size[3], tiles: 1,
        )
        let rawSize = PixelSize(width: size[0], height: size[1])
        #expect(try DNGJPEGXL.decode(url, rawSize: rawSize) == nil)
        #expect(try DNGJPEGXL.decode(url, rawSize: Self.rawSize) == nil)
    }

    @Test func `a claimed size LibRaw doesn't share allocates nothing`() throws {
        let url = try Self.writeDNG(
            photometric: 34892, width: 20000, height: 20000, tileWidth: 20000, tileHeight: 20000, tiles: 1,
        )
        let before = Self.footprint()
        let image = try DNGJPEGXL.decode(url, rawSize: Self.rawSize)
        let growth = Self.footprint() - before
        #expect(image == nil)
        #expect(growth < 50 << 20)
    }

    @Test func `a tile larger than the DNG's tiles isn't decoded`() throws {
        let url = try Self.writeDNG(photometric: 34892, width: 6, height: 5, tileWidth: 3, tileHeight: 5, tiles: 2)
        let rawSize = PixelSize(width: 6, height: 5)
        #expect(throws: EngineError.self) { try DNGJPEGXL.decode(url, rawSize: rawSize) }
    }

    /// The process's physical footprint, as Activity Monitor's Memory column shows it.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    struct Entry {
        var tag: Int
        var type: Int
        var count: Int
        /// The value itself, or the offset to it when it doesn't fit in four bytes.
        var value: Int
    }

    /// A big-endian TIFF with one image, 12×5 made of two 6×5 copies of `tile` unless the sizes say
    /// otherwise, and the linearization table code → code · 64.
    static func writeDNG(
        photometric: Int, compression: Int = DNGJPEGXL.compression,
        width: Int = 12, height: Int = 5, tileWidth: Int = 6, tileHeight: Int = 5, tiles: Int = 2,
    ) throws -> URL {
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
        // One tile's offset and byte count fit in their entries.
        let listBytes = tiles == 1 ? 0 : tiles * 4
        let offsetsOffset = tableOffset + table.count * 2
        let countsOffset = offsetsOffset + listBytes
        let tileOffset = countsOffset + listBytes
        let entries = [
            Entry(tag: 254, type: long, count: 1, value: 0),
            Entry(tag: 256, type: long, count: 1, value: width),
            Entry(tag: 257, type: long, count: 1, value: height),
            Entry(tag: 259, type: short, count: 1, value: compression),
            Entry(tag: 262, type: short, count: 1, value: photometric),
            Entry(tag: 277, type: short, count: 1, value: photometric == 32803 ? 1 : 3),
            Entry(tag: 322, type: long, count: 1, value: tileWidth),
            Entry(tag: 323, type: long, count: 1, value: tileHeight),
            Entry(tag: 324, type: long, count: tiles, value: tiles == 1 ? tileOffset : offsetsOffset),
            Entry(tag: 325, type: long, count: tiles, value: tiles == 1 ? tile.count : countsOffset),
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
        if tiles > 1 {
            for index in 0 ..< tiles {
                append32(tileOffset + index * tile.count)
            }
            for _ in 0 ..< tiles {
                append32(tile.count)
            }
        }
        for _ in 0 ..< tiles {
            data.append(tile)
        }

        let url = FileManager.default.temporaryDirectory.appending(path: "jxl-\(UUID().uuidString).dng")
        try data.write(to: url)
        return url
    }
}
