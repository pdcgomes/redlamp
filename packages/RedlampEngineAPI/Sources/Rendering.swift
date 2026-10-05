import CoreGraphics
import Foundation
import IOSurface

/// A rectangle in normalized image coordinates, after orientation: (0, 0) is the top-left
/// corner of the photo as displayed and (1, 1) the bottom-right.
public struct ImageRect: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = ImageRect(x: 0, y: 0, width: 1, height: 1)
}

/// An interactive render: the latest request always wins, older ones are dropped.
public struct RenderRequest: Sendable, Hashable {
    public var recipe: EditRecipe
    /// Without a `region`, the whole photo is fitted inside this size (after orientation).
    /// With one, the region is rendered at exactly this size.
    public var targetSize: PixelSize
    /// Renders only this part of the photo, for example the visible part at 1:1. The frame's
    /// histogram still describes the whole photo.
    public var region: ImageRect?
    /// Paint clipped highlights red and clipped shadows blue.
    public var showClipping: Bool
    /// Paint photosites the sensor clipped, in the colour of each clipped channel (black where
    /// all three clipped), whatever the edit has done to them since.
    public var showRawClipping = false
    /// Tints this mask's coverage (Lightroom's mask overlay).
    public var maskOverlay: UUID?
    public var maskOverlayColor: MaskOverlayColor = .red
    public var maskOverlayStyle: MaskOverlayStyle = .colorOverlay
    /// How strongly the tinting modes (Color Overlay, Color Overlay on B&W, the luminance map) tint
    /// the mask, 0...1.
    public var maskOverlayOpacity = MaskOverlayStyle.defaultOpacity
    /// Shows the photo as Lightroom's Visualize Spots does, white where it differs from a wider
    /// blur of itself, so dust and specks stand out, at this sensitivity (0...100). The overview
    /// and the histogram still show the photo.
    public var visualizeSpots: Double?
    /// Also renders this recipe at the same size and region (the "before" of a before/after
    /// view). It is re-rendered only when it, the geometry or clipping change, so edits to
    /// `recipe` cost no more than without it.
    public var comparison: EditRecipe?
    /// Monotonic counter set by the caller so frames can be matched to requests.
    public var generation: UInt64

    public init(
        recipe: EditRecipe,
        targetSize: PixelSize,
        region: ImageRect? = nil,
        showClipping: Bool = false,
        maskOverlay: UUID? = nil,
        generation: UInt64 = 0,
    ) {
        self.recipe = recipe
        self.targetSize = targetSize
        self.region = region
        self.showClipping = showClipping
        self.maskOverlay = maskOverlay
        self.generation = generation
    }
}

/// How the selected mask is shown: Lightroom's overlay modes, plus the luminance map that
/// Luminance Range shows while it is edited.
public enum MaskOverlayStyle: Int, Sendable, Hashable, CaseIterable {
    case colorOverlay, colorOverlayOnBlackAndWhite, imageOnBlack, imageOnWhite, blackAndWhite, luminanceMap
    case imageOnBlackAndWhite

    public var name: String {
        switch self {
        case .colorOverlay: "Color Overlay"
        case .colorOverlayOnBlackAndWhite: "Color Overlay on B&W"
        case .imageOnBlack: "Image on Black"
        case .imageOnWhite: "Image on White"
        case .blackAndWhite: "B&W"
        case .luminanceMap: "Luminance Map"
        case .imageOnBlackAndWhite: "Image on B&W"
        }
    }

    /// The modes offered in the overlay menu, in Lightroom's order (the luminance map belongs to
    /// Luminance Range).
    public static let menu: [MaskOverlayStyle] = [
        .colorOverlay, .colorOverlayOnBlackAndWhite, .imageOnBlack, .imageOnWhite, .blackAndWhite,
        .imageOnBlackAndWhite,
    ]

    /// Whether the mode tints the mask, so the overlay's opacity applies.
    public var tints: Bool {
        switch self {
        case .colorOverlay, .colorOverlayOnBlackAndWhite, .luminanceMap: true
        case .imageOnBlack, .imageOnWhite, .blackAndWhite, .imageOnBlackAndWhite: false
        }
    }

    /// The tint's opacity until it's changed.
    public static let defaultOpacity = 0.55
}

/// Mask overlay colors, cycled with Shift-O as in Lightroom.
public enum MaskOverlayColor: Int, Sendable, Hashable, CaseIterable {
    case red, green, blue, white

    public var next: MaskOverlayColor {
        MaskOverlayColor(rawValue: (rawValue + 1) % MaskOverlayColor.allCases.count) ?? .red
    }

    public var name: String {
        switch self {
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        case .white: "White"
        }
    }
}

public enum OutputColorSpace: String, Codable, Sendable, Hashable, CaseIterable {
    case sRGB
    case displayP3

    public var name: String {
        switch self {
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        }
    }
}

/// A full-quality render for export or for the CLI.
/// What a still is for, which decides how a reduced size is reached.
public enum StillPurpose: Sendable, Hashable {
    /// Rendered straight at the requested size: fast, for thumbnails and previews.
    case preview
    /// Processed at full resolution and downscaled last, so sharpening, noise reduction and
    /// texture look the same at every export size.
    case export
}

public struct StillRequest: Sendable, Hashable {
    public var recipe: EditRecipe
    /// Long edge limit in pixels; `nil` renders at full resolution.
    public var maxLongEdge: Int?
    public var colorSpace: OutputColorSpace
    public var bitsPerComponent: Int
    public var purpose: StillPurpose
    /// The image this still is of. When set, the render fails with `imageChanged` if another
    /// image has been opened since, rather than rendering that one.
    public var source: URL?

    public init(
        recipe: EditRecipe,
        maxLongEdge: Int? = nil,
        colorSpace: OutputColorSpace = .sRGB,
        bitsPerComponent: Int = 8,
        purpose: StillPurpose = .preview,
    ) {
        self.recipe = recipe
        self.maxLongEdge = maxLongEdge
        self.colorSpace = colorSpace
        self.bitsPerComponent = bitsPerComponent
        self.purpose = purpose
    }
}

/// Per-channel histogram of the rendered, display-encoded image.
public struct Histogram: Sendable, Hashable {
    public static let binCount = 256

    public var red: [UInt32]
    public var green: [UInt32]
    public var blue: [UInt32]
    public var luminance: [UInt32]

    public init(red: [UInt32], green: [UInt32], blue: [UInt32], luminance: [UInt32]) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luminance = luminance
    }

    public static let empty = Histogram(
        red: .init(repeating: 0, count: binCount),
        green: .init(repeating: 0, count: binCount),
        blue: .init(repeating: 0, count: binCount),
        luminance: .init(repeating: 0, count: binCount),
    )

    public var totalCount: UInt64 {
        luminance.reduce(0) { $0 + UInt64($1) }
    }

    /// Whether a visible fraction of pixels is clipped at the top in any channel.
    public var highlightsClipped: Bool {
        let threshold = max(UInt64(1), totalCount / 2000)
        return [red, green, blue].contains { UInt64($0[Histogram.binCount - 1]) > threshold }
    }

    /// Whether a visible fraction of pixels is clipped to black in any channel.
    public var shadowsClipped: Bool {
        let threshold = max(UInt64(1), totalCount / 2000)
        return [red, green, blue].contains { UInt64($0[0]) > threshold }
    }
}

/// A rendered frame, delivered as an IOSurface so it crosses the engine/UI boundary
/// without copying pixels.
public struct RenderedFrame: @unchecked Sendable {
    /// `RGhA` (RGBA float16), linear extended Display P3.
    public let surface: IOSurfaceRef
    public let size: PixelSize
    /// The part of the photo the surface shows.
    public let region: ImageRect
    /// With a region, a small render of the whole photo (same format), for showing behind the
    /// region while the view pans.
    public let overview: IOSurfaceRef?
    public let overviewSize: PixelSize
    /// The request's `comparison` recipe, rendered like `surface` (same size and region).
    public let comparison: IOSurfaceRef?
    /// With a region, the comparison's whole-photo render, like `overview`.
    public let comparisonOverview: IOSurfaceRef?
    /// Describes `surface` only.
    public let histogram: Histogram
    public let generation: UInt64
    public let renderDuration: Duration

    public init(
        surface: IOSurfaceRef,
        size: PixelSize,
        region: ImageRect = .full,
        overview: IOSurfaceRef? = nil,
        overviewSize: PixelSize = .zero,
        comparison: IOSurfaceRef? = nil,
        comparisonOverview: IOSurfaceRef? = nil,
        histogram: Histogram,
        generation: UInt64,
        renderDuration: Duration,
    ) {
        self.surface = surface
        self.size = size
        self.region = region
        self.overview = overview
        self.overviewSize = overviewSize
        self.comparison = comparison
        self.comparisonOverview = comparisonOverview
        self.histogram = histogram
        self.generation = generation
        self.renderDuration = renderDuration
    }
}

public enum EngineError: Error, LocalizedError, Codable, Sendable {
    case noImageOpen
    case unsupportedFile(String)
    case decodeFailed(String)
    /// A format Redlamp knows and plans to read, named in the plural ("JPEG XL mosaic DNGs"), with
    /// the tracker row that will add it.
    case notSupportedYet(String, tracker: String)
    case gpuUnavailable
    case renderFailed(String)
    case imageChanged
    /// Generative fill can't run here, and why.
    case generativeFillUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .noImageOpen: "No image is open."
        case .imageChanged: "Another photo was opened before this one could be rendered."
        case let .unsupportedFile(name): "\(name) is not a supported image."
        case let .decodeFailed(reason): "The image could not be decoded: \(reason)"
        case let .notSupportedYet(formats, _): "\(formats) aren't supported yet."
        case .gpuUnavailable: "No Metal GPU is available."
        case let .renderFailed(reason): "Rendering failed: \(reason)"
        case let .generativeFillUnavailable(reason): reason
        }
    }

    /// The tracker row that will add the format, for a format that isn't supported yet.
    public var notSupportedYetTracker: String? {
        if case let .notSupportedYet(_, tracker) = self {
            tracker
        } else {
            nil
        }
    }
}
