import CoreGraphics
import Foundation

/// Reads what the library needs from photo files without developing them: in the Mac app, in the
/// sandboxed decode service, so a damaged or hostile file can only crash the service. Each call
/// takes a batch of files and answers in their order, nil for a file that can't be read.
public protocol FileInspecting: Sendable {
    /// The capture settings in each file's EXIF, read on all cores unless `concurrently` is false
    /// (for callers that already run their reads side by side).
    func captures(of urls: [URL], concurrently: Bool) -> [CaptureSettings?]

    /// Each file's grey thumbnail for focus-stack detection (`GreyThumbnail.longEdge`), as
    /// `captures(of:concurrently:)` reads.
    func focusThumbnails(of urls: [URL], concurrently: Bool) -> [GreyThumbnail?]

    /// Each file's ImageIO properties (its first image's EXIF, TIFF, GPS, IPTC and the rest), for
    /// an export to copy from its source or to tell an earlier export from a photo.
    func imageProperties(of urls: [URL]) -> [ImageProperties?]

    /// A HaldCLUT image's pixels, as a look table import reads them (see `HaldImage`); nil for a
    /// file that isn't an image.
    func haldImage(of url: URL) -> HaldImage?

    /// Each raw file's camera, raw mode and capture settings, as `RawFileInspecting.identify`
    /// reads them; nil for a file that isn't raw.
    func rawIdentities(of urls: [URL]) -> [RawFileIdentity?]

    /// Each raw file's largest embedded JPEG, the camera's own rendering, upright and at most
    /// `maxLongEdge` on its long edge, as `RawFileInspecting.cameraPreview` reads it.
    func cameraPreviews(of urls: [URL], maxLongEdge: Int) -> [CGImage?]
}

/// For readers that read no raw files.
public extension FileInspecting {
    func rawIdentities(of urls: [URL]) -> [RawFileIdentity?] {
        urls.map { _ in nil }
    }

    func cameraPreviews(of urls: [URL], maxLongEdge _: Int) -> [CGImage?] {
        urls.map { _ in nil }
    }
}

/// A reader that can read no file: for engines that read none, such as previews' and tests'.
public struct UnreadableFiles: FileInspecting {
    public init() {}

    public func captures(of urls: [URL], concurrently _: Bool) -> [CaptureSettings?] {
        urls.map { _ in nil }
    }

    public func focusThumbnails(of urls: [URL], concurrently _: Bool) -> [GreyThumbnail?] {
        urls.map { _ in nil }
    }

    public func imageProperties(of urls: [URL]) -> [ImageProperties?] {
        urls.map { _ in nil }
    }

    public func haldImage(of _: URL) -> HaldImage? {
        nil
    }
}

/// An image's pixels as a HaldCLUT import reads them: drawn into 16-bit RGBA in sRGB, alpha
/// premultiplied and last, each word little-endian, row after row. An image no HaldCLUT can be
/// (not square, or a side that isn't a level cubed), or one whose table has more points than a
/// look table holds (`LookTable.sizeRange`), has only its size.
public struct HaldImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgba16: Data

    public init(width: Int, height: Int, rgba16: Data) {
        self.width = width
        self.height = height
        self.rgba16 = rgba16
    }

    /// The level of a HaldCLUT `side` pixels square: a level³ × level³ image holding a
    /// level²-point table, for levels 2 to 16.
    public static func level(side: Int) -> Int? {
        (2 ... 16).first { $0 * $0 * $0 == side }
    }
}

/// A file's ImageIO properties, as a property list: only the values one can hold (strings,
/// numbers, data, dates, arrays and dictionaries of them) are kept.
public struct ImageProperties: Sendable, Equatable, Codable {
    public let propertyList: Data

    public init?(_ dictionary: [CFString: Any]) {
        guard let kept = Self.kept(dictionary as NSDictionary),
              let data = try? PropertyListSerialization.data(fromPropertyList: kept, format: .binary, options: 0)
        else { return nil }
        propertyList = data
    }

    public var dictionary: [CFString: Any] {
        (try? PropertyListSerialization.propertyList(from: propertyList, format: nil)) as? [CFString: Any] ?? [:]
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.dictionary as NSDictionary).isEqual(rhs.dictionary as NSDictionary)
    }

    private static func kept(_ value: Any) -> Any? {
        switch value {
        case is NSString, is NSNumber, is NSData, is NSDate:
            value
        case let array as NSArray:
            array.compactMap(kept)
        case let dictionary as NSDictionary:
            dictionary.reduce(into: [String: Any]()) { result, entry in
                if let key = entry.key as? String, let value = kept(entry.value) {
                    result[key] = value
                }
            }
        default:
            nil
        }
    }
}

/// The capture settings a focus stack keeps constant, and when the frame was taken.
public struct CaptureSettings: Sendable, Hashable, Codable {
    public var model: String?
    public var lens: String?
    public var focalLength: Double?
    public var aperture: Double?
    public var iso: Double?
    public var exposureTime: Double?
    /// DateTimeOriginal with its sub-second digits, in the camera's (unknown) time zone.
    public var date: Date?

    public init(
        model: String? = nil, lens: String? = nil, focalLength: Double? = nil, aperture: Double? = nil,
        iso: Double? = nil, exposureTime: Double? = nil, date: Date? = nil,
    ) {
        self.model = model
        self.lens = lens
        self.focalLength = focalLength
        self.aperture = aperture
        self.iso = iso
        self.exposureTime = exposureTime
        self.date = date
    }
}

/// A grey thumbnail, 0 to 1, rows top to bottom.
public struct GreyThumbnail: Sendable, Hashable {
    /// The long edge focus-stack detection compares frames at.
    public static let longEdge = 256

    public let width: Int
    public let height: Int
    public let pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// From one byte a pixel, as the reader draws it.
    public init(width: Int, height: Int, bytes: [UInt8]) {
        self.init(width: width, height: height, pixels: bytes.map { Float($0) / 255 })
    }
}
