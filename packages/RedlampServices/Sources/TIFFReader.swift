import Foundation

/// Reads tags from TIFF-based files (DNG, and DNG camera profiles, whose magic is "RC" rather
/// than 42) for the few things LibRaw doesn't expose.
struct TIFFReader {
    let bytes: UnsafeRawBufferPointer
    let littleEndian: Bool

    static let subIFDsTag: UInt16 = 330
    static let shortType: UInt16 = 3
    static let longType: UInt16 = 4
    static let doubleType: UInt16 = 12
    static let ifdType: UInt16 = 13
    static let floatType: UInt16 = 11
    static let profileMagic: UInt16 = 0x4352

    struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: Int
        /// Where the value (≤ 4 bytes) or the offset to it is stored.
        var valueOffset: Int
    }

    init?(bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= 8 else { return nil }
        self.bytes = bytes
        switch (bytes[0], bytes[1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: return nil
        }
        guard u16(2) == 42 || u16(2) == Self.profileMagic else { return nil }
    }

    /// Every image file directory: the main chain and the SubIFDs hanging off it.
    func imageFileDirectories() -> [[Entry]] {
        var directories: [[Entry]] = []
        var pending = [Int(u32(4))]
        var visited = Set<Int>()
        while let offset = pending.popLast() {
            guard offset > 0, visited.insert(offset).inserted, visited.count < 64,
                  let entries = entries(at: offset)
            else {
                continue
            }
            directories.append(entries)
            for entry in entries where entry.tag == Self.subIFDsTag {
                pending.append(contentsOf: integers(entry).prefix(16))
            }
            if let next = nextIFD(after: offset) {
                pending.append(next)
            }
        }
        return directories
    }

    /// The values of a SHORT, LONG or IFD entry; empty for other types.
    func integers(_ entry: Entry) -> [Int] {
        let size: Int
        switch entry.type {
        case Self.shortType: size = 2
        case Self.longType, Self.ifdType: size = 4
        default: return []
        }
        let start = entry.count * size <= 4 ? entry.valueOffset : Int(u32(entry.valueOffset))
        guard entry.count >= 0, start + entry.count * size <= bytes.count else { return [] }
        return (0 ..< entry.count).map { index in
            size == 2 ? Int(u16(start + index * 2)) : Int(u32(start + index * 4))
        }
    }

    /// The values of an SSHORT entry; empty for other types.
    func signedShorts(_ entry: Entry) -> [Int] {
        guard entry.type == 8, entry.count >= 0 else { return [] }
        let start = entry.count * 2 <= 4 ? entry.valueOffset : Int(u32(entry.valueOffset))
        guard start + entry.count * 2 <= bytes.count else { return [] }
        return (0 ..< entry.count).map { Int(Int16(bitPattern: u16(start + $0 * 2))) }
    }

    /// The values of a FLOAT or DOUBLE entry; empty for other types.
    func floats(_ entry: Entry) -> [Float] {
        let size: Int
        switch entry.type {
        case Self.floatType: size = 4
        case Self.doubleType: size = 8
        default: return []
        }
        let start = entry.count * size <= 4 ? entry.valueOffset : Int(u32(entry.valueOffset))
        guard entry.count >= 0, start + entry.count * size <= bytes.count else { return [] }
        return (0 ..< entry.count).map { index in
            size == 4 ? Float(bitPattern: u32(start + index * 4)) : Float(f64(start + index * 8))
        }
    }

    /// An ASCII or BYTE (UTF-8) entry's text, up to its first NUL.
    func string(_ entry: Entry) -> String? {
        guard [1, 2, 7].contains(entry.type), entry.count > 0 else { return nil }
        let start = entry.count <= 4 ? entry.valueOffset : Int(u32(entry.valueOffset))
        guard start + entry.count <= bytes.count else { return nil }
        let text = bytes[start ..< start + entry.count].prefix { $0 != 0 }
        return String(bytes: text, encoding: .utf8).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func entries(at offset: Int) -> [Entry]? {
        guard offset + 2 <= bytes.count else { return nil }
        let count = Int(u16(offset))
        guard offset + 2 + count * 12 + 4 <= bytes.count else { return nil }
        return (0 ..< count).map { index in
            let at = offset + 2 + index * 12
            return Entry(tag: u16(at), type: u16(at + 2), count: Int(u32(at + 4)), valueOffset: at + 8)
        }
    }

    private func nextIFD(after offset: Int) -> Int? {
        let next = Int(u32(offset + 2 + Int(u16(offset)) * 12))
        return next > 0 && next < bytes.count ? next : nil
    }

    func u16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
        return littleEndian ? UInt16(littleEndian: value) : UInt16(bigEndian: value)
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        return littleEndian ? UInt32(littleEndian: value) : UInt32(bigEndian: value)
    }

    func f64(_ offset: Int) -> Double {
        guard offset + 8 <= bytes.count else { return 0 }
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        return Double(bitPattern: littleEndian ? UInt64(littleEndian: value) : UInt64(bigEndian: value))
    }

    /// The product of counts a file states, or nil if one isn't positive or the product overflows.
    static func product(_ factors: Int...) -> Int? {
        var total = 1
        for factor in factors {
            guard factor > 0 else { return nil }
            let (next, overflow) = total.multipliedReportingOverflow(by: factor)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }
}
