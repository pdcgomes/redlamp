import Foundation

/// What a TIFF-based file's head says of it (LIB-40): where its strips, tiles and embedded JPEG end,
/// and which raw it is. Only the directories and arrays that lie inside the head are read: IFD0 and
/// those it chains to, and their sub-IFDs, as TIFF 6.0 and DNG 1.7 lay them out.
struct TIFFHead {
    /// The furthest any strip, tile or embedded JPEG the head describes reaches; nil when it
    /// describes none it holds the offsets of.
    let dataEnd: Int64?
    /// Directories the head holds.
    let directories: Int
    let isDNG: Bool
    /// Some directory describes raw sensor data (a colour filter array or linear raw), or IFD0 has
    /// sub-IFDs, where raws keep it.
    let isRaw: Bool
    let make: String?
    /// The signature after the TIFF header: Canon's CR2, or the magic numbers Olympus and Panasonic
    /// use in TIFF's place.
    let signature: Signature

    enum Signature {
        case tiff, cr2, olympus, panasonic
    }

    /// Directories read at most, and how deep sub-IFDs go.
    private static let directoryLimit = 64
    private static let depthLimit = 4

    private enum Tag {
        static let make = 271
        static let stripOffsets = 273
        static let stripByteCounts = 279
        static let photometric = 262
        static let subIFDs = 330
        static let tileOffsets = 324
        static let tileByteCounts = 325
        static let jpegOffset = 513
        static let jpegLength = 514
        static let dngVersion = 50706
    }

    /// Nil for a head that isn't TIFF-based, or is BigTIFF or Phase One's, whose directories aren't
    /// TIFF's.
    init?(_ head: Data) {
        guard let parsed = head.withUnsafeBytes({ Self.parse($0) }) else { return nil }
        self = parsed
    }

    private init(
        dataEnd: Int64?, directories: Int, isDNG: Bool, isRaw: Bool, make: String?, signature: Signature,
    ) {
        self.dataEnd = dataEnd
        self.directories = directories
        self.isDNG = isDNG
        self.isRaw = isRaw
        self.make = make
        self.signature = signature
    }

    /// The extension a file of it takes, in small letters: `dng`, a maker's raw, or `tif` for a TIFF
    /// that holds no raw data; nil for a raw whose maker this doesn't know, or a head that holds none
    /// of its directories (Phase One's and Hasselblad's put them at the end).
    var proposedExtension: String? {
        switch signature {
        case .cr2: return "cr2"
        case .olympus: return "orf"
        case .panasonic: return "rw2"
        case .tiff: break
        }
        guard directories > 0 else { return nil }
        if isDNG {
            return "dng"
        }
        guard isRaw else { return "tif" }
        let maker = (make ?? "").lowercased()
        let makers: [(String, String)] = [
            ("nikon", "nef"), ("sony", "arw"), ("pentax", "pef"), ("ricoh", "pef"), ("samsung", "srw"),
            ("hasselblad", "3fr"), ("leaf", "mos"), ("mamiya", "mef"), ("kodak", "dcr"), ("epson", "erf"),
        ]
        return makers.first { maker.contains($0.0) }?.1
    }

    private static func parse(_ bytes: UnsafeRawBufferPointer) -> TIFFHead? {
        guard bytes.count >= 8, bytes[0] == bytes[1], bytes[0] == 0x49 || bytes[0] == 0x4D else { return nil }
        let littleEndian = bytes[0] == 0x49
        func number(at offset: Int, length: Int) -> Int? {
            guard offset >= 0, length > 0, offset + length <= bytes.count else { return nil }
            return (0 ..< length).reduce(0) { value, index in
                value << 8 | Int(bytes[offset + (littleEndian ? length - 1 - index : index)])
            }
        }
        let signature: Signature
        switch number(at: 2, length: 2) {
        case 42:
            signature = bytes.count >= 10 && bytes[8] == 0x43 && bytes[9] == 0x52 ? .cr2 : .tiff
        case 0x4F52, 0x5352: signature = .olympus
        case 0x55: signature = .panasonic
        default: return nil
        }
        guard let first = number(at: 4, length: 4) else { return nil }

        var end: Int64?
        var directories = 0
        var isDNG = false
        var isRaw = false
        var make: String?
        var visited = Set<Int>()
        var pending: [(offset: Int, depth: Int)] = [(first, 0)]
        while let (directory, depth) = pending.popLast(), visited.count < directoryLimit {
            guard directory >= 8, visited.insert(directory).inserted, let count = number(at: directory, length: 2),
                  count > 0, count <= 1000, directory + 2 + count * 12 + 4 <= bytes.count
            else { continue }
            directories += 1
            var entries: [Int: (type: Int, count: Int, field: Int)] = [:]
            for index in 0 ..< count {
                let entry = directory + 2 + index * 12
                guard let tag = number(at: entry, length: 2), let type = number(at: entry + 2, length: 2),
                      let items = number(at: entry + 4, length: 4)
                else { continue }
                entries[tag] = (type, items, entry + 8)
            }
            /// The entry's values, unsigned, where the head holds them all.
            func values(_ tag: Int) -> [Int]? {
                guard let entry = entries[tag], entry.count > 0, entry.count <= 1 << 20 else { return nil }
                let size = switch entry.type {
                case 1, 7: 1
                case 3: 2
                case 4, 13: 4
                default: 0
                }
                guard size > 0 else { return nil }
                let start = entry.count * size <= 4 ? entry.field : number(at: entry.field, length: 4)
                guard let start, start + entry.count * size <= bytes.count else { return nil }
                return (0 ..< entry.count).compactMap { number(at: start + $0 * size, length: size) }
            }
            for (offsets, counts) in [
                (Tag.stripOffsets, Tag.stripByteCounts), (Tag.tileOffsets, Tag.tileByteCounts),
                (Tag.jpegOffset, Tag.jpegLength),
            ] {
                guard let starts = values(offsets), let lengths = values(counts) else { continue }
                for (start, length) in zip(starts, lengths) where length > 0 {
                    end = max(end ?? 0, Int64(start) + Int64(length))
                }
            }
            isDNG = isDNG || entries[Tag.dngVersion] != nil
            if let photometric = values(Tag.photometric)?.first, photometric == 32803 || photometric == 34892 {
                isRaw = true
            }
            if depth == 0, entries[Tag.subIFDs] != nil {
                isRaw = true
            }
            if make == nil, let entry = entries[Tag.make], entry.type == 2, entry.count > 0 {
                let start = entry.count <= 4 ? entry.field : number(at: entry.field, length: 4) ?? -1
                if start >= 0, start + entry.count <= bytes.count {
                    let text = UnsafeRawBufferPointer(rebasing: bytes[start ..< start + entry.count]).prefix { $0 != 0 }
                    make = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if depth < depthLimit {
                pending += (values(Tag.subIFDs) ?? []).map { ($0, depth + 1) }
            }
            if let next = number(at: directory + 2 + count * 12, length: 4), next != 0 {
                pending.append((next, depth))
            }
        }
        return TIFFHead(
            dataEnd: end, directories: directories, isDNG: isDNG, isRaw: isRaw, make: make, signature: signature,
        )
    }
}
