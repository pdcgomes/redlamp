import Foundation

/// A record in a shard's pack (`RLPS`, version 1). A pack is a 16-byte header (`RLPS`, the version,
/// and a generation chosen whenever the file is written whole), then records, each starting at a
/// multiple of 8 so the shard's table can hold its offset in 32 bits:
///
/// | Offset | Bytes | Field |
/// | --- | --- | --- |
/// | 0 | 4 | the record's length: header, payload and padding |
/// | 4 | 1 | tier: 0 grid, 1 preview |
/// | 5 | 1 | flags: 1 removes rather than stores; 2 (with 1) removes every tier and edit of the key |
/// | 6 | 1 | padding after the payload, 0 to 7 bytes |
/// | 7 | 1 | 0 |
/// | 8 | 16 | content key |
/// | 24 | 16 | edit digest, zero for the unedited photo |
/// | 40 | 8 | the photo file's size |
/// | 48 | 8 | its modification date, seconds since 2001 (a `Double`'s bits) |
/// | 56 | 4 | checksum of the payload |
/// | 60 | 4 | checksum of bytes 0 to 59 |
/// | 64 | | payload (HEIC or JPEG), then the padding's zeros |
///
/// Numbers are little-endian. The last record for a key, tier and edit wins, and a removal hides
/// what came before it. A torn write fails its checksums: its record is never trusted.
enum StoreRecord {
    static let headerLength = 64
    static let alignment = 8
    static let removes: UInt8 = 1
    static let everyVariant: UInt8 = 2

    struct Header: Equatable {
        var length: Int
        var tier: PhotoStore.Tier
        var flags: UInt8
        var padding: Int
        var key: StoreKey
        var edit: EditDigest
        var size: Int64
        var modified: Double
        var payloadChecksum: UInt32

        var payloadLength: Int {
            length - StoreRecord.headerLength - padding
        }

        var isRemoval: Bool {
            flags & StoreRecord.removes != 0
        }

        var removesEveryVariant: Bool {
            flags & StoreRecord.everyVariant != 0
        }

        var variant: UInt32 {
            StoreEntry.variant(tier, edit)
        }

        /// Whether the record is of `photo`'s file as it is now.
        func matches(size: Int64, modified: Date) -> Bool {
            self.size == size && abs(self.modified - modified.timeIntervalSinceReferenceDate) < 0.001
        }
    }

    /// Records to append in one write, in order.
    struct Batch {
        private(set) var bytes = Data()
        private(set) var headers: [Header] = []

        init() {}

        init(_ record: (bytes: Data, header: Header)) {
            bytes = record.bytes
            headers = [record.header]
        }

        var isEmpty: Bool {
            headers.isEmpty
        }

        mutating func append(_ record: (bytes: Data, header: Header)) {
            bytes.append(record.bytes)
            headers.append(record.header)
        }
    }

    /// What a record a shard's table found holds.
    enum Reading {
        /// The record, with its payload when it was asked for.
        case found(Data?)
        /// A record of another file (its size or date differ), or of another edit.
        case none
        /// A record whose checksums fail, or that isn't what its entry says it is.
        case damaged
    }

    /// The record `lookup` found, if it's of `key`'s `tier` and `edit` (and of `file`, when given).
    /// The payload is checked against its checksum and copied out of the mapping, so it outlives a
    /// compaction.
    static func read(
        _ lookup: StoreLookup, key: StoreKey, tier: PhotoStore.Tier, edit: EditDigest,
        file: (size: Int64, modified: Date)?, payload: Bool,
    ) -> Reading {
        withExtendedLifetime(lookup.mapping) {
            let bytes = lookup.mapping.bytes
            let entry = lookup.entry
            guard let header = header(in: bytes, at: entry.offset), header.length == Int(entry.length),
                  header.key == key, header.tier == tier, !header.isRemoval
            else { return .damaged }
            guard header.edit == edit, file.map({ header.matches(size: $0.size, modified: $0.modified) }) ?? true
            else { return .none }
            guard payload else { return .found(nil) }
            let stored = self.payload(in: bytes, at: entry.offset, header: header)
            guard StoreChecksum.of(stored) == header.payloadChecksum, let base = stored.baseAddress else {
                return .damaged
            }
            return .found(Data(bytes: base, count: stored.count))
        }
    }

    /// A record storing `payload`.
    static func encode(
        _ payload: Data, key: StoreKey, tier: PhotoStore.Tier, edit: EditDigest, size: Int64, modified: Date,
    ) -> (bytes: Data, header: Header)? {
        let unpadded = headerLength + payload.count
        let length = (unpadded + alignment - 1) / alignment * alignment
        guard length <= Int(UInt32.max) else { return nil }
        var header = Header(
            length: length, tier: tier, flags: 0, padding: length - unpadded, key: key, edit: edit, size: size,
            modified: modified.timeIntervalSinceReferenceDate, payloadChecksum: 0,
        )
        var bytes = Data(count: length)
        bytes.withUnsafeMutableBytes { buffer in
            payload.withUnsafeBytes { source in
                header.payloadChecksum = StoreChecksum.of(source)
                if let base = source.baseAddress {
                    (buffer.baseAddress! + headerLength).copyMemory(from: base, byteCount: source.count)
                }
            }
            write(header, into: buffer)
        }
        return (bytes, header)
    }

    /// A record removing the key's `tier` and `edit`, or with neither, everything of the key's.
    static func removal(
        of key: StoreKey, tier: PhotoStore.Tier? = nil, edit: EditDigest = .unedited,
    ) -> (bytes: Data, header: Header) {
        let header = Header(
            length: headerLength, tier: tier ?? .grid, flags: removes | (tier == nil ? everyVariant : 0), padding: 0,
            key: key, edit: edit, size: 0, modified: 0, payloadChecksum: StoreChecksum.of(UnsafeRawBufferPointer(
                start: nil, count: 0,
            )),
        )
        var bytes = Data(count: headerLength)
        bytes.withUnsafeMutableBytes { write(header, into: $0) }
        return (bytes, header)
    }

    private static func write(_ header: Header, into buffer: UnsafeMutableRawBufferPointer) {
        buffer.storeBytes(of: UInt32(header.length).littleEndian, toByteOffset: 0, as: UInt32.self)
        buffer.storeBytes(of: header.tier.rawValue, toByteOffset: 4, as: UInt8.self)
        buffer.storeBytes(of: header.flags, toByteOffset: 5, as: UInt8.self)
        buffer.storeBytes(of: UInt8(header.padding), toByteOffset: 6, as: UInt8.self)
        buffer.storeBytes(of: 0, toByteOffset: 7, as: UInt8.self)
        buffer.storeBytes(of: header.key.high.bigEndian, toByteOffset: 8, as: UInt64.self)
        buffer.storeBytes(of: header.key.low.bigEndian, toByteOffset: 16, as: UInt64.self)
        buffer.storeBytes(of: header.edit.high.bigEndian, toByteOffset: 24, as: UInt64.self)
        buffer.storeBytes(of: header.edit.low.bigEndian, toByteOffset: 32, as: UInt64.self)
        buffer.storeBytes(of: header.size.littleEndian, toByteOffset: 40, as: Int64.self)
        buffer.storeBytes(of: header.modified.bitPattern.littleEndian, toByteOffset: 48, as: UInt64.self)
        buffer.storeBytes(of: header.payloadChecksum.littleEndian, toByteOffset: 56, as: UInt32.self)
        let checksum = StoreChecksum.of(UnsafeRawBufferPointer(rebasing: buffer[0 ..< 60]))
        buffer.storeBytes(of: checksum.littleEndian, toByteOffset: 60, as: UInt32.self)
    }

    /// The header of the record at `offset`, if one is there whole: its checksum holds, and it ends
    /// inside `bytes`.
    static func header(in bytes: UnsafeRawBufferPointer, at offset: Int) -> Header? {
        guard offset >= 0, offset % alignment == 0, offset + headerLength <= bytes.count else { return nil }
        func load<T: FixedWidthInteger>(_ at: Int, _: T.Type) -> T {
            T(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + at, as: T.self))
        }
        func loadBig(_ at: Int) -> UInt64 {
            UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: offset + at, as: UInt64.self))
        }
        let length = Int(load(0, UInt32.self))
        let flags = load(5, UInt8.self)
        let padding = Int(load(6, UInt8.self))
        guard length >= headerLength, length % alignment == 0, offset + length <= bytes.count,
              let tier = PhotoStore.Tier(rawValue: load(4, UInt8.self)), padding < alignment,
              length - headerLength >= padding, load(7, UInt8.self) == 0,
              flags & ~(removes | everyVariant) == 0, flags & everyVariant == 0 || flags & removes != 0,
              flags & removes == 0 || length == headerLength,
              load(60, UInt32.self) == StoreChecksum.of(UnsafeRawBufferPointer(
                  rebasing: bytes[offset ..< offset + 60],
              ))
        else { return nil }
        return Header(
            length: length, tier: tier, flags: flags, padding: padding, key: StoreKey(
                high: loadBig(8),
                low: loadBig(16),
            ),
            edit: EditDigest(high: loadBig(24), low: loadBig(32)), size: load(40, Int64.self),
            modified: Double(bitPattern: load(48, UInt64.self)), payloadChecksum: load(56, UInt32.self),
        )
    }

    /// The payload of the record at `offset`, whose header is `header`.
    static func payload(in bytes: UnsafeRawBufferPointer, at offset: Int, header: Header) -> UnsafeRawBufferPointer {
        let start = offset + headerLength
        return UnsafeRawBufferPointer(rebasing: bytes[start ..< start + header.payloadLength])
    }
}

/// A 32-bit checksum over little-endian words, four lanes at once: it tells a torn, zeroed or
/// misplaced write, not a forged one.
enum StoreChecksum {
    static func of(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        let count = bytes.count
        var a: UInt64 = 0x9E37_79B9_7F4A_7C15
        var b: UInt64 = 0xC2B2_AE3D_27D4_EB4F
        var c: UInt64 = 0x1656_67B1_9E37_79F9
        var d: UInt64 = 0x27D4_EB2F_1656_67C5
        var offset = 0
        while offset + 32 <= count {
            a = mix(a ^ word(bytes, offset))
            b = mix(b ^ word(bytes, offset + 8))
            c = mix(c ^ word(bytes, offset + 16))
            d = mix(d ^ word(bytes, offset + 24))
            offset += 32
        }
        var hash = UInt64(count) ^ a ^ (b << 17 | b >> 47) ^ (c << 31 | c >> 33) ^ (d << 47 | d >> 17)
        while offset + 8 <= count {
            hash = mix(hash ^ word(bytes, offset))
            offset += 8
        }
        var tail: UInt64 = 0
        while offset < count {
            tail = tail << 8 | UInt64(bytes[offset])
            offset += 1
        }
        hash = mix(mix(hash ^ tail))
        return UInt32(truncatingIfNeeded: hash ^ hash >> 32)
    }

    @inline(__always)
    private static func word(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
        UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    @inline(__always)
    private static func mix(_ value: UInt64) -> UInt64 {
        let product = value &* 0xBF58_476D_1CE4_E5B9
        return product ^ product >> 31
    }
}
