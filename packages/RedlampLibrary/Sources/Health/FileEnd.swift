import Foundation

/// Whether a file ends where its data does (LIB-40), judged only where that takes a small read: a
/// TIFF-based file's strips, tiles and embedded JPEG and a RAF's parts from the head, an ISO base
/// media file's top-level boxes from their headers, and a JPEG's end-of-image marker and a PNG's
/// last chunk from the last `tailLength` bytes, or the head when it holds the whole file.
enum FileEnd: Sendable, Hashable {
    /// It ends where its data does, or its format doesn't say where that is.
    case whole
    /// It ends before its data does: by `missing` bytes, or by an amount its format doesn't say.
    case early(missing: Int64?)
    /// The bytes of `range` are needed to say: read them and judge again.
    case needs(Range<Int>)

    /// The end of a JPEG or a PNG read to find its last marker or chunk: room for the trailers
    /// cameras and editors write after the image (PhotoMechanic's, Canon's VRD), and one read.
    static let tailLength = 64 * 1024
    /// Box headers followed, at most: a file needing more is left as whole.
    static let boxLimit = 256

    /// `format`'s end in a file of `size` bytes, from what's been read of it; an ISO base media file's
    /// boxes followed from the one at `boxesFrom`, which an earlier judgement asked for.
    static func judge(_ format: PhotoFormat, size: Int, bytes: FileBytes, boxesFrom: Int = 0) -> FileEnd {
        switch format {
        case .jpeg: jpeg(size: size, bytes: bytes)
        case .png: png(size: size, bytes: bytes)
        case .tiff: tiff(size: size, bytes: bytes)
        case .heif, .avif, .cr3: boxes(size: size, bytes: bytes, from: Int64(boxesFrom))
        case .raf: raf(size: size, bytes: bytes)
        case .unknown, .crw, .mrw, .gif, .webp: .whole
        }
    }

    /// The tail of a file of `size` bytes, unless `bytes` holds it.
    private static func tail(size: Int, bytes: FileBytes) -> Data? {
        let start = max(0, size - tailLength)
        return bytes.data(at: start, length: size - start)
    }

    // MARK: - JPEG

    /// A JPEG the head holds whole is walked from marker to marker to its end-of-image marker; a
    /// longer one needs the marker in its tail. In the tail, `FF D9` can only be a marker: entropy-coded
    /// data stuffs every `FF` it holds. Data after the marker is a trailer, which ends nothing early;
    /// a trailer too long for the tail (Google's and Samsung's motion photos) is said in the head.
    private static func jpeg(size: Int, bytes: FileBytes) -> FileEnd {
        if let whole = bytes.data(at: 0, length: size) {
            return walkJPEG(whole)
        }
        let headRange = 0 ..< min(size, PhotoMetadataReader.headLength)
        let head = bytes.data(at: 0, length: headRange.count)
        if let head, ["MotionPhoto", "MicroVideo"].contains(where: { contains(head, Array($0.utf8)) }) {
            return .whole
        }
        guard let tail = tail(size: size, bytes: bytes) else {
            return .needs(max(0, size - tailLength) ..< size)
        }
        if contains(tail, [0xFF, 0xD9]) || tail.suffix(4).elementsEqual(Array("SEFT".utf8)) {
            return .whole
        }
        return head == nil ? .needs(headRange) : .early(missing: nil)
    }

    /// The markers of a whole JPEG from its start: its end-of-image marker found, or a segment or its
    /// data running past the end, which doesn't say how much of the image is missing.
    private static func walkJPEG(_ data: Data) -> FileEnd {
        data.withUnsafeBytes { bytes in
            let count = bytes.count
            var offset = 2
            while offset < count {
                guard bytes[offset] == 0xFF else { return .whole }
                while offset < count, bytes[offset] == 0xFF {
                    offset += 1
                }
                guard offset < count else { break }
                let marker = bytes[offset]
                offset += 1
                switch marker {
                case 0xD9:
                    return .whole
                case 0x01, 0xD0 ... 0xD7:
                    continue
                case 0xD8, 0x00:
                    return .whole
                default:
                    guard offset + 2 <= count else { return .early(missing: nil) }
                    let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                    guard length >= 2 else { return .whole }
                    offset += length
                    guard offset <= count else { return .early(missing: nil) }
                    guard marker == 0xDA else { continue }
                    // Entropy-coded data, up to the next marker: an FF neither stuffed nor a restart.
                    while offset + 1 < count,
                          !(bytes[offset] == 0xFF && bytes[offset + 1] != 0 && !(0xD0 ... 0xD7)
                              .contains(bytes[offset + 1])) {
                        offset += 1
                    }
                    guard offset + 1 < count else { return .early(missing: nil) }
                }
            }
            return .early(missing: nil)
        }
    }

    // MARK: - PNG

    /// A PNG's last chunk, `IEND`, in its tail, or in the head when that holds it whole.
    private static func png(size: Int, bytes: FileBytes) -> FileEnd {
        guard let tail = bytes.data(at: 0, length: size).map({ $0.suffix(tailLength) }) ?? tail(
            size: size,
            bytes: bytes,
        )
        else { return .needs(max(0, size - tailLength) ..< size) }
        return contains(tail, Array("IEND".utf8)) ? .whole : .early(missing: nil)
    }

    // MARK: - TIFF and RAF

    private static func tiff(size: Int, bytes: FileBytes) -> FileEnd {
        guard let head = bytes.data(at: 0, length: min(size, PhotoMetadataReader.headLength)),
              let end = TIFFHead(head)?.dataEnd, end > Int64(size)
        else { return .whole }
        return .early(missing: end - Int64(size))
    }

    /// A RAF's embedded JPEG, its CFA header and its CFA data, by the offsets and lengths its header
    /// gives from byte 84, big-endian.
    private static func raf(size: Int, bytes: FileBytes) -> FileEnd {
        guard let header = bytes.data(at: 84, length: 24) else { return .whole }
        let numbers = stride(from: 0, to: 24, by: 4).map { start in
            header.dropFirst(start).prefix(4).reduce(Int64(0)) { $0 << 8 | Int64($1) }
        }
        var end: Int64 = 0
        for part in stride(from: 0, to: 6, by: 2) where numbers[part] > 0 && numbers[part + 1] > 0 {
            end = max(end, numbers[part] + numbers[part + 1])
        }
        return end > Int64(size) ? .early(missing: end - Int64(size)) : .whole
    }

    // MARK: - ISO base media

    /// The top-level boxes from the first, each header read where it starts: the last must end where
    /// the file does. A box sized to the end of the file says nothing, nor does a header that isn't
    /// a box's.
    private static func boxes(size: Int, bytes: FileBytes, from first: Int64) -> FileEnd {
        var offset = first
        for _ in 0 ..< boxLimit {
            if offset == Int64(size) {
                return .whole
            }
            guard offset < Int64(size) else { return .early(missing: offset - Int64(size)) }
            let start = Int(offset)
            let length = min(16, size - start)
            guard length >= 8 else { return .whole }
            guard let read = bytes.data(at: start, length: length) else { return .needs(start ..< start + length) }
            let header = [UInt8](read)
            let box = header[0 ..< 4].reduce(Int64(0)) { $0 << 8 | Int64($1) }
            guard header[4 ..< 8].allSatisfy({ (0x20 ... 0x7E).contains($0) }) else { return .whole }
            switch box {
            case 0:
                return .whole
            case 1:
                guard header.count >= 16 else { return .early(missing: Int64(start + 16 - size)) }
                let large = header[8 ..< 16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard large >= 16, large < UInt64(Int64.max) - UInt64(offset) else { return .whole }
                offset += Int64(large)
            case 8...:
                offset += box
            default:
                return .whole
            }
        }
        return .whole
    }

    // MARK: - Helpers

    private static func contains(_ data: Data, _ needle: [UInt8]) -> Bool {
        data.withUnsafeBytes { bytes in
            guard needle.count > 0, bytes.count >= needle.count else { return false }
            for start in 0 ... bytes.count - needle.count where bytes[start] == needle[0] {
                if (1 ..< needle.count).allSatisfy({ bytes[start + $0] == needle[$0] }) {
                    return true
                }
            }
            return false
        }
    }
}

/// The parts of a file read so far, each where it starts.
struct FileBytes: Sendable {
    private(set) var parts: [(offset: Int, data: Data)] = []

    init(_ parts: [(offset: Int, data: Data)] = []) {
        self.parts = parts.filter { !$0.data.isEmpty }
    }

    mutating func add(_ data: Data, at offset: Int) {
        guard !data.isEmpty else { return }
        parts.append((offset, data))
    }

    /// The `length` bytes from `offset`, when one part holds them all.
    func data(at offset: Int, length: Int) -> Data? {
        guard offset >= 0, length >= 0 else { return nil }
        for part in parts where part.offset <= offset && offset + length <= part.offset + part.data.count {
            let start = part.data.startIndex + (offset - part.offset)
            return part.data[start ..< start + length]
        }
        return nil
    }
}
