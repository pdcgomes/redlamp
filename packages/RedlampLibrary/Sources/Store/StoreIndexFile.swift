import Foundation

/// A shard's table as it was when last written (`RLPI`, version 1, in `<shard>.rlpi` beside its
/// pack), so opening a shard reads one small file instead of a header in every record. Only the
/// records after `covered` are read from the pack itself. The file is trusted only for the pack of
/// its generation and at least `covered` long; anything else is read from the pack.
///
/// | Offset | Bytes | Field |
/// | --- | --- | --- |
/// | 0 | 4 | `RLPI` |
/// | 4 | 4 | version |
/// | 8 | 8 | the pack's generation |
/// | 16 | 8 | how much of the pack the entries cover |
/// | 24 | 8 | bytes of that part that no entry points at |
/// | 32 | 4 | entries |
/// | 36 | 4 | when it was written, seconds since 2001 |
/// | 40 | 4 | checksum of the entries |
/// | 44 | 4 | checksum of bytes 0 to 43 |
/// | 48 | 32 each | the entries in key order: key (16, big-endian), variant, last use, offset / 8, length |
///
/// Numbers are little-endian except the keys.
enum StoreIndexFile {
    static let magic: [UInt8] = Array("RLPI".utf8)
    static let version: UInt32 = 1
    static let headerLength = 48
    static let entryLength = 32

    struct Contents {
        var table: StoreTable
        var covered: Int
        var stale: Int
        var written: UInt32
    }

    static func encode(generation: UInt64, covered: Int, stale: Int, written: UInt32, table: StoreTable) -> Data {
        var data = Data(count: headerLength + table.count * entryLength)
        data.withUnsafeMutableBytes { buffer in
            buffer.copyBytes(from: magic)
            buffer.storeBytes(of: version.littleEndian, toByteOffset: 4, as: UInt32.self)
            buffer.storeBytes(of: generation.littleEndian, toByteOffset: 8, as: UInt64.self)
            buffer.storeBytes(of: UInt64(covered).littleEndian, toByteOffset: 16, as: UInt64.self)
            buffer.storeBytes(of: UInt64(stale).littleEndian, toByteOffset: 24, as: UInt64.self)
            buffer.storeBytes(of: UInt32(table.count).littleEndian, toByteOffset: 32, as: UInt32.self)
            buffer.storeBytes(of: written.littleEndian, toByteOffset: 36, as: UInt32.self)
            var offset = headerLength
            for entry in table.entries {
                buffer.storeBytes(of: entry.high.bigEndian, toByteOffset: offset, as: UInt64.self)
                buffer.storeBytes(of: entry.low.bigEndian, toByteOffset: offset + 8, as: UInt64.self)
                buffer.storeBytes(of: entry.variant.littleEndian, toByteOffset: offset + 16, as: UInt32.self)
                buffer.storeBytes(of: entry.used.littleEndian, toByteOffset: offset + 20, as: UInt32.self)
                buffer.storeBytes(of: entry.location.littleEndian, toByteOffset: offset + 24, as: UInt32.self)
                buffer.storeBytes(of: entry.length.littleEndian, toByteOffset: offset + 28, as: UInt32.self)
                offset += entryLength
            }
            let entries = StoreChecksum.of(UnsafeRawBufferPointer(rebasing: buffer[headerLength...]))
            buffer.storeBytes(of: entries.littleEndian, toByteOffset: 40, as: UInt32.self)
            let header = StoreChecksum.of(UnsafeRawBufferPointer(rebasing: buffer[0 ..< 44]))
            buffer.storeBytes(of: header.littleEndian, toByteOffset: 44, as: UInt32.self)
        }
        return data
    }

    /// The file's entries, if it's whole and for the pack of `generation`, `packLength` long.
    static func decode(_ data: Data, generation: UInt64, packLength: Int) -> Contents? {
        data.withUnsafeBytes { bytes -> Contents? in
            guard bytes.count >= headerLength, Array(bytes.prefix(4)) == magic else { return nil }
            func load<T: FixedWidthInteger>(_ at: Int, _: T.Type) -> T {
                T(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: T.self))
            }
            let covered = Int(clamping: load(16, UInt64.self))
            let stale = Int(clamping: load(24, UInt64.self))
            let count = Int(load(32, UInt32.self))
            guard load(4, UInt32.self) == version, load(8, UInt64.self) == generation,
                  covered >= PhotoStore.packHeaderLength, covered <= packLength, stale <= covered,
                  bytes.count == headerLength + count * entryLength,
                  load(44, UInt32.self) == StoreChecksum.of(UnsafeRawBufferPointer(rebasing: bytes[0 ..< 44])),
                  load(40, UInt32.self) == StoreChecksum.of(UnsafeRawBufferPointer(rebasing: bytes[headerLength...]))
            else { return nil }
            var entries = ContiguousArray<StoreEntry>()
            entries.reserveCapacity(count)
            var offset = headerLength
            for _ in 0 ..< count {
                let entry = StoreEntry(
                    high: UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)),
                    low: UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self)),
                    variant: load(offset + 16, UInt32.self), used: load(offset + 20, UInt32.self),
                    location: load(offset + 24, UInt32.self), length: load(offset + 28, UInt32.self),
                )
                let previous = entries.last
                guard entry.offset >= PhotoStore.packHeaderLength, entry.length >= StoreRecord.headerLength,
                      Int(entry.length) % StoreRecord.alignment == 0, entry.offset + Int(entry.length) <= covered,
                      previous.map({ ($0.high, $0.low, $0.variant) < (entry.high, entry.low, entry.variant) }) ?? true
                else { return nil }
                entries.append(entry)
                offset += entryLength
            }
            return Contents(
                table: StoreTable(entries: entries), covered: covered, stale: stale, written: load(36, UInt32.self),
            )
        }
    }
}
