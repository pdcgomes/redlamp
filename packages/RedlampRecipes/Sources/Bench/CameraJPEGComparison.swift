import CoreGraphics
import Foundation
import RedlampEngineAPI
import simd

/// Redlamp's default rendering of a raw against the JPEG the camera embedded in it (CAM-14).
/// The camera's JPEG carries its picture style, so these measure gross differences: which way
/// up, how it's framed, whether the structure matches, the exposure, a cast on what the camera
/// rendered neutral, and tinted highlights. Colours are compared, but only as a number to
/// read beside the others.
public struct CameraJPEGComparison: Sendable, Hashable {
    public static let analysisSize = 512

    /// Width over height of each, as rendered.
    public var ourAspect: Double
    public var theirAspect: Double
    /// Clockwise quarter turns of ours that best match theirs (0 when both are the same way up),
    /// and how much better that turn matches than none.
    public var quarterTurns: Int
    public var turnGain: Double
    /// Where theirs lands on ours, in fractions of the frame: `theirs = (ours - 0.5) * scale + 0.5 + offset`.
    public var scale: Double
    public var offsetX: Double
    public var offsetY: Double
    /// How alike the two frames' edges are after that (−1 to 1).
    public var correlation: Double
    /// Ours over theirs in midtones, in stops.
    public var exposure: Double?
    /// The mean OKLab a/b difference (× 100) where the camera rendered a neutral, and how many places.
    public var cast: Double?
    public var neutralSamples: Int
    /// The OKLab chroma (× 100) of ours where the camera's highlights are white, and how many places.
    public var highlightChroma: Double?
    public var highlightSamples: Int
    /// The mean OKLab ΔE (× 100) over flat areas once the exposure difference is taken out.
    public var colourDifference: Double?
    public var colourSamples: Int
    /// The camera's JPEG is black and white.
    public var monochrome: Bool

    public init?(ours: CGImage, theirs: CGImage) {
        guard let rendered = PixelImage(ours, maxLongEdge: Self.analysisSize),
              let camera = PixelImage(theirs, maxLongEdge: Self.analysisSize),
              rendered.width >= 32, rendered.height >= 32, camera.width >= 32, camera.height >= 32
        else { return nil }
        self.init(rendered, camera)
    }

    init(_ ours: PixelImage, _ theirs: PixelImage) {
        ourAspect = Double(ours.width) / Double(ours.height)
        theirAspect = Double(theirs.width) / Double(theirs.height)

        let turns = (0 ..< 4).map { PhotoPairAnalysis.similarity(Self.rotated(ours, quarterTurns: $0), theirs) }
        let best = turns.indices.max { turns[$0] < turns[$1] } ?? 0
        quarterTurns = best
        turnGain = Double(turns[best] - turns[0])

        let framed = PhotoPairAnalysis.cropped(ours, toAspect: Float(theirAspect))
        let alignment = LookProfiler.align(framed, theirs)
        scale = Double(alignment.scale)
        offsetX = Double(alignment.offset.x)
        offsetY = Double(alignment.offset.y)
        correlation = Double(alignment.correlation)

        let a = LookProfiler.blur(framed), b = LookProfiler.blur(theirs)
        var stops: [Float] = []
        var flat: [(SIMD3<Float>, SIMD3<Float>)] = []
        var neutral: [SIMD2<Float>] = []
        var highlights: [Float] = []
        var theirChroma: Float = 0
        var count: Float = 0
        for y in stride(from: Int(Float(a.height) * 0.08), to: Int(Float(a.height) * 0.92), by: 2) {
            for x in stride(from: Int(Float(a.width) * 0.08), to: Int(Float(a.width) * 0.92), by: 2) {
                let u = (Float(x) + 0.5) / Float(a.width), v = (Float(y) + 0.5) / Float(a.height)
                let cu = (u - 0.5) * alignment.scale + 0.5 + alignment.offset.x
                let cv = (v - 0.5) * alignment.scale + 0.5 + alignment.offset.y
                guard (0.02 ... 0.98).contains(cu), (0.02 ... 0.98).contains(cv) else { continue }
                let mine = a[x, y]
                let camera = LookProfiler.bilinear(b, cu * Float(b.width) - 0.5, cv * Float(b.height) - 0.5)
                let ourLab = ColorMath.encodedSRGBToOKLab(simd_clamp(mine, .zero, SIMD3(repeating: 1)))
                let theirLab = ColorMath.encodedSRGBToOKLab(simd_clamp(camera, .zero, SIMD3(repeating: 1)))
                let theirC = simd_length(SIMD2(theirLab.y, theirLab.z))
                theirChroma += theirC
                count += 1
                if theirLab.x > 0.93, theirC < 0.025, ourLab.x > 0.85 {
                    highlights.append(simd_length(SIMD2(ourLab.y, ourLab.z)))
                }
                // Areas the camera rendered flat, so a pixel of misalignment doesn't change the
                // colour; judged on the camera's, since a broken decode is never flat.
                let bx = cu * Float(b.width) - 0.5, by = cv * Float(b.height) - 0.5
                let gradient = simd_length(LookProfiler.bilinear(b, bx + 2, by) - LookProfiler.bilinear(b, bx - 2, by))
                    + simd_length(LookProfiler.bilinear(b, bx, by + 2) - LookProfiler.bilinear(b, bx, by - 2))
                guard gradient < 0.06, camera.max() < 0.97, camera.min() > 0.015 else { continue }
                // Any colour of ours counts against a neutral of theirs: a broken decode's are extreme.
                if theirC < 0.02, (0.3 ... 0.9).contains(theirLab.x) {
                    neutral.append(SIMD2(ourLab.y - theirLab.y, ourLab.z - theirLab.z))
                }
                guard mine.max() < 0.97, mine.min() > 0.015 else { continue }
                let ourY = PhotoPairAnalysis.luma(ColorMath.srgbDecode(mine))
                let theirY = PhotoPairAnalysis.luma(ColorMath.srgbDecode(camera))
                if (0.02 ... 0.6).contains(theirY) {
                    stops.append(log2(ourY / theirY))
                }
                flat.append((mine, camera))
            }
        }
        monochrome = count > 0 && theirChroma / count < 0.008
        exposure = stops.count >= 50 ? Double(Self.median(stops)) : nil

        neutralSamples = neutral.count
        cast = !monochrome && neutral.count >= 40
            ? Double(simd_length(neutral.reduce(.zero, +) / Float(neutral.count))) * 100 : nil
        highlightSamples = highlights.count
        highlightChroma = highlights.count >= 30 ? Double(highlights.reduce(0, +) / Float(highlights.count)) * 100 : nil

        colourSamples = flat.count
        if !monochrome, flat.count >= 50 {
            let gain = exp2(-Float(exposure ?? 0))
            let differences = flat.map { mine, camera in
                let matched = ColorMath.srgbEncode(simd_clamp(
                    ColorMath.srgbDecode(mine) * gain,
                    .zero,
                    SIMD3(repeating: 1),
                ))
                return simd_distance(ColorMath.encodedSRGBToOKLab(matched), ColorMath.encodedSRGBToOKLab(camera))
            }
            colourDifference = Double(differences.reduce(0, +) / Float(differences.count)) * 100
        } else {
            colourDifference = nil
        }
    }

    /// `image` turned clockwise by quarter turns.
    static func rotated(_ image: PixelImage, quarterTurns: Int) -> PixelImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let (w, h) = (image.width, image.height)
        let size = turns == 2 ? (w, h) : (h, w)
        var pixels = [SIMD3<Float>](repeating: .zero, count: w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let (nx, ny) = switch turns {
                case 1: (h - 1 - y, x)
                case 2: (w - 1 - x, h - 1 - y)
                default: (y, w - 1 - x)
                }
                pixels[ny * size.0 + nx] = image[x, y]
            }
        }
        return PixelImage(width: size.0, height: size.1, pixels: pixels)
    }

    static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
