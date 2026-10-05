import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// A fixture's JPEGs and HEICs. Each is one of sixteen small images, encoded once by ImageIO,
/// carrying the photo's own EXIF, TIFF, GPS and IPTC. ImageIO writes metadata from a property
/// dictionary under a lock the whole process shares (no more than about 2,000 photos a second on
/// every core, 650 with IPTC), and a HEIC takes 35 ms to encode, so the encoded images are
/// templates: a JPEG gets new EXIF and IPTC segments; a HEIC, encoded with room to spare in its
/// Exif and XMP items, gets them overwritten in place, its layout unchanged.
struct FixtureImages: Sendable {
    /// Made once for the process: ImageIO's HEIC encoder takes a moment to start.
    static let shared = Result { try FixtureImages() }

    private struct HEICTemplate: Sendable {
        let bytes: [UInt8]
        /// The Exif item, and where its TIFF header starts in it.
        let exif: Range<Int>
        let tiffStart: Int
        /// The XMP item, which holds a HEIC's IPTC.
        let xmp: Range<Int>
    }

    /// Each image's JPEG after its start-of-image marker, without the application segments
    /// ImageIO wrote.
    private let jpegs: [[UInt8]]
    private let heics: [HEICTemplate]

    private init() throws {
        let images = Self.palette()
        jpegs = try images.map(Self.jpegBody)
        let heics = Mutex<[Int: Result<HEICTemplate, any Error>]>([:])
        DispatchQueue.concurrentPerform(iterations: images.count) { index in
            let template = Result { try Self.heicTemplate(images[index]) }
            heics.withLock { $0[index] = template }
        }
        self.heics = try heics.withLock { made in try images.indices.map { try made[$0]!.get() } }
    }

    func data(for photo: FixturePhoto) -> Data {
        photo.kind == .heic ? heic(photo) : jpeg(photo)
    }

    // MARK: - JPEG

    private func jpeg(_ photo: FixturePhoto) -> Data {
        var bytes: [UInt8] = [0xFF, 0xD8]
        bytes += Self.segment(0xE1, Array("Exif\0\0".utf8) + Self.exif(photo))
        if !photo.embeddedKeywords.isEmpty || photo.caption != nil {
            bytes += Self.segment(0xED, Self.photoshop(Self.iim(photo)))
        }
        bytes += jpegs[photo.index % jpegs.count]
        return Data(bytes)
    }

    private static func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [0xFF, marker] + bigEndian(UInt16(payload.count + 2)) + payload
    }

    private static func jpegBody(_ image: CGImage) throws -> [UInt8] {
        let bytes = try encode(image, as: .jpeg, properties: [:])
        var body: [UInt8] = []
        var offset = 2
        while offset + 4 <= bytes.count, bytes[offset] == 0xFF {
            let marker = bytes[offset + 1]
            if marker == 0xDA {
                break
            }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            if !(0xE0 ... 0xEF).contains(marker) {
                body += bytes[offset ..< offset + 2 + length]
            }
            offset += 2 + length
        }
        return body + bytes[offset...]
    }

    /// The IPTC keywords and caption as a Photoshop image resource (0x0404), as an APP13 segment
    /// carries them.
    private static func photoshop(_ iim: [UInt8]) -> [UInt8] {
        Array("Photoshop 3.0\0".utf8) + Array("8BIM".utf8) + bigEndian(UInt16(0x0404)) + [0, 0]
            + bigEndian(UInt32(iim.count)) + iim + (iim.count % 2 == 1 ? [0] : [])
    }

    /// IPTC-IIM datasets: UTF-8, then the keywords (2:25) and the caption (2:120).
    private static func iim(_ photo: FixturePhoto) -> [UInt8] {
        func dataset(_ record: UInt8, _ number: UInt8, _ value: [UInt8]) -> [UInt8] {
            [0x1C, record, number] + bigEndian(UInt16(value.count)) + value
        }
        var datasets = dataset(1, 90, [0x1B, 0x25, 0x47]) + dataset(2, 0, [0, 4])
        for keyword in photo.embeddedKeywords {
            datasets += dataset(2, 25, Array(keyword.utf8))
        }
        if let caption = photo.caption {
            datasets += dataset(2, 120, Array(caption.utf8))
        }
        return datasets
    }

    // MARK: - HEIC

    private func heic(_ photo: FixturePhoto) -> Data {
        let template = heics[photo.index % heics.count]
        var bytes = template.bytes
        let tiff = Self.exif(photo)
        precondition(
            template.tiffStart + tiff.count <= template.exif.upperBound,
            "a HEIC template's Exif item is too small",
        )
        bytes.replaceSubrange(template.tiffStart ..< template.tiffStart + tiff.count, with: tiff)
        bytes.replaceSubrange(
            template.tiffStart + tiff.count ..< template.exif.upperBound,
            with: repeatElement(0, count: template.exif.upperBound - template.tiffStart - tiff.count),
        )
        bytes.replaceSubrange(template.xmp, with: Self.xmp(photo, length: template.xmp.count))
        return Data(bytes)
    }

    /// A HEIC whose Exif and XMP items have room for any photo's: placeholders a kilobyte long.
    private static func heicTemplate(_ image: CGImage) throws -> HEICTemplate {
        let room = String(repeating: "x", count: 1000)
        let bytes = try encode(image, as: .heic, properties: [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: room],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCKeywords: [room],
                kCGImagePropertyIPTCCaptionAbstract: room,
            ],
        ])
        let items = HEIFItems(bytes)
        guard let exif = items.extent(ofType: "Exif"), let xmp = items.extent(ofType: "mime"), exif.count > 4
        else { throw FixtureError.cannotEncode("a HEIC template") }
        let offset = bytes[exif.lowerBound ..< exif.lowerBound + 4].reduce(0) { $0 << 8 | Int($1) }
        return HEICTemplate(bytes: bytes, exif: exif, tiffStart: exif.lowerBound + 4 + offset, xmp: xmp)
    }

    /// The IPTC keywords and caption as a HEIC carries them, padded to `length` as XMP allows.
    private static func xmp(_ photo: FixturePhoto, length: Int) -> [UInt8] {
        var description = ""
        if !photo.embeddedKeywords.isEmpty {
            description += "   <dc:subject>\n    <rdf:Bag>\n"
                + photo.embeddedKeywords.map { "     <rdf:li>\($0)</rdf:li>\n" }.joined()
                + "    </rdf:Bag>\n   </dc:subject>\n"
        }
        if let caption = photo.caption {
            description += "   <dc:description>\n    <rdf:Alt>\n"
                + "     <rdf:li xml:lang=\"x-default\">\(caption)</rdf:li>\n    </rdf:Alt>\n   </dc:description>\n"
        }
        let head = Array("""
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
        \(description)  </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """.utf8)
        let end = Array("<?xpacket end=\"w\"?>".utf8)
        precondition(head.count + end.count <= length, "a HEIC template's XMP item is too small")
        return head + Array(repeating: 0x20, count: length - head.count - end.count) + end
    }

    // MARK: - EXIF

    /// The photo's EXIF as a little-endian TIFF structure: make, model and orientation in IFD 0,
    /// the exposure, capture date and lens in the Exif IFD, the location in the GPS IFD.
    static func exif(_ photo: FixturePhoto) -> [UInt8] {
        var main: [TIFF.Entry] = [(0x0112, .short(1)), (0x0132, .ascii(photo.captured.exif))]
        if let make = photo.make {
            main.append((0x010F, .ascii(make)))
        }
        if let model = photo.model {
            main.append((0x0110, .ascii(model)))
        }
        var exif: [TIFF.Entry] = [
            (0x9000, .undefined(Array("0232".utf8))), (0x9003, .ascii(photo.captured.exif)),
            (0x9004, .ascii(photo.captured.exif)),
        ]
        if let time = photo.exposureTime {
            exif.append((0x829A, .rationals([time < 1 ? (1, UInt32((1 / time).rounded())) : TIFF.rational(time, 10)])))
        }
        if let aperture = photo.aperture {
            exif.append((0x829D, .rationals([TIFF.rational(aperture, 100)])))
        }
        if let iso = photo.iso {
            exif.append((0x8827, .short(UInt16(min(iso, 65535)))))
        }
        if let focal = photo.focalLength {
            exif.append((0x920A, .rationals([TIFF.rational(focal, 1000)])))
        }
        if let lens = photo.lens {
            exif.append((0xA434, .ascii(lens)))
        }
        var subdirectories: [(pointer: UInt16, entries: [TIFF.Entry])] = [(0x8769, exif)]
        if let location = photo.location {
            subdirectories.append((0x8825, [
                (0x0000, .bytes([2, 3, 0, 0])),
                (0x0001, .ascii(location.latitude < 0 ? "S" : "N")),
                (0x0002, .rationals(TIFF.degrees(abs(location.latitude)))),
                (0x0003, .ascii(location.longitude < 0 ? "W" : "E")),
                (0x0004, .rationals(TIFF.degrees(abs(location.longitude)))),
            ]))
        }
        return TIFF.encode(main, subdirectories)
    }

    // MARK: - Images

    private static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any]) throws -> [UInt8] {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { throw FixtureError.cannotEncode(type.identifier) }
        var properties = properties
        properties[kCGImageDestinationLossyCompressionQuality] = 0.7
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.cannotEncode(type.identifier) }
        return [UInt8](data as Data)
    }

    /// Sixteen small two-tone images, so neighbouring thumbnails differ.
    private static func palette() -> [CGImage] {
        let colors: [(UInt8, UInt8, UInt8)] = [
            (196, 64, 52), (226, 140, 48), (232, 196, 72), (120, 172, 72), (56, 140, 112), (48, 128, 180),
            (72, 88, 168), (128, 72, 160), (180, 72, 128), (120, 96, 72), (88, 88, 88), (168, 168, 160),
            (40, 72, 56), (200, 176, 140), (96, 152, 200), (232, 120, 120),
        ]
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return colors.indices.compactMap { index in
            guard let context = CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ) else { return nil }
            for (band, color) in [colors[index], colors[(index + 5) % colors.count]].enumerated() {
                context.setFillColor(
                    red: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255, blue: CGFloat(color.2) / 255, alpha: 1,
                )
                context.fill(CGRect(x: 0, y: band * (16 + index), width: 64, height: band == 0 ? 48 : 32 - index))
            }
            return context.makeImage()
        }
    }
}

/// TIFF image file directories, little-endian: the structure EXIF is written in.
enum TIFF {
    enum Value {
        case ascii(String)
        case short(UInt16)
        case long(UInt32)
        case rationals([(UInt32, UInt32)])
        case bytes([UInt8])
        case undefined([UInt8])

        /// Its type, count and bytes, as an entry records them.
        var encoded: (type: UInt16, count: Int, bytes: [UInt8]) {
            switch self {
            case let .ascii(text):
                let bytes = Array(text.utf8) + [0]
                return (2, bytes.count, bytes)
            case let .short(value): return (3, 1, littleEndian(value))
            case let .long(value): return (4, 1, littleEndian(value))
            case let .rationals(values):
                return (5, values.count, values.flatMap { littleEndian($0.0) + littleEndian($0.1) })
            case let .bytes(bytes): return (1, bytes.count, bytes)
            case let .undefined(bytes): return (7, bytes.count, bytes)
            }
        }
    }

    typealias Entry = (tag: UInt16, value: Value)

    /// IFD 0 with `main`'s entries and a pointer to each subdirectory, then the subdirectories,
    /// then every value too long to sit in its entry.
    static func encode(_ main: [Entry], _ subdirectories: [(pointer: UInt16, entries: [Entry])]) -> [UInt8] {
        var directories = [main + subdirectories.map { (tag: $0.pointer, value: Value.long(0)) }]
            + subdirectories.map(\.entries)
        var offsets: [Int] = []
        var end = 8
        for directory in directories {
            offsets.append(end)
            end += 2 + 12 * directory.count + 4
        }
        for (index, subdirectory) in subdirectories.enumerated() {
            if let entry = directories[0].firstIndex(where: { $0.tag == subdirectory.pointer }) {
                directories[0][entry].value = .long(UInt32(offsets[index + 1]))
            }
        }
        var bytes: [UInt8] = Array("II".utf8) + littleEndian(UInt16(42)) + littleEndian(UInt32(8))
        var values: [UInt8] = []
        for directory in directories {
            bytes += littleEndian(UInt16(directory.count))
            for (tag, value) in directory.sorted(by: { $0.tag < $1.tag }) {
                let (type, count, data) = value.encoded
                bytes += littleEndian(tag) + littleEndian(type) + littleEndian(UInt32(count))
                if data.count <= 4 {
                    bytes += data + Array(repeating: 0, count: 4 - data.count)
                } else {
                    bytes += littleEndian(UInt32(end + values.count))
                    values += data + (data.count % 2 == 1 ? [0] : [])
                }
            }
            bytes += littleEndian(UInt32(0))
        }
        return bytes + values
    }

    /// `value` as a fraction over `denominator`, reduced.
    static func rational(_ value: Double, _ denominator: UInt32) -> (UInt32, UInt32) {
        var numerator = UInt32((value * Double(denominator)).rounded())
        var denominator = denominator
        var a = numerator
        var b = denominator
        while b != 0 {
            (a, b) = (b, a % b)
        }
        if a > 1 {
            numerator /= a
            denominator /= a
        }
        return (numerator, denominator)
    }

    /// Degrees, minutes and seconds, as GPS tags hold a latitude or longitude.
    static func degrees(_ value: Double) -> [(UInt32, UInt32)] {
        let degrees = value.rounded(.down)
        let minutes = ((value - degrees) * 60).rounded(.down)
        let seconds = (value - degrees) * 3600 - minutes * 60
        return [(UInt32(degrees), 1), (UInt32(minutes), 1), rational(seconds, 10000)]
    }
}

/// Where a HEIF file's items are, from its `iinf` and `iloc` boxes: enough to find the Exif and
/// XMP items ImageIO writes, each one extent in the file.
struct HEIFItems {
    private let types: [Int: String]
    private let extents: [Int: Range<Int>]

    init(_ bytes: [UInt8]) {
        var types: [Int: String] = [:]
        var extents: [Int: Range<Int>] = [:]
        func number(_ offset: Int, _ size: Int) -> Int {
            guard size > 0, offset + size <= bytes.count else { return 0 }
            return bytes[offset ..< offset + size].reduce(0) { $0 << 8 | Int($1) }
        }
        func fourCC(_ offset: Int) -> String {
            String(decoding: bytes[offset ..< min(offset + 4, bytes.count)], as: UTF8.self)
        }
        func boxes(_ start: Int, _ end: Int, _ visit: (String, Int, Int) -> Void) {
            var offset = start
            while offset + 8 <= end {
                var size = number(offset, 4)
                var header = 8
                if size == 1 {
                    size = number(offset + 8, 8)
                    header = 16
                } else if size == 0 {
                    size = end - offset
                }
                guard size >= header else { return }
                visit(fourCC(offset + 4), offset + header, min(offset + size, end))
                offset += size
            }
        }
        boxes(0, bytes.count) { type, start, end in
            guard type == "meta" else { return }
            boxes(start + 4, end) { type, start, end in
                let version = Int(bytes[start])
                if type == "iinf" {
                    boxes(start + 4 + (version == 0 ? 2 : 4), end) { type, start, _ in
                        guard type == "infe", bytes[start] >= 2 else { return }
                        let idSize = bytes[start] == 2 ? 2 : 4
                        types[number(start + 4, idSize)] = fourCC(start + 4 + idSize + 2)
                    }
                } else if type == "iloc" {
                    let offsetSize = Int(bytes[start + 4] >> 4)
                    let lengthSize = Int(bytes[start + 4] & 15)
                    let baseSize = Int(bytes[start + 5] >> 4)
                    let indexSize = version > 0 ? Int(bytes[start + 5] & 15) : 0
                    let idSize = version < 2 ? 2 : 4
                    var at = start + 6
                    let count = number(at, idSize)
                    at += idSize
                    for _ in 0 ..< count {
                        let item = number(at, idSize)
                        at += idSize
                        let method = version > 0 ? number(at, 2) & 15 : 0
                        at += (version > 0 ? 2 : 0) + 2
                        let base = number(at, baseSize)
                        at += baseSize
                        let extentCount = number(at, 2)
                        at += 2
                        for _ in 0 ..< extentCount {
                            at += indexSize
                            let offset = number(at, offsetSize)
                            let length = number(at + offsetSize, lengthSize)
                            at += offsetSize + lengthSize
                            if method == 0, extentCount == 1 {
                                extents[item] = base + offset ..< base + offset + length
                            }
                        }
                    }
                }
            }
        }
        self.types = types
        self.extents = extents
    }

    /// The single extent of the first item of `type`, if it's in the file itself.
    func extent(ofType type: String) -> Range<Int>? {
        types.keys.sorted().first { types[$0] == type }.flatMap { extents[$0] }
    }
}

private func littleEndian(_ value: some FixedWidthInteger) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian, Array.init)
}

private func bigEndian(_ value: some FixedWidthInteger) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian, Array.init)
}
