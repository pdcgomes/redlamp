import Foundation

/// One Heal or Clone spot, as in Lightroom's Remove tool: the circle at `center` is replaced
/// with the circle at `source`.
///
/// Points are `ImagePoint`s, so spots stay on the same content whatever the crop, Transform
/// or lens correction. Spots apply in order, each to the photo as the earlier ones left it.
public struct RetouchSpot: Codable, Sendable, Hashable, Identifiable {
    public enum Mode: String, Codable, Sendable, Hashable, CaseIterable {
        /// The source's texture, matched to the colour and brightness around the spot.
        case heal
        /// The source as it is.
        case clone

        public var name: String {
            switch self {
            case .heal: "Heal"
            case .clone: "Clone"
            }
        }
    }

    public var id: UUID
    public var mode: Mode
    public var center: ImagePoint
    public var source: ImagePoint
    /// A fraction of the image *height*, like radial mask radii.
    public var radius: Double
    /// 0...100: the share of the radius that fades out.
    public var feather: Double
    /// 0...100.
    public var opacity: Double

    public static let radiusRange = 0.002 ... 0.25

    public init(
        id: UUID = UUID(),
        mode: Mode = .heal,
        center: ImagePoint,
        source: ImagePoint,
        radius: Double,
        feather: Double = 50,
        opacity: Double = 100,
    ) {
        self.id = id
        self.mode = mode
        self.center = center
        self.source = source
        self.radius = radius
        self.feather = feather
        self.opacity = opacity
    }

    /// Whether the spot changes nothing.
    public var isEmpty: Bool {
        opacity <= 0 || radius <= 0 || center == source
    }
}
