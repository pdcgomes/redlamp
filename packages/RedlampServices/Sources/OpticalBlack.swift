import Foundation

/// Row and column banding measured in the sensor's optical-black margins (DN-03): masked
/// photosites beside and above the image, read out with it, so a row's or column's readout
/// offset shows in their mean. Subtracted with the black level.
public struct BandingCorrection: Sendable, Hashable {
    /// Per image row, in raw units; empty when rows need nothing.
    public var rows: [Float]
    /// Per image column, in raw units; empty when columns need nothing.
    public var columns: [Float]

    public init(rows: [Float], columns: [Float]) {
        self.rows = rows
        self.columns = columns
    }
}

enum OpticalBlack {
    /// Fewer masked photosites per line can't measure its offset below their own noise.
    static let minimumSamples = 16
    /// Photosites next to the image or the sensor edge may see light or edge effects.
    static let guardBand = 2
    /// Lines must vary this much more than their noise alone would make them.
    static let significance: Float = 1.5

    /// The correction for a mosaic from LibRaw's full sensor readout; nil where the margins are
    /// too narrow, aren't at the black level (not masked), or show no banding.
    static func measure(
        raw: UnsafePointer<UInt16>, pitch: Int, top: Int, left: Int, width: Int, height: Int,
        white: Float, black: (_ x: Int, _ y: Int) -> Float,
    ) -> BandingCorrection? {
        func residual(x: Int, y: Int) -> Float {
            Float(raw[(y + top) * pitch + x + left]) - black(x, y)
        }
        var rows: [Float] = []
        if left - 2 * guardBand >= minimumSamples {
            let rowSamples = (guardBand - left) ..< -guardBand
            let lines = (0 ..< height).map { y in rowSamples.map { residual(x: $0, y: y) } }
            rows = isBlack(lines, white: white) ? lineOffsets(lines) ?? [] : []
        }
        var columns: [Float] = []
        if top - 2 * guardBand >= minimumSamples {
            let columnSamples = (guardBand - top) ..< -guardBand
            let lines = (0 ..< width).map { x in columnSamples.map { residual(x: x, y: $0) } }
            columns = isBlack(lines, white: white) ? lineOffsets(lines) ?? [] : []
        }
        return rows.isEmpty && columns.isEmpty ? nil : BandingCorrection(rows: rows, columns: columns)
    }

    /// The residuals' median and robust noise sigma (median absolute deviation), from a sparse sample.
    static func robustLevel(_ lines: [[Float]]) -> (median: Float, sigma: Float) {
        let step = max(1, lines.count / 512)
        var values = stride(from: 0, to: lines.count, by: step).flatMap { lines[$0] }
        guard !values.isEmpty else { return (0, 0) }
        values.sort()
        let median = values[values.count / 2]
        var deviations = values.map { abs($0 - median) }
        deviations.sort()
        return (median, 1.4826 * deviations[deviations.count / 2])
    }

    /// Masked margins sit at the black level; anything else (image, dummy rows) isn't black.
    static func isBlack(_ lines: [[Float]], white: Float) -> Bool {
        let values = lines.flatMap(\.self)
        guard !values.isEmpty else { return false }
        let mean = values.reduce(0, +) / Float(values.count)
        let sigma = robustLevel(lines).sigma
        return abs(mean) <= max(2, sigma) && sigma < 0.02 * white
    }

    /// Each line's offset from the others, from its margin residuals (black subtracted). Samples
    /// beyond 5 sigmas are clipped first, so a hot photosite can't band its line. Estimates are
    /// shrunk by the share of their variance that is real (a Wiener estimate), so a line never
    /// gains more noise than banding it loses; nil when the lines vary little beyond noise.
    static func lineOffsets(_ lines: [[Float]]) -> [Float]? {
        guard lines.count > 2, let count = lines.first?.count, count >= 2 else { return nil }
        let (median, sigma) = robustLevel(lines)
        let limit = 5 * max(sigma, 1e-3)
        let clipped = lines.map { $0.map { min(max($0, median - limit), median + limit) } }
        let means = clipped.map { $0.reduce(0, +) / Float($0.count) }
        var within: Float = 0
        for (line, mean) in zip(clipped, means) {
            within += line.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        }
        let noise = within / Float(clipped.count * (count - 1)) / Float(count)
        let grand = means.reduce(0, +) / Float(means.count)
        let between = means.reduce(0) { $0 + ($1 - grand) * ($1 - grand) } / Float(means.count - 1)
        guard between > significance * noise else { return nil }
        let weight = (between - noise) / between
        return means.map { weight * ($0 - grand) }
    }
}
