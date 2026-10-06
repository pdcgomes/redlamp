import CoreGraphics
import Foundation
import ImageIO

/// A JPEG a camera embedded in a raw file: where it lies, and its size when the file or the JPEG
/// itself says.
struct EmbeddedJPEG: Sendable, Hashable {
    var offset: Int
    var length: Int
    var width: Int?
    var height: Int?

    var range: Range<Int> {
        offset ..< offset + length
    }

    var longEdge: Int? {
        guard let width, let height else { return nil }
        return max(width, height)
    }
}

/// A file's bytes as the previews' search reads them: its head, already read, and what lies beyond
/// fetched as asked, in blocks.
struct PreviewBytes {
    let head: Data
    let size: Int
    let fetch: @Sendable (Range<Int>) async throws -> Data
    private var blocks: [Int: Data] = [:]
    private(set) var fetched = 0
    static let block = 16 * 1024

    init(head: Data, size: Int, fetch: @escaping @Sendable (Range<Int>) async throws -> Data) {
        self.head = head
        self.size = size
        self.fetch = fetch
    }

    /// The bytes of `range`, nil when the file doesn't hold them all.
    mutating func bytes(_ range: Range<Int>) async throws -> [UInt8]? {
        guard range.lowerBound >= 0, range.upperBound <= size, !range.isEmpty else { return nil }
        if range.upperBound <= head.count {
            return Array(head[head.startIndex + range.lowerBound ..< head.startIndex + range.upperBound])
        }
        if range.count > 4 * Self.block {
            let data = try await fetch(range)
            fetched += data.count
            return data.count == range.count ? Array(data) : nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(range.count)
        var position = range.lowerBound
        while position < range.upperBound {
            let start = position / Self.block * Self.block
            let block: Data
            if start + Self.block <= head.count {
                block = head[head.startIndex + start ..< head.startIndex + start + Self.block]
            } else if let known = blocks[start] {
                block = known
            } else {
                block = try await fetch(start ..< min(start + Self.block, size))
                fetched += block.count
                blocks[start] = block
            }
            let end = min(range.upperBound, start + block.count)
            guard end > position else { return nil }
            bytes += block[block.startIndex + position - start ..< block.startIndex + end - start]
            position = end
        }
        return bytes
    }
}

/// Finds the JPEG previews a camera put in a raw file without reading the rest of it: in the image
/// file directories of TIFF/EP's structure, which ARW, CR2, DNG, NEF, PEF and RW2 share (each
/// directory's JPEG interchange format, its single strip compressed as JPEG, or RW2's JpgFromRaw); at
/// the place Fujifilm's RAF header gives; and in the preview box of Canon's CR3.
enum EmbeddedPreviews {
    /// The previews `bytes`' file holds, in no particular order, each inside the file.
    static func find(in bytes: inout PreviewBytes) async throws -> [EmbeddedJPEG] {
        let found: [EmbeddedJPEG] = if let magic = try await bytes.bytes(0 ..< 16) {
            if magic.starts(with: Array("FUJIFILMCCD-RAW".utf8)) {
                try await raf(&bytes)
            } else if magic[4 ..< 8] == ArraySlice("ftyp".utf8) {
                try await cr3(&bytes)
            } else if magic[0] == magic[1], magic[0] == 0x49 || magic[0] == 0x4D {
                try await tiff(&bytes, littleEndian: magic[0] == 0x49)
            } else {
                []
            }
        } else {
            []
        }
        return found.filter { $0.length > 0 && $0.offset >= 0 && $0.offset + $0.length <= bytes.size }
    }

    /// The smallest preview whose long edge reaches `edge`, or the largest when none does; nil when
    /// the file has none that decodes as a JPEG.
    static func best(in bytes: inout PreviewBytes, reaching edge: Int) async throws -> EmbeddedJPEG? {
        var previews: [EmbeddedJPEG] = []
        for var preview in try await find(in: &bytes) {
            guard let (width, height) = try await frameSize(of: preview, in: &bytes) else { continue }
            preview.width = width
            preview.height = height
            previews.append(preview)
        }
        let reaching = previews.filter { ($0.longEdge ?? 0) >= edge }.min { $0.length < $1.length }
        return reaching ?? previews.max { ($0.longEdge ?? 0, $0.length) < ($1.longEdge ?? 0, $1.length) }
    }

    // MARK: - TIFF/EP

    private static let jpegCompressions: Set<Int> = [6, 7]
    /// Colour filter array and linear raw: sensor data, not a preview.
    private static let rawPhotometrics: Set<Int> = [32803, 34892]

    private struct Entry {
        var type: Int
        var count: Int
        /// The value itself when it fits in four bytes, else where it is.
        var value: Int
    }

    private static func tiff(_ bytes: inout PreviewBytes, littleEndian: Bool) async throws -> [EmbeddedJPEG] {
        func number(_ data: [UInt8], _ offset: Int, _ length: Int) -> Int {
            (0 ..< length).reduce(0) { value, index in
                value << 8 | Int(data[offset + (littleEndian ? length - 1 - index : index)])
            }
        }
        guard let header = try await bytes.bytes(0 ..< 8) else { return [] }
        var waiting = [number(header, 4, 4)]
        var seen = Set<Int>()
        var found: [EmbeddedJPEG] = []
        while let offset = waiting.popLast(), seen.count < 64 {
            guard offset >= 8, seen.insert(offset).inserted,
                  let countBytes = try await bytes.bytes(offset ..< offset + 2)
            else { continue }
            let count = number(countBytes, 0, 2)
            guard count > 0, count < 512, let table = try await bytes.bytes(offset + 2 ..< offset + 2 + count * 12 + 4)
            else { continue }
            var entries: [Int: Entry] = [:]
            for index in 0 ..< count {
                let at = index * 12
                let type = number(table, at + 2, 2)
                let items = number(table, at + 4, 4)
                let short = (type == 3 || type == 8) && items == 1
                entries[number(table, at, 2)] = Entry(
                    type: type, count: items, value: short ? number(table, at + 8, 2) : number(table, at + 8, 4),
                )
            }
            let next = number(table, count * 12, 4)
            if next != 0 {
                waiting.append(next)
            }
            if let subdirectories = entries[0x014A] {
                if subdirectories.count == 1 {
                    waiting.append(subdirectories.value)
                } else if subdirectories.count <= 16,
                          let list = try await bytes
                          .bytes(subdirectories.value ..< subdirectories.value + 4 * subdirectories.count) {
                    waiting += (0 ..< subdirectories.count).map { number(list, $0 * 4, 4) }
                }
            }
            let width = entries[0x0100].map(\.value)
            let height = entries[0x0101].map(\.value)
            let compression = entries[0x0103]?.value
            if let start = entries[0x0201]?.value, let length = entries[0x0202]?.value {
                found.append(EmbeddedJPEG(
                    offset: start, length: length, width: compression == 6 ? width : nil,
                    height: compression == 6 ? height : nil,
                ))
            }
            if let compression, jpegCompressions.contains(compression),
               let strip = entries[0x0111], let stripLength = entries[0x0117], strip.count == 1, stripLength.count == 1,
               !rawPhotometrics.contains(entries[0x0106]?.value ?? 0), entries[0xC640] == nil {
                found.append(EmbeddedJPEG(offset: strip.value, length: stripLength.value, width: width, height: height))
            }
            if let jpeg = entries[0x002E], jpeg.type == 7, jpeg.count > 4 {
                found.append(EmbeddedJPEG(offset: jpeg.value, length: jpeg.count))
            }
        }
        return found
    }

    // MARK: - RAF and CR3

    /// Fujifilm's header gives its JPEG's offset and length, big-endian, at bytes 84 and 88.
    private static func raf(_ bytes: inout PreviewBytes) async throws -> [EmbeddedJPEG] {
        guard let fields = try await bytes.bytes(84 ..< 92) else { return [] }
        return [EmbeddedJPEG(offset: bigEndian(fields, 0, 4), length: bigEndian(fields, 4, 4))]
    }

    /// Canon's preview box, `uuid` `eaf42b5e-1c98-4b88-b9fb-b7dc406e4d16` at the top level, holds a `PRVW`
    /// box: its size, the preview's width and height at 14 and 16, its length at 20 and the JPEG at 24.
    private static func cr3(_ bytes: inout PreviewBytes) async throws -> [EmbeddedJPEG] {
        let previewBox: [UInt8] = [
            0xEA, 0xF4, 0x2B, 0x5E, 0x1C, 0x98, 0x4B, 0x88, 0xB9, 0xFB, 0xB7, 0xDC, 0x40, 0x6E, 0x4D, 0x16,
        ]
        var offset = 0
        var boxes = 0
        while offset + 8 <= bytes.size, boxes < 64 {
            boxes += 1
            guard let header = try await bytes.bytes(offset ..< min(offset + 24, bytes.size)), header.count >= 8
            else { return [] }
            var size = bigEndian(header, 0, 4)
            var content = offset + 8
            if size == 1, header.count >= 16 {
                size = bigEndian(header, 8, 8)
                content += 8
            } else if size == 0 {
                size = bytes.size - offset
            }
            guard size >= 8 else { return [] }
            if header[4 ..< 8] == ArraySlice("uuid".utf8), header.count >= content - offset + 16,
               Array(header[content - offset ..< content - offset + 16]) == previewBox,
               let inside = try await bytes.bytes(content + 16 ..< min(content + 16 + 64, offset + size)),
               let mark = inside.indices.dropLast(3).first(where: { inside[$0 ..< $0 + 4] == ArraySlice("PRVW".utf8) }),
               mark >= 4, mark + 20 <= inside.count {
                let box = mark - 4
                return [EmbeddedJPEG(
                    offset: content + 16 + box + 24, length: bigEndian(inside, box + 20, 4),
                    width: bigEndian(inside, box + 14, 2), height: bigEndian(inside, box + 16, 2),
                )]
            }
            offset += size
        }
        return []
    }

    private static func bigEndian(_ data: [UInt8], _ offset: Int, _ length: Int) -> Int {
        guard offset + length <= data.count else { return 0 }
        return (0 ..< length).reduce(0) { $0 << 8 | Int(data[offset + $1]) }
    }

    // MARK: - JPEG frames

    /// The width and height a JPEG's frame header gives, read from its first bytes; nil when it isn't
    /// a JPEG ImageIO decodes (a lossless one holds a raw's sensor data) or no frame header comes
    /// before its scan.
    static func frameSize(of preview: EmbeddedJPEG, in bytes: inout PreviewBytes) async throws -> (Int, Int)? {
        var position = preview.offset
        let end = preview.offset + min(preview.length, 256 * 1024)
        guard let start = try await bytes.bytes(position ..< position + 2), start == [0xFF, 0xD8] else { return nil }
        position += 2
        while position + 4 <= end {
            guard let marker = try await bytes.bytes(position ..< position + 4), marker[0] == 0xFF else { return nil }
            let kind = marker[1]
            let length = bigEndian(marker, 2, 2)
            switch kind {
            case 0xC0, 0xC1, 0xC2:
                guard let frame = try await bytes.bytes(position + 4 ..< position + 9) else { return nil }
                return (bigEndian(frame, 3, 2), bigEndian(frame, 1, 2))
            case 0xC3, 0xC5 ... 0xC7, 0xC9 ... 0xCB, 0xCD ... 0xCF, 0xDA:
                return nil
            case 0x01, 0xD0 ... 0xD7:
                position += 2
            default:
                guard length >= 2 else { return nil }
                position += 2 + length
            }
        }
        return nil
    }

    // MARK: - Thumbnails

    /// A JPEG's image at most `edge` on its long side, upright: as the JPEG's own orientation says,
    /// or, when it has none, as its raw's does (`orientation`, EXIF's 1 to 8).
    static func thumbnail(ofJPEG data: Data, edge: Int, orientation: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let own = properties?[kCGImagePropertyOrientation] as? Int
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceCreateThumbnailWithTransform: own != nil,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        guard own == nil, let orientation, (2 ... 8).contains(orientation) else { return image }
        return oriented(image, orientation)
    }

    /// A raw's image at most `edge` on its long side, upright, from the preview ImageIO finds in it: a
    /// raw it would have to develop takes it seconds.
    static func thumbnail(ofRaw data: Data, edge: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// `image` turned upright from EXIF's `orientation`.
    static func oriented(_ image: CGImage, _ orientation: Int) -> CGImage? {
        let (width, height) = (CGFloat(image.width), CGFloat(image.height))
        let swaps = (5 ... 8).contains(orientation)
        let size = swaps ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else { return nil }
        // The transforms take the stored image to its upright place, in Core Graphics' flipped space.
        let transform: CGAffineTransform = switch orientation {
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case 3: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 4: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case 5: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: height, ty: width)
        case 6: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case 7: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        default: .identity
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
