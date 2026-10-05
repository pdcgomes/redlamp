import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI
import Synchronization

/// Decodes a DNG raw image that is JPEG XL-compressed (DNG 1.7, Compression 52546), as in
/// recent iPhone ProRAW files. LibRaw only reads these when built with the Adobe DNG SDK.
///
/// ImageIO decodes each tile to the stored integer codes, regardless of the color encoding the
/// tile's header declares; the DNG LinearizationTable then maps those codes to linear values.
enum DNGJPEGXL {
    /// The stored raw image, three samples per pixel, before the ActiveArea crop.
    struct Image {
        let width: Int
        let height: Int
        let samples: [UInt16]
    }

    static let compression = 52546

    private enum Tag {
        static let newSubfileType: UInt16 = 254
        static let width: UInt16 = 256
        static let height: UInt16 = 257
        static let compression: UInt16 = 259
        static let photometric: UInt16 = 262
        static let samplesPerPixel: UInt16 = 277
        static let tileWidth: UInt16 = 322
        static let tileHeight: UInt16 = 323
        static let tileOffsets: UInt16 = 324
        static let tileByteCounts: UInt16 = 325
        static let linearizationTable: UInt16 = 50712
    }

    private enum Photometric {
        static let colorFilterArray = 32803
        static let linearRaw = 34892
    }

    /// LibRaw's limit on each side of a raw image.
    static let maximumSide = 65535

    /// The raw image, or nil when the file's raw image isn't JPEG XL-compressed. A JPEG XL
    /// directory is the raw image only when its size is LibRaw's `rawSize`.
    static func decode(_ url: URL, rawSize: PixelSize) throws -> Image? {
        try decode(Data(contentsOf: url, options: .alwaysMapped), rawSize: rawSize)
    }

    static func decode(_ data: Data, rawSize: PixelSize) throws -> Image? {
        try data.withUnsafeBytes { bytes in
            guard let reader = TIFFReader(bytes: bytes) else { return nil }
            return try decode(reader, rawSize: rawSize)
        }
    }

    static func decode(_ reader: TIFFReader, rawSize: PixelSize) throws -> Image? {
        let directories = reader.imageFileDirectories().map { entries in
            Dictionary(entries.map { ($0.tag, $0) }) { first, _ in first }
        }
        func values(_ tags: [UInt16: TIFFReader.Entry], _ tag: UInt16) -> [Int] {
            tags[tag].map(reader.integers) ?? []
        }
        // The full-resolution raw image is the directory with NewSubfileType 0.
        guard let tags = directories.first(where: {
            values($0, Tag.newSubfileType).first ?? 0 == 0 && values($0, Tag.compression).first == compression
        }) else {
            return nil
        }

        let photometric = values(tags, Tag.photometric).first
        if photometric == Photometric.colorFilterArray {
            throw EngineError.notSupportedYet("JPEG XL-compressed mosaic DNGs", tracker: "CAM-10")
        }
        guard photometric == Photometric.linearRaw, values(tags, Tag.samplesPerPixel).first == 3 else {
            throw EngineError.decodeFailed("unsupported JPEG XL DNG layout")
        }

        let width = values(tags, Tag.width).first ?? 0
        let height = values(tags, Tag.height).first ?? 0
        guard width == rawSize.width, height == rawSize.height,
              (1 ... maximumSide).contains(width), (1 ... maximumSide).contains(height),
              let sampleCount = TIFFReader.product(width, height, 3)
        else {
            return nil
        }
        let tileWidth = values(tags, Tag.tileWidth).first ?? 0
        let tileHeight = values(tags, Tag.tileHeight).first ?? 0
        let offsets = values(tags, Tag.tileOffsets)
        let byteCounts = values(tags, Tag.tileByteCounts)
        guard tileWidth > 0, tileHeight > 0 else {
            throw EngineError.decodeFailed("JPEG XL DNG without tile dimensions")
        }
        let tilesAcross = (width + tileWidth - 1) / tileWidth
        let tilesDown = (height + tileHeight - 1) / tileHeight
        guard offsets.count == TIFFReader.product(tilesAcross, tilesDown), byteCounts.count == offsets.count,
              zip(offsets, byteCounts).allSatisfy({ $0 >= 0 && $1 > 0 && $0 + $1 <= reader.bytes.count })
        else {
            throw EngineError.decodeFailed("JPEG XL DNG tiles are missing or truncated")
        }
        let table = values(tags, Tag.linearizationTable).map { UInt16(clamping: $0) }

        let failure = Mutex<EngineError?>(nil)
        nonisolated(unsafe) let file = reader.bytes
        let samples = [UInt16](unsafeUninitializedCapacity: sampleCount) { buffer, count in
            buffer.initialize(repeating: 0)
            count = sampleCount
            // Each tile writes only its own pixels.
            nonisolated(unsafe) let destination = Destination(
                samples: buffer, width: width, height: height,
                tileWidth: tileWidth, tileHeight: tileHeight, table: table,
            )
            DispatchQueue.concurrentPerform(iterations: offsets.count) { index in
                let tile = Data(bytes: file.baseAddress! + offsets[index], count: byteCounts[index])
                do {
                    try decodeTile(
                        tile, into: destination,
                        originX: (index % tilesAcross) * tileWidth, originY: (index / tilesAcross) * tileHeight,
                    )
                } catch {
                    failure.withLock { $0 = $0 ?? (error as? EngineError) ?? .decodeFailed("\(error)") }
                }
            }
        }
        if let error = failure.withLock({ $0 }) {
            throw error
        }
        return Image(width: width, height: height, samples: samples)
    }

    /// The whole stored image that tiles decode into.
    private struct Destination {
        let samples: UnsafeMutableBufferPointer<UInt16>
        let width: Int
        let height: Int
        let tileWidth: Int
        let tileHeight: Int
        let table: [UInt16]
    }

    private static func decodeTile(_ data: Data, into destination: Destination, originX: Int, originY: Int) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let tileWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let tileHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw EngineError.decodeFailed("a JPEG XL tile could not be decoded")
        }
        guard tileWidth <= destination.tileWidth, tileHeight <= destination.tileHeight else {
            throw EngineError.decodeFailed("a JPEG XL tile is larger than the DNG's tiles")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let pixels = image.dataProvider?.data,
              let base = CFDataGetBytePtr(pixels)
        else {
            throw EngineError.decodeFailed("a JPEG XL tile could not be decoded")
        }
        let channels = image.bitsPerPixel / 16
        guard image.bitsPerComponent == 16, channels >= 3, !image.bitmapInfo.contains(.floatComponents) else {
            throw EngineError.decodeFailed("a JPEG XL tile decoded to an unexpected pixel format")
        }
        let byteOrder = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        let littleEndian = byteOrder == CGImageByteOrderInfo.order16Little.rawValue
        let rowBytes = image.bytesPerRow
        let columns = min(image.width, destination.tileWidth, destination.width - originX)
        let rows = min(image.height, destination.tileHeight, destination.height - originY)
        let table = destination.table
        let raw = UnsafeRawPointer(base)
        for y in 0 ..< rows {
            let row = raw + y * rowBytes
            var to = ((originY + y) * destination.width + originX) * 3
            for x in 0 ..< columns {
                for channel in 0 ..< 3 {
                    let stored = row.loadUnaligned(fromByteOffset: (x * channels + channel) * 2, as: UInt16.self)
                    let code = Int(littleEndian ? UInt16(littleEndian: stored) : UInt16(bigEndian: stored))
                    destination.samples[to] = table.isEmpty ? UInt16(code) : table[min(code, table.count - 1)]
                    to += 1
                }
            }
        }
    }
}
