import Foundation

/// What a file's first bytes say it holds (LIB-40): each format's signature, from the head the
/// indexer reads anyway. Most raws are TIFF inside, so they're one format here, whichever maker's
/// extension they carry.
public enum PhotoFormat: Int, Sendable, Hashable, CaseIterable, Codable {
    /// No signature this knows.
    case unknown = 0
    case jpeg = 1
    /// ISO base media with an image brand: HEIC and HEIF.
    case heif = 2
    case png = 3
    /// TIFF and the raws built on it: DNG, NEF, CR2, ARW, PEF, ORF, RW2 and the others.
    case tiff = 4
    /// ISO base media with Canon's `crx ` brand.
    case cr3 = 5
    /// Fujifilm's own container.
    case raf = 6
    /// Canon's CIFF.
    case crw = 7
    /// Minolta's own.
    case mrw = 8
    /// ISO base media with the AV1 image brand.
    case avif = 9
    case gif = 10
    case webp = 11

    /// The format `head` starts with.
    public init(head: Data) {
        self = head.withUnsafeBytes { Self.format(of: $0) }
    }

    private static func format(of bytes: UnsafeRawBufferPointer) -> PhotoFormat {
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + signature.count
                && signature.indices.allSatisfy { bytes[offset + $0] == signature[$0] }
        }
        if starts([0xFF, 0xD8, 0xFF]) {
            return .jpeg
        }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return .png
        }
        if starts(Array("ftyp".utf8), at: 4) {
            return brand(of: bytes)
        }
        if starts(Array("FUJIFILM".utf8)) {
            return .raf
        }
        if starts([0x49, 0x49, 0x1A, 0x00]), starts(Array("HEAPCCDR".utf8), at: 6) {
            return .crw
        }
        if starts([0x00, 0x4D, 0x52, 0x4D]) {
            return .mrw
        }
        // TIFF, BigTIFF, Olympus's ORF, Panasonic's RW2 and Phase One's IIQ.
        let tiff: [[UInt8]] = [
            [0x49, 0x49, 0x2A, 0x00], [0x4D, 0x4D, 0x00, 0x2A], [0x49, 0x49, 0x2B, 0x00], [0x4D, 0x4D, 0x00, 0x2B],
            [0x49, 0x49, 0x52, 0x4F], [0x49, 0x49, 0x52, 0x53], [0x4D, 0x4D, 0x4F, 0x52], [0x49, 0x49, 0x55, 0x00],
            Array("IIII".utf8), Array("MMMM".utf8),
        ]
        if tiff.contains(where: { starts($0) }) {
            return .tiff
        }
        if starts(Array("GIF8".utf8)) {
            return .gif
        }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) {
            return .webp
        }
        return .unknown
    }

    /// An ISO base media file's format by its `ftyp` box's brands, the major brand first.
    private static func brand(of bytes: UnsafeRawBufferPointer) -> PhotoFormat {
        let size = bytes.count >= 4 ? (0 ..< 4).reduce(0) { $0 << 8 | Int(bytes[$1]) } : 0
        var brands: [String] = []
        var offset = 8
        while offset + 4 <= min(max(size, 16), bytes.count, 256) {
            // The minor version sits between the major brand and the compatible ones.
            if offset != 12 {
                let brand = UnsafeRawBufferPointer(rebasing: bytes[offset ..< offset + 4])
                brands.append(String(decoding: brand, as: UTF8.self))
            }
            offset += 4
        }
        for brand in brands {
            switch brand {
            case "crx ": return .cr3
            case "avif", "avis": return .avif
            case "heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1": return .heif
            default: continue
            }
        }
        return .unknown
    }

    /// The formats a file named with `ext` may hold; nil for an extension too loosely used to say
    /// (`.raw`, `.kdc`) or one that isn't a photo's.
    public static func formats(forExtension ext: String) -> Set<PhotoFormat>? {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe": [.jpeg]
        case "heic", "heif", "hif": [.heif]
        case "avif": [.avif]
        case "png": [.png]
        case "tif", "tiff", "dng", "nef", "nrw", "cr2", "arw", "srf", "sr2", "pef", "orf", "rw2", "rwl", "srw", "3fr",
             "fff", "erf", "mef", "mos", "dcr", "iiq":
            [.tiff]
        case "cr3": [.cr3]
        case "raf": [.raf]
        case "crw": [.crw]
        case "mrw": [.mrw]
        default: nil
        }
    }

    /// Whether a file named `name` may hold this format: true for a format or an extension this
    /// doesn't know, so only a known format under another family's extension counts against it.
    public func fits(name: String) -> Bool {
        guard self != .unknown, let allowed = Self.formats(forExtension: (name as NSString).pathExtension) else {
            return true
        }
        return allowed.contains(self)
    }

    /// The format's name, as a reason gives it: "named .JPG, holds HEIC".
    public var title: String {
        switch self {
        case .unknown: "an unknown format"
        case .jpeg: "JPEG"
        case .heif: "HEIC"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .cr3: "a CR3 raw"
        case .raf: "a RAF raw"
        case .crw: "a CRW raw"
        case .mrw: "an MRW raw"
        case .avif: "AVIF"
        case .gif: "GIF"
        case .webp: "WebP"
        }
    }

    /// The extension a file of this format takes, in small letters, judging a TIFF-based raw from
    /// `head` (its first IFD's DNG version and maker, and Canon's and Olympus's and Panasonic's own
    /// signatures); nil where the library doesn't index the format or the head doesn't say which raw.
    public func proposedExtension(head: Data) -> String? {
        switch self {
        case .jpeg: "jpg"
        case .heif: "heic"
        case .png: "png"
        case .cr3: "cr3"
        case .raf: "raf"
        case .crw: "crw"
        case .mrw: "mrw"
        case .tiff: TIFFHead(head)?.proposedExtension
        case .unknown, .avif, .gif, .webp: nil
        }
    }
}
