import Foundation

/// Reads the DNG NoiseProfile tag (0xC761): per color plane, variance = S · value + O in
/// normalised units, the same model `NoiseEstimator` fits. LibRaw doesn't expose it.
enum DNGNoiseProfile {
    static func read(_ url: URL) -> NoiseModel? {
        guard url.pathExtension.lowercased() == "dng",
              let data = try? Data(contentsOf: url, options: .alwaysMapped)
        else {
            return nil
        }
        return data.withUnsafeBytes { bytes in
            TIFFReader(bytes: bytes)?.noiseProfile()
        }
    }
}

private struct TIFFReader {
    let bytes: UnsafeRawBufferPointer
    let littleEndian: Bool

    static let noiseProfileTag: UInt16 = 0xC761
    static let subIFDsTag: UInt16 = 330
    static let doubleType: UInt16 = 12
    static let longType: UInt16 = 4
    static let ifdType: UInt16 = 13

    init?(bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= 8 else { return nil }
        self.bytes = bytes
        switch (bytes[0], bytes[1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: return nil
        }
        guard u16(2) == 42 else { return nil }
    }

    func noiseProfile() -> NoiseModel? {
        var pending = [Int(u32(4))]
        var visited = Set<Int>()
        while let offset = pending.popLast() {
            guard offset > 0, visited.insert(offset).inserted, visited.count < 64,
                  let entries = entries(at: offset)
            else {
                continue
            }
            for entry in entries {
                if entry.tag == Self.noiseProfileTag, entry.type == Self.doubleType,
                   let model = model(entry) {
                    return model
                }
                if entry.tag == Self.subIFDsTag, entry.type == Self.longType || entry.type == Self.ifdType {
                    // One offset fits in the entry; several are stored elsewhere.
                    let array = entry.count == 1 ? entry.valueOffset : Int(u32(entry.valueOffset))
                    for index in 0 ..< min(entry.count, 16) {
                        pending.append(Int(u32(array + index * 4)))
                    }
                }
            }
            if let next = nextIFD(after: offset) {
                pending.append(next)
            }
        }
        return nil
    }

    private struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: Int
        /// Where the value (≤ 4 bytes) or the offset to it is stored.
        var valueOffset: Int
    }

    private func entries(at offset: Int) -> [Entry]? {
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

    private func model(_ entry: Entry) -> NoiseModel? {
        let pairs = entry.count / 2
        let start = Int(u32(entry.valueOffset))
        guard pairs >= 1, start + entry.count * 8 <= bytes.count else { return nil }
        let values = (0 ..< entry.count).map { f64(start + $0 * 8) }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        // One pair covers every plane; otherwise the first three planes are R, G, B.
        let plane = { (channel: Int) in pairs >= 3 ? channel : 0 }
        let a = SIMD3<Float>((0 ..< 3).map { Float(values[plane($0) * 2]) })
        let b = SIMD3<Float>((0 ..< 3).map { Float(values[plane($0) * 2 + 1]) })
        guard a.max() > 0 || b.max() > 0 else { return nil }
        return NoiseModel(a: a, b: b)
    }

    private func u16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
        return littleEndian ? UInt16(littleEndian: value) : UInt16(bigEndian: value)
    }

    private func u32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        return littleEndian ? UInt32(littleEndian: value) : UInt32(bigEndian: value)
    }

    private func f64(_ offset: Int) -> Double {
        guard offset + 8 <= bytes.count else { return 0 }
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        return Double(bitPattern: littleEndian ? UInt64(littleEndian: value) : UInt64(bigEndian: value))
    }
}
