import CryptoKit
import Foundation

/// What a photo shows, across renames, moves, copies to other drives and rebuilt indexes: the first
/// 16 bytes of SHA-256 over the file's size (8 bytes, little-endian) and its first 64 KiB, or all of
/// it when it's smaller. The store keys thumbnails and previews by it. A file rewritten in place gets
/// a new key only when its size or its first 64 KiB change.
public struct ContentKey: Sendable, Hashable, Codable, CustomStringConvertible {
    /// How much of the file the key covers.
    public static let headLength = 64 * 1024

    /// The key's bytes 0 to 7 and 8 to 15, big-endian.
    private let high: UInt64
    private let low: UInt64

    /// The key of a file of `fileSize` bytes from `head`, its first bytes: at least `headLength` of
    /// them, or the whole file. Bytes past `headLength` are ignored.
    public init(fileSize: Int, head: Data) {
        var hash = SHA256()
        withUnsafeBytes(of: UInt64(clamping: fileSize).littleEndian) { hash.update(bufferPointer: $0) }
        hash.update(data: head.prefix(Self.headLength))
        self.init(bytes: Array(hash.finalize()))
    }

    /// The key whose 16 bytes are `data`'s; nil unless it holds exactly 16.
    public init?(data: Data) {
        guard data.count == 16 else { return nil }
        self.init(bytes: Array(data))
    }

    /// The key `hex` spells, in either case; nil unless it's 32 hexadecimal digits.
    public init?(hex: String) {
        guard hex.utf8.count == 32, hex.allSatisfy(\.isHexDigit),
              let high = UInt64(hex.prefix(16), radix: 16), let low = UInt64(hex.suffix(16), radix: 16)
        else { return nil }
        self.high = high
        self.low = low
    }

    private init(bytes: [UInt8]) {
        high = bytes[0 ..< 8].reduce(0) { $0 << 8 | UInt64($1) }
        low = bytes[8 ..< 16].reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// The key's 16 bytes, as the index stores it.
    public var data: Data {
        withUnsafeBytes(of: (high.bigEndian, low.bigEndian)) { Data($0) }
    }

    /// 32 lowercase hexadecimal digits.
    public var hex: String {
        String(format: "%016llx%016llx", high, low)
    }

    public var description: String {
        hex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let key = ContentKey(hex: hex) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(hex) isn't a content key")
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
