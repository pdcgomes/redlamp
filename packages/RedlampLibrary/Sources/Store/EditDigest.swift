import CryptoKit
import Foundation

/// Which edit a stored thumbnail or preview shows (LIB-17): 16 bytes, all zero for the photo as it
/// was shot. The store keeps a photo's edited images beside its unedited ones, by its content key
/// and the edit's digest.
public struct EditDigest: Sendable, Hashable, CustomStringConvertible {
    /// The photo as it was shot.
    public static let unedited = EditDigest(high: 0, low: 0)

    /// The digest's bytes 0 to 7 and 8 to 15, big-endian.
    let high: UInt64
    let low: UInt64

    init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    /// The digest whose 16 bytes are `data`'s; nil unless it holds exactly 16.
    public init?(data: Data) {
        guard data.count == 16 else { return nil }
        (high, low) = data.withUnsafeBytes { bytes in
            (
                UInt64(bigEndian: bytes.loadUnaligned(as: UInt64.self)),
                UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self)),
            )
        }
    }

    /// The first 16 bytes of SHA-256 over `data`, an edit in a form that's the same every time it's
    /// written out.
    public init(hashing data: Data) {
        let digest = SHA256.hash(data: data)
        self = digest.withUnsafeBytes { bytes in
            EditDigest(
                high: UInt64(bigEndian: bytes.loadUnaligned(as: UInt64.self)),
                low: UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self)),
            )
        }
    }

    public var isUnedited: Bool {
        high == 0 && low == 0
    }

    /// The digest's 16 bytes.
    public var data: Data {
        withUnsafeBytes(of: (high.bigEndian, low.bigEndian)) { Data($0) }
    }

    /// 32 lowercase hexadecimal digits.
    public var description: String {
        String(format: "%016llx%016llx", high, low)
    }
}

/// A content key as the store compares it: its bytes 0 to 7 and 8 to 15, big-endian. The first
/// byte picks the key's shard.
struct StoreKey: Hashable, Comparable {
    let high: UInt64
    let low: UInt64

    init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    init(_ key: ContentKey) {
        (high, low) = key.data.withUnsafeBytes { bytes in
            (
                UInt64(bigEndian: bytes.loadUnaligned(as: UInt64.self)),
                UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self)),
            )
        }
    }

    var shard: Int {
        Int(high >> 56)
    }

    var contentKey: ContentKey {
        ContentKey(data: withUnsafeBytes(of: (high.bigEndian, low.bigEndian)) { Data($0) })!
    }

    static func < (lhs: StoreKey, rhs: StoreKey) -> Bool {
        (lhs.high, lhs.low) < (rhs.high, rhs.low)
    }
}
