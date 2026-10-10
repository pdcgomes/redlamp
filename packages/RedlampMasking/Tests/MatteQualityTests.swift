import CoreGraphics
import Foundation
import RedlampEngineAPI
import simd
import Testing
@testable import RedlampMasking

/// The quality gate for the mattes Sky and Subject draw (MSK-25): scenes whose coverage is known
/// exactly, scored over the whole edge rather than at a pixel. The bounds sit a little above what
/// the mattes do today; a change that does better tightens them.
struct MatteQualityTests {
    typealias Segment = (start: SIMD2<Float>, end: SIMD2<Float>, width: Float)

    static let sky = SIMD3<Float>(110, 160, 235) / 255
    static let bark = SIMD3<Float>(45, 38, 30) / 255
    static let hair = SIMD3<Float>(0.15, 0.1, 0.08)
    static let wall = SIMD3<Float>(0.75, 0.8, 0.85)

    /// The share of each pixel that thick lines cover together, exact to 1/16.
    private func coverage(of segments: [Segment], width: Int, height: Int) -> [Float] {
        var hits = [Bool](repeating: false, count: width * height * 16)
        for segment in segments {
            let axis = segment.end - segment.start
            let length = simd_length_squared(axis)
            let reach = segment.width / 2 + 1
            let low = simd_max(simd_min(segment.start, segment.end) - reach, .zero)
            let high = simd_min(
                simd_max(segment.start, segment.end) + reach, SIMD2(Float(width - 1), Float(height - 1)),
            )
            for y in Int(low.y) ... Int(high.y) {
                for x in Int(low.x) ... Int(high.x) {
                    for sample in 0 ..< 16 {
                        let point = SIMD2(
                            Float(x) + (Float(sample % 4) + 0.5) / 4, Float(y) + (Float(sample / 4) + 0.5) / 4,
                        )
                        let t = length > 0 ? simd_clamp(simd_dot(point - segment.start, axis) / length, 0, 1) : 0
                        if simd_length(point - (segment.start + t * axis)) < segment.width / 2 {
                            hits[(y * width + x) * 16 + sample] = true
                        }
                    }
                }
            }
        }
        return (0 ..< width * height).map { index in
            Float(hits[index * 16 ..< index * 16 + 16].filter(\.self).count) / 16
        }
    }

    /// An 8-bit sRGB photo of `front` over `back`, mixed in linear light by `share`, as a lens
    /// mixes a strand with what is behind it.
    private func photo(
        width: Int, height: Int, share: [Float], front: SIMD3<Float>, back: (Int) -> SIMD3<Float>,
    ) throws -> CGImage {
        func linear(_ v: Float) -> Float {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        func encoded(_ v: Float) -> UInt8 {
            UInt8((v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055) * 255 + 0.5)
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0 ..< width * height {
            let behind = back(index / width)
            for channel in 0 ..< 3 {
                pixels[index * 4 + channel] = encoded(
                    share[index] * linear(front[channel]) + (1 - share[index]) * linear(behind[channel]),
                )
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
        ))
    }

    /// The matte's mean error where the truth is mixed and 2 px around it, and the share of the
    /// thin structure's pixels that the matte puts on the same side of a half as the truth.
    private func score(_ matte: GrayMask, truth: [Float], thin: [Bool]) -> (band: Float, recall: Float) {
        let width = matte.width
        var band = [Bool](repeating: false, count: truth.count)
        for index in truth.indices where truth[index] > 0.02 && truth[index] < 0.98 {
            for dy in -2 ... 2 {
                for dx in -2 ... 2 {
                    let (x, y) = (index % width + dx, index / width + dy)
                    if x >= 0, x < width, y >= 0, y < matte.height {
                        band[y * width + x] = true
                    }
                }
            }
        }
        let drawn = truth.indices.map { Float(matte[$0 % width, $0 / width]) / 255 }
        let error = truth.indices.filter { band[$0] }.map { abs(drawn[$0] - truth[$0]) }
        let thinPixels = truth.indices.filter { thin[$0] }
        let kept = thinPixels.filter { (drawn[$0] >= 0.5) == (truth[$0] >= 0.5) }
        return (error.reduce(0, +) / Float(error.count), Float(kept.count) / Float(thinPixels.count))
    }

    /// Twelve branches 0.5 to 3 px wide rising out of the ground into a sky the coarse mask has
    /// whole, as a model at a quarter of the size gives it.
    @Test func `the sky matte keeps branches out of the sky along their length`() throws {
        let (width, height, ground) = (600, 400, 320)
        let branches = coverage(of: (0 ..< 12).map { i in
            let x = Float(30 + 45 * i)
            return (
                SIMD2(x, Float(ground)), SIMD2(x + Float(i % 3 - 1) * 40, Float(40 + 17 * i)),
                0.5 + 2.5 * Float(i % 6) / 5,
            )
        }, width: width, height: height)
        let truth = branches.indices.map { $0 / width >= ground ? 0 : 1 - branches[$0] }
        let image = try photo(width: width, height: height, share: truth.map { 1 - $0 }, front: Self.bark) { y in
            Self.sky * (0.9 + 0.15 * Float(y) / Float(height))
        }
        let coarse = GrayMask(width: width / 4, height: height / 4, pixels: (0 ..< width * height / 16).map {
            $0 / (width / 4) < ground / 4 ? 255 : 0
        })
        let result = score(
            SkyMatte.refine(coarse, image: image), truth: truth,
            thin: branches.indices.map { branches[$0] > 0.5 && $0 / width < ground },
        )
        #expect(result.band < 0.02, "error along the branches: \(result.band)")
        #expect(result.recall > 0.98, "branches kept out of the sky: \(result.recall)")
    }

    /// A dark head with sixteen strands 0.5 to 2 px wide reaching 4 to 24 px over a light wall;
    /// the coarse mask, as Vision gives it, has the head and none of the strands. The matte is
    /// solved only within 2% of the long side past the coarse edge, and finds less of a strand the
    /// further it is from the head, so most strands stay out until flyaways are found another way
    /// (MSK-29).
    @Test func `the subject matte brings back strands that reach over the wall`() throws {
        let scene = try strandScene()
        let result = score(
            ClosedFormMatte.refine(scene.coarse, image: scene.image),
            truth: scene.truth,
            thin: scene.thin,
        )
        #expect(result.band < 0.055, "error along the head and strands: \(result.band)")
        #expect(result.recall > 0.28, "strands brought back: \(result.recall)")
    }

    /// ViTMatte, where this Mac has it (MSK-32): over its wider band it reaches the strands closed-
    /// form matting can't.
    @Test(.enabled(if: MatteQualityTests.vitMatte != nil))
    func `ViTMatte brings back more of the strands`() throws {
        let scene = try strandScene()
        let matte = try #require(Self.vitMatte).refine(scene.coarse, image: scene.image)
        let result = score(matte, truth: scene.truth, thin: scene.thin)
        #expect(result.band < 0.045, "error along the head and strands: \(result.band)")
        #expect(result.recall > 0.6, "strands brought back: \(result.recall)")
    }

    /// Closed-form's matte with only the strands ViTMatte finds beyond it, as the app makes them.
    @Test(.enabled(if: MatteQualityTests.vitMatte != nil))
    func `closed-form with ViTMatte's strands brings back more of them`() throws {
        let scene = try strandScene()
        let closed = ClosedFormMatte.refine(scene.coarse, image: scene.image)
        let matte = try ViTMatte.strands(
            of: #require(Self.vitMatte).refine(scene.coarse, image: scene.image),
            addedTo: closed,
        )
        let result = score(matte, truth: scene.truth, thin: scene.thin)
        #expect(result.band < 0.04, "error along the head and strands: \(result.band)")
        #expect(result.recall > 0.6, "strands brought back: \(result.recall)")
    }

    static let vitMatte: ViTMatte? = {
        guard let manifest = ModelCatalog.manifest("vitmatte-base") else { return nil }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Redlamp/Models/\(manifest.id)/\(manifest.version)")
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return try? ViTMatte(manifest: manifest, directory: directory)
    }()

    /// The head and its strands, the coarse mask, the true coverage and the strands' own pixels.
    private func strandScene() throws -> (image: CGImage, coarse: GrayMask, truth: [Float], thin: [Bool]) {
        let (width, height) = (600, 400)
        let centre = SIMD2<Float>(300, 260)
        let radius: Float = 120
        let head: Segment = (centre, centre, 2 * radius)
        let strands: [Segment] = (0 ..< 16).map { i in
            let angle = Float.pi * (1.1 + 0.8 * Float(i) / 15)
            let direction = SIMD2(cos(angle), sin(angle))
            return (
                centre + (radius - 4) * direction, centre + (radius + 4 + 5 * Float(i % 5)) * direction,
                0.5 + 0.5 * Float(i % 4),
            )
        }
        let truth = coverage(of: [head] + strands, width: width, height: height)
        let inHead = coverage(of: [head], width: width, height: height)
        let strandCoverage = coverage(of: strands, width: width, height: height)
        let image = try photo(width: width, height: height, share: truth, front: Self.hair) { _ in Self.wall }
        let coarse = GrayMask(width: width, height: height, coverage: (0 ..< width * height).map { index in
            let distance = simd_distance(SIMD2(Float(index % width), Float(index / width)), centre)
            return min(max((radius + 4 - distance) / 8, 0), 1)
        })
        return (image, coarse, truth, truth.indices.map { strandCoverage[$0] > 0.5 && inHead[$0] == 0 })
    }
}
