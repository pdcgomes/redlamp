import Compression
import Foundation

/// The XMP a Lightroom Classic catalog keeps for each photo (`Adobe_AdditionalMetadata.xmp`), read for the
/// fields its own tables don't hold (LIB-29): the title, the creators and the location, with the caption and
/// the copyright notice. The catalog stores it as text, or compressed with zlib behind a 4-byte length, so
/// both are read.
enum LightroomXMP {
    enum Read: Sendable {
        case fields(XMPFields)
        /// It names none of the fields.
        case nothing
        case unreadable
    }

    /// The elements of the fields read, as Lightroom writes them; a packet naming none of them isn't parsed.
    private static let markers: [[UInt8]] = [
        "dc:title", "dc:creator", "dc:description", "dc:rights", "Iptc4xmpCore:Location", "photoshop:City",
        "photoshop:State", "photoshop:Country", "Iptc4xmpCore:CountryCode",
    ].map { Array($0.utf8) }

    static func read(_ data: Data) -> Read {
        guard let packet = text(of: data) else { return .unreadable }
        let named = packet.withUnsafeBytes { bytes in
            markers.contains { marker in
                marker.withUnsafeBytes { memmem(bytes.baseAddress, bytes.count, $0.baseAddress, $0.count) != nil }
            }
        }
        guard named else { return .nothing }
        guard let source = XMPSource(xmp: packet) else { return .unreadable }
        return .fields(source.fields)
    }

    /// The packet's text: `data` itself when it's text, else what zlib's stream in it holds.
    static func text(of data: Data) -> Data? {
        guard let first = data.first(where: { !(0x09 ... 0x0D).contains($0) && $0 != 0x20 && $0 != 0xEF
                && $0 != 0xBB && $0 != 0xBF
        })
        else { return nil }
        if first == UInt8(ascii: "<") {
            return data
        }
        for start in [4, 0, 8] where start + 2 < data.count {
            let header = data.index(data.startIndex, offsetBy: start)
            let method = data[header]
            let flags = data[data.index(after: header)]
            guard method & 0x0F == 8, (UInt16(method) << 8 | UInt16(flags)) % 31 == 0 else { continue }
            let deflated = data[data.index(header, offsetBy: 2)...]
            if let inflated = inflate(Data(deflated), expected: start >= 4 ? length(data) : nil),
               inflated.first(where: { $0 > 0x20 }) == UInt8(ascii: "<") {
                return inflated
            }
        }
        return nil
    }

    /// The uncompressed length a 4-byte prefix gives, read in whichever order gives a likely size.
    private static func length(_ data: Data) -> Int? {
        let bytes = Array(data.prefix(4))
        guard bytes.count == 4 else { return nil }
        let big = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        let little = Int(bytes[3]) << 24 | Int(bytes[2]) << 16 | Int(bytes[1]) << 8 | Int(bytes[0])
        return [big, little].filter { $0 > 0 && $0 <= maximum }.min()
    }

    /// Packets are kilobytes; anything past this isn't one.
    private static let maximum = 64 << 20

    /// The deflate stream inflated, into `expected` bytes when that's known, else into ever larger buffers.
    private static func inflate(_ deflated: Data, expected: Int?) -> Data? {
        var capacity = expected ?? max(deflated.count * 8, 4096)
        while capacity <= maximum {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination in
                deflated.withUnsafeBytes { source in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!, deflated.count, nil, COMPRESSION_ZLIB,
                    )
                }
            }
            if written == 0 {
                return nil
            }
            if written < capacity || expected != nil {
                output.count = written
                return output
            }
            capacity *= 4
        }
        return nil
    }
}
