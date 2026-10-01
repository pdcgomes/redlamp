import Foundation
import RedlampEngineAPI

/// How big the exported file is. Each mode keeps its own value, so switching back and forth
/// doesn't lose what was typed.
public struct ExportSizing: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable, Hashable, CaseIterable {
        case full, longEdge, shortEdge, dimensions, megapixels, percentage

        public var name: String {
            switch self {
            case .full: "Full Size"
            case .longEdge: "Long Edge"
            case .shortEdge: "Short Edge"
            case .dimensions: "Width & Height"
            case .megapixels: "Megapixels"
            case .percentage: "Percentage"
            }
        }
    }

    public var mode: Mode = .full
    public var longEdge = 2048
    public var shortEdge = 1080
    public var width = 1920
    public var height = 1080
    public var megapixels = 12.0
    public var percentage = 50.0
    /// Pixels per inch, written to the file for print layouts; it doesn't change the pixels.
    public var ppi = 300

    public init(mode: Mode = .full) {
        self.mode = mode
    }

    /// Whether the current mode's values make a size.
    public var isValid: Bool {
        switch mode {
        case .full: true
        case .longEdge: longEdge >= 1
        case .shortEdge: shortEdge >= 1
        case .dimensions: width >= 1 && height >= 1
        case .megapixels: megapixels > 0
        case .percentage: percentage > 0 && percentage <= 100
        }
    }

    /// The exported size for a photo of `source` pixels. Never larger than the photo, and
    /// reached the way the engine fits a long edge, so the readout matches the file.
    public func resolve(_ source: PixelSize) -> PixelSize {
        guard let limit = maxLongEdge(for: source) else { return source }
        return Self.fit(source, longEdge: limit)
    }

    /// The `StillRequest.maxLongEdge` that renders `resolve(source)`; nil at full size.
    public func maxLongEdge(for source: PixelSize) -> Int? {
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = scale(for: source)
        guard scale.isFinite, scale < 1 else { return nil }
        let limit = adjusted(max(1, Int((Double(source.longEdge) * max(scale, 0)).rounded())), for: source)
        return limit < source.longEdge ? limit : nil
    }

    private func scale(for source: PixelSize) -> Double {
        let long = Double(source.longEdge)
        let short = Double(Self.shortEdge(of: source))
        return switch mode {
        case .full: 1
        case .longEdge: Double(longEdge) / long
        case .shortEdge: Double(shortEdge) / short
        case .dimensions: min(Double(width) / Double(source.width), Double(height) / Double(source.height))
        case .megapixels: (megapixels * 1_000_000 / (long * short)).squareRoot()
        case .percentage: percentage / 100
        }
    }

    /// Rounding the long edge can land the short edge a pixel off the one asked for, or a
    /// side a pixel outside the box; nudge it back.
    private func adjusted(_ limit: Int, for source: PixelSize) -> Int {
        switch mode {
        case .shortEdge:
            let target = max(1, shortEdge)
            return [limit, limit + 1, limit - 1].first { candidate in
                candidate >= 1 && Self.shortEdge(of: Self.fit(source, longEdge: candidate)) == target
            } ?? limit
        case .dimensions:
            var limit = limit
            while limit > 1 {
                let size = Self.fit(source, longEdge: limit)
                if size.width <= max(1, width), size.height <= max(1, height) {
                    break
                }
                limit -= 1
            }
            return limit
        default:
            return limit
        }
    }

    private static func fit(_ source: PixelSize, longEdge: Int) -> PixelSize {
        source.fitted(within: PixelSize(width: longEdge, height: longEdge))
    }

    private static func shortEdge(of size: PixelSize) -> Int {
        min(size.width, size.height)
    }
}

extension ExportSizing {
    private enum CodingKeys: String, CodingKey {
        case mode, longEdge, shortEdge, width, height, megapixels, percentage, ppi
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let defaults = ExportSizing()
        mode = value(.mode, defaults.mode)
        longEdge = max(1, value(.longEdge, defaults.longEdge))
        shortEdge = max(1, value(.shortEdge, defaults.shortEdge))
        width = max(1, value(.width, defaults.width))
        height = max(1, value(.height, defaults.height))
        megapixels = max(0.01, value(.megapixels, defaults.megapixels))
        percentage = min(max(value(.percentage, defaults.percentage), 1), 100)
        ppi = max(1, value(.ppi, defaults.ppi))
    }
}
