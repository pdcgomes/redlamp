import CoreGraphics
import Foundation

/// How a focus stack's frames are combined.
public enum FocusStackStrategy: String, Sendable, Hashable, Codable, CaseIterable {
    /// Coarse tone and colour from the depth map, fine detail from the sharpest frames near it.
    case auto
    /// A soft blend between the two frames around the depth map: clean on smooth surfaces.
    case smooth
    /// The sharpest detail from any frame at every scale: hair and bristles, more noise and halos.
    case detail
}

/// A focus stack as a file (`.redlampstack`, JSON) beside its frames: the recipe for the merge,
/// which the engine opens like any photo. The merged pixels live in a cache and are rebuilt
/// from the frames when missing.
public struct FocusStackDocument: Codable, Sendable, Hashable {
    public static let fileExtension = "redlampstack"

    public var version = 1
    /// Frame paths in focus order, relative to the document's folder when inside it.
    public var frames: [String]
    public var strategy: FocusStackStrategy

    public init(frames: [String], strategy: FocusStackStrategy = .auto) {
        self.frames = frames
        self.strategy = strategy
    }

    /// A document at `url` for `frames`, storing each path relative to `url`'s folder.
    public init(frames: [URL], strategy: FocusStackStrategy = .auto, at url: URL) {
        let folder = url.deletingLastPathComponent().standardizedFileURL.path
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        let paths = frames.map { frame in
            let path = frame.standardizedFileURL.path
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
        self.init(frames: paths, strategy: strategy)
    }

    /// The frames of the document at `url`.
    public func frameURLs(at url: URL) -> [URL] {
        let folder = url.deletingLastPathComponent()
        return frames.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : folder.appendingPathComponent($0) }
    }

    public static func read(_ url: URL) throws -> FocusStackDocument {
        try JSONDecoder().decode(FocusStackDocument.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// What a merge found and how long it took.
public struct FocusStackReport: Sendable, Hashable, Codable {
    public var frames: Int
    /// Index of the reference frame (the narrowest field of view) in the given order.
    public var reference: Int
    /// Fused size before orientation, in pixels.
    public var width: Int
    public var height: Int
    /// The largest magnification difference between a frame and the reference (focus breathing).
    public var maximumScaleChange: Double
    /// The lowest correlation of a frame with the reference after alignment.
    public var minimumCorrelation: Double
    /// The share of the depth map solved with confidence.
    public var confidentDepthFraction: Double
    /// Seconds per phase: decode, align, depth, fuse, total.
    public var timings: [String: Double]

    public init(
        frames: Int, reference: Int, width: Int, height: Int, maximumScaleChange: Double,
        minimumCorrelation: Double, confidentDepthFraction: Double, timings: [String: Double],
    ) {
        self.frames = frames
        self.reference = reference
        self.width = width
        self.height = height
        self.maximumScaleChange = maximumScaleChange
        self.minimumCorrelation = minimumCorrelation
        self.confidentDepthFraction = confidentDepthFraction
        self.timings = timings
    }
}

/// A merged focus stack rendered for viewing, with its depth map.
public struct FocusStackPreview: Sendable {
    /// The fused photo developed with the default edit, oriented.
    public var image: CGImage
    /// Which frame is sharpest where (black = first frame, white = last), oriented.
    public var depth: CGImage
    public var report: FocusStackReport

    public init(image: CGImage, depth: CGImage, report: FocusStackReport) {
        self.image = image
        self.depth = depth
        self.report = report
    }
}
