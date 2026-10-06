import Foundation
import simd

/// A measurable summary of an image's style, independent of what it shows.
///
/// References and look-development photos show different scenes, so fingerprints compare
/// distributions (tone percentiles, tint of near-neutrals, chroma per hue band, grain,
/// vignetting), never pixels. They guide the fitter and the agents; they don't judge taste.
public struct StyleFingerprint: Codable, Sendable, Hashable {
    public static let version = 1
    /// Images are measured at this long edge.
    public static let analysisSize = 320
    public static let percentileLevels: [Double] = [0.01, 0.05, 0.25, 0.5, 0.75, 0.95, 0.99]

    /// OKLab lightness at `percentileLevels`.
    public var lightness: [Double]
    /// Mean deviation from a local average (radius 8 at analysis size).
    public var localContrast: Double
    /// Fraction of pixels brighter than L 0.97.
    public var clippedHighlights: Double
    /// Mean OKLab a/b of near-neutral pixels in shadows, midtones and highlights.
    public var shadowTint: [Double]
    public var midtoneTint: [Double]
    public var highlightTint: [Double]
    public var meanChroma: Double
    /// Per mixer band: mean chroma of its pixels, their circular-mean hue offset from the
    /// band centre in degrees, and the band's share of colorful pixels.
    public var bandChroma: [Double]
    public var bandHueOffset: [Double]
    public var bandShare: [Double]
    /// Fine-scale lightness noise in flat areas.
    public var grain: Double
    /// Centre lightness minus corner lightness.
    public var vignette: Double

    public var isMonochrome: Bool {
        meanChroma < 0.008
    }

    public init(_ image: PixelImage) {
        let w = image.width, h = image.height, n = w * h
        var labs = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0 ..< n {
            labs[i] = ColorMath.encodedSRGBToOKLab(simd_clamp(image.pixels[i], .zero, SIMD3(repeating: 1)))
        }
        let ls = labs.map { Double($0.x) }
        let sorted = ls.sorted()
        lightness = Self.percentileLevels.map { sorted[min(Int($0 * Double(n - 1)), n - 1)] }
        clippedHighlights = Double(ls.filter { $0 > 0.97 }.count) / Double(n)

        let blurred = Self.boxBlur(ls, width: w, height: h, radius: 8)
        let fine = Self.boxBlur(ls, width: w, height: h, radius: 1)
        var contrast = 0.0
        var grainSum = 0.0, grainCount = 0.0
        for i in 0 ..< n {
            contrast += abs(ls[i] - blurred[i])
            // Flat where the coarse and fine averages agree.
            if abs(fine[i] - blurred[i]) < 0.01 {
                grainSum += abs(ls[i] - fine[i])
                grainCount += 1
            }
        }
        localContrast = contrast / Double(n)
        grain = grainCount > 0 ? grainSum / grainCount : 0

        var zone = [[Double]](repeating: [0, 0, 0], count: 3)
        var chromaSum = 0.0
        var band = [(chroma: Double, x: Double, y: Double, count: Double)](repeating: (0, 0, 0, 0), count: 8)
        var colorful = 0.0
        let hues = LookSynthesizer.bandHues
        for lab in labs {
            let (l, c, hue) = ColorMath.lch(lab)
            chromaSum += Double(c)
            if c < 0.04 {
                let weight = Double(1 - c / 0.04)
                let z = l < 0.35 ? 0 : (l < 0.7 ? 1 : 2)
                zone[z][0] += Double(lab.y) * weight
                zone[z][1] += Double(lab.z) * weight
                zone[z][2] += weight
            } else {
                colorful += 1
                let nearest = (0 ..< 8)
                    .min { ColorMath.hueDistance(hue, hues[$0]) < ColorMath.hueDistance(hue, hues[$1]) }!
                let offset = Double(ColorMath.hueDelta(from: hues[nearest], to: hue)) * .pi / 180
                band[nearest].chroma += Double(c)
                band[nearest].x += cos(offset)
                band[nearest].y += sin(offset)
                band[nearest].count += 1
            }
        }
        func tint(_ z: Int) -> [Double] {
            zone[z][2] > 0 ? [zone[z][0] / zone[z][2], zone[z][1] / zone[z][2]] : [0, 0]
        }
        shadowTint = tint(0)
        midtoneTint = tint(1)
        highlightTint = tint(2)
        meanChroma = chromaSum / Double(n)
        bandChroma = band.map { $0.count > 0 ? $0.chroma / $0.count : 0 }
        bandHueOffset = band.map { $0.count > 0 ? atan2($0.y, $0.x) * 180 / .pi : 0 }
        bandShare = band.map { colorful > 0 ? $0.count / colorful : 0 }

        var centre = 0.0, centreCount = 0.0, corner = 0.0, cornerCount = 0.0
        for y in 0 ..< h {
            for x in 0 ..< w {
                let dx = (Double(x) + 0.5) / Double(w) - 0.5, dy = (Double(y) + 0.5) / Double(h) - 0.5
                let r = (dx * dx + dy * dy).squareRoot() / 0.7071
                if r < 0.35 {
                    centre += ls[y * w + x]
                    centreCount += 1
                } else if r > 0.85 {
                    corner += ls[y * w + x]
                    cornerCount += 1
                }
            }
        }
        vignette = centreCount > 0 && cornerCount > 0 ? centre / centreCount - corner / cornerCount : 0
    }

    public init(
        lightness: [Double], localContrast: Double, clippedHighlights: Double, shadowTint: [Double],
        midtoneTint: [Double], highlightTint: [Double], meanChroma: Double, bandChroma: [Double],
        bandHueOffset: [Double], bandShare: [Double], grain: Double, vignette: Double,
    ) {
        self.lightness = lightness
        self.localContrast = localContrast
        self.clippedHighlights = clippedHighlights
        self.shadowTint = shadowTint
        self.midtoneTint = midtoneTint
        self.highlightTint = highlightTint
        self.meanChroma = meanChroma
        self.bandChroma = bandChroma
        self.bandHueOffset = bandHueOffset
        self.bandShare = bandShare
        self.grain = grain
        self.vignette = vignette
    }

    /// The mean fingerprint of a set of images, for a style made of several references.
    public static func average(_ prints: [StyleFingerprint]) throws -> StyleFingerprint {
        guard let first = prints.first else { throw CocoaError(.featureUnsupported) }
        let count = Double(prints.count)
        func mean(_ key: (StyleFingerprint) -> Double) -> Double {
            prints.map(key).reduce(0, +) / count
        }
        func means(_ key: (StyleFingerprint) -> [Double]) -> [Double] {
            (0 ..< key(first).count).map { i in prints.map { key($0)[i] }.reduce(0, +) / count }
        }
        // Band hue offsets average weighted by each image's share of that band.
        let hueOffsets = (0 ..< 8).map { i -> Double in
            let weight = prints.map { $0.bandShare[i] }.reduce(0, +)
            return weight > 0 ? prints.map { $0.bandHueOffset[i] * $0.bandShare[i] }.reduce(0, +) / weight : 0
        }
        let chroma = (0 ..< 8).map { i -> Double in
            let weight = prints.map { $0.bandShare[i] }.reduce(0, +)
            return weight > 0 ? prints.map { $0.bandChroma[i] * $0.bandShare[i] }.reduce(0, +) / weight : 0
        }
        return StyleFingerprint(
            lightness: means(\.lightness), localContrast: mean(\.localContrast),
            clippedHighlights: mean(\.clippedHighlights), shadowTint: means(\.shadowTint),
            midtoneTint: means(\.midtoneTint), highlightTint: means(\.highlightTint), meanChroma: mean(\.meanChroma),
            bandChroma: chroma, bandHueOffset: hueOffsets, bandShare: means(\.bandShare), grain: mean(\.grain),
            vignette: mean(\.vignette),
        )
    }

    /// Weighted distance: roughly 1 per clearly visible difference in any one aspect.
    public func distance(to other: StyleFingerprint) -> Double {
        var sum = 0.0
        func add(_ a: Double, _ b: Double, _ scale: Double) {
            let d = (a - b) / scale
            sum += d * d
        }
        for (a, b) in zip(lightness, other.lightness) {
            add(a, b, 0.05)
        }
        add(localContrast, other.localContrast, 0.01)
        add(clippedHighlights, other.clippedHighlights, 0.05)
        for (a, b) in zip(
            shadowTint + midtoneTint + highlightTint,
            other.shadowTint + other.midtoneTint + other.highlightTint,
        ) {
            add(a, b, 0.008)
        }
        add(meanChroma, other.meanChroma, 0.015)
        for i in 0 ..< 8 {
            // Bands only count where both images have them.
            let presence = min(bandShare[i], other.bandShare[i]) * 8
            guard presence > 0.05 else { continue }
            let weight = min(presence, 1).squareRoot()
            add(bandChroma[i] * weight, other.bandChroma[i] * weight, 0.02)
            add(bandHueOffset[i] * weight, other.bandHueOffset[i] * weight, 6)
        }
        add(grain, other.grain, 0.004)
        add(vignette, other.vignette, 0.04)
        return (sum / 30).squareRoot()
    }

    /// The fingerprint as one flat vector, for clustering references.
    public var vector: [Double] {
        var v: [Double] = lightness.map { $0 / 0.05 }
        v.append(contentsOf: [localContrast / 0.01, clippedHighlights / 0.05])
        for tint in [shadowTint, midtoneTint, highlightTint] {
            v.append(contentsOf: tint.map { $0 / 0.008 })
        }
        v.append(meanChroma / 0.015)
        for (chroma, share) in zip(bandChroma, bandShare) {
            v.append(chroma * min(share * 8, 1) / 0.02)
        }
        v.append(contentsOf: [grain / 0.004, vignette / 0.04])
        return v
    }

    public var summary: String {
        let tone = lightness.map { String(format: "%.2f", $0) }.joined(separator: " ")
        let tints = [("shadows", shadowTint), ("mids", midtoneTint), ("highlights", highlightTint)]
            .map { "\($0.0) \(String(format: "%+.3f/%+.3f", $0.1[0], $0.1[1]))" }.joined(separator: ", ")
        return "L[\(tone)] contrast \(String(format: "%.3f", localContrast)) chroma \(String(format: "%.3f", meanChroma))"
            + " tint \(tints) grain \(String(format: "%.4f", grain)) vignette \(String(format: "%+.3f", vignette))"
            + (isMonochrome ? " (monochrome)" : "")
    }

    static func boxBlur(_ values: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        var integral = [Double](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0 ..< height {
            var row = 0.0
            for x in 0 ..< width {
                row += values[y * width + x]
                integral[(y + 1) * (width + 1) + x + 1] = integral[y * (width + 1) + x + 1] + row
            }
        }
        var result = [Double](repeating: 0, count: values.count)
        for y in 0 ..< height {
            let y0 = max(y - radius, 0), y1 = min(y + radius + 1, height)
            for x in 0 ..< width {
                let x0 = max(x - radius, 0), x1 = min(x + radius + 1, width)
                let sum = integral[y1 * (width + 1) + x1] - integral[y0 * (width + 1) + x1]
                    - integral[y1 * (width + 1) + x0] + integral[y0 * (width + 1) + x0]
                result[y * width + x] = sum / Double((x1 - x0) * (y1 - y0))
            }
        }
        return result
    }
}
