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
