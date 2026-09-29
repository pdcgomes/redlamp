import CoreGraphics
import Foundation
import IOSurface

/// An interactive render: the latest request always wins, older ones are dropped.
public struct RenderRequest: Sendable, Hashable {
    public var recipe: EditRecipe
    /// The rendered image is fitted inside this size (after orientation).
    public var targetSize: PixelSize
    /// Paint clipped highlights red and clipped shadows blue.
    public var showClipping: Bool
    /// Monotonic counter set by the caller so frames can be matched to requests.
    public var generation: UInt64

    public init(recipe: EditRecipe, targetSize: PixelSize, showClipping: Bool = false, generation: UInt64 = 0) {
        self.recipe = recipe
        self.targetSize = targetSize
        self.showClipping = showClipping
        self.generation = generation
    }
}

public enum OutputColorSpace: String, Sendable, Hashable, CaseIterable {
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
public struct StillRequest: Sendable, Hashable {
    public var recipe: EditRecipe
    /// Long edge limit in pixels; `nil` renders at full resolution.
    public var maxLongEdge: Int?
    public var colorSpace: OutputColorSpace
    public var bitsPerComponent: Int

    public init(
        recipe: EditRecipe,
        maxLongEdge: Int? = nil,
        colorSpace: OutputColorSpace = .sRGB,
        bitsPerComponent: Int = 8,
    ) {
        self.recipe = recipe
        self.maxLongEdge = maxLongEdge
        self.colorSpace = colorSpace
        self.bitsPerComponent = bitsPerComponent
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
    public let histogram: Histogram
    public let generation: UInt64
    public let renderDuration: Duration

    public init(
        surface: IOSurfaceRef,
        size: PixelSize,
        histogram: Histogram,
        generation: UInt64,
        renderDuration: Duration,
    ) {
        self.surface = surface
        self.size = size
        self.histogram = histogram
        self.generation = generation
        self.renderDuration = renderDuration
    }
}

public enum EngineError: Error, LocalizedError, Sendable {
    case noImageOpen
    case unsupportedFile(String)
    case decodeFailed(String)
    case gpuUnavailable
    case renderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noImageOpen: "No image is open."
        case let .unsupportedFile(name): "\(name) is not a supported image."
        case let .decodeFailed(reason): "The image could not be decoded: \(reason)"
        case .gpuUnavailable: "No Metal GPU is available."
        case let .renderFailed(reason): "Rendering failed: \(reason)"
        }
    }
}
