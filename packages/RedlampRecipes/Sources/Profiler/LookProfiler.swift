import CoreGraphics
import Foundation
import RedlampEngineAPI
import simd

/// Fits a Base Look to a camera's own renderings: raw files paired with the JPEGs the
/// camera made from them.
///
/// For each pair the raw is rendered neutrally (Redlamp Color, as-shot white balance), the
/// two frames are aligned (the camera corrects lens distortion and crops slightly), and
/// color correspondences are taken away from edges, corners (the camera corrects
/// vignetting) and clipped areas. A table is fitted to all of them, and cross-validated by
/// leaving scenes out, so the reported error is on photos the fit never saw.
public final class LookProfiler {
    public struct Pair: Sendable {
        public var raw: URL
        /// Pairs from the same scene share a group, so validation never trains on a scene
        /// it then tests on.
        public var scene: String

        public init(raw: URL, scene: String) {
            self.raw = raw
            self.scene = scene
        }
    }

    public struct Alignment: Sendable {
        public var scale: Float
        public var offset: SIMD2<Float>
        public var correlation: Float
    }

    public struct Report: Sendable {
        public var table: LookTable
        public var smoothness: Float
        public var scenes: Int
        public var samples: Int
        /// Held-out ΔE (OKLab × 100): no look, the look it replaces, and the fitted look.
        public var neutral: (mean: Double, p90: Double)
        public var previous: (mean: Double, p90: Double)?
        public var fitted: (mean: Double, p90: Double)
        public var alignments: [String: Alignment]
    }

    public static let analysisSize = 512
    private let renderer: RecipeRenderer

    public init(renderer: RecipeRenderer) {
        self.renderer = renderer
    }

    // MARK: - Samples

    public func samples(
        for pair: Pair,
        perBin: Int = 24,
    ) async throws -> (samples: [ProfileSample], alignment: Alignment) {
        let rendered = try await renderer.render(nil, image: pair.raw, maxLongEdge: Self.analysisSize, sixteenBit: true)
        let camera = try CameraJPEG.extract(from: pair.raw, maxLongEdge: Self.analysisSize)
        guard let ours = PixelImage(rendered),
              let theirs = PixelImage(camera) else { throw CameraJPEG.Failure.unreadable }
        let alignment = Self.align(ours, theirs)
        let a = Self.blur(ours), b = Self.blur(theirs)
        var bins: [Int: Int] = [:]
        var samples: [ProfileSample] = []
        for y in stride(from: Int(Float(a.height) * 0.12), to: Int(Float(a.height) * 0.88), by: 2) {
            for x in stride(from: Int(Float(a.width) * 0.12), to: Int(Float(a.width) * 0.88), by: 2) {
                let input = a[x, y]
                guard input.max() < 0.97, input.min() > 0.015 else { continue }
                // Flat areas only: misalignment by a pixel shouldn't change the color.
                let gradient = simd_length(a[min(x + 2, a.width - 1), y] - a[max(x - 2, 0), y])
                    + simd_length(a[x, min(y + 2, a.height - 1)] - a[x, max(y - 2, 0)])
                guard gradient < 0.06 else { continue }
                let u = (Float(x) + 0.5) / Float(a.width), v = (Float(y) + 0.5) / Float(a.height)
                let cu = (u - 0.5) * alignment.scale + 0.5 + alignment.offset.x
                let cv = (v - 0.5) * alignment.scale + 0.5 + alignment.offset.y
                guard (0.02 ... 0.98).contains(cu), (0.02 ... 0.98).contains(cv) else { continue }
                let target = Self.bilinear(b, cu * Float(b.width) - 0.5, cv * Float(b.height) - 0.5)
                guard target.max() < 0.97, target.min() > 0.015 else { continue }
                // Cap samples per color cell, so a big sky can't outvote everything else.
                let cell = SIMD3<Int>(simd_clamp(input * 12, .zero, SIMD3(repeating: 11.99)))
                let key = (cell.x * 12 + cell.y) * 12 + cell.z
                guard bins[key, default: 0] < perBin else { continue }
                bins[key, default: 0] += 1
                samples.append(ProfileSample(input: Self.toWorking(input), target: Self.toWorking(target)))
            }
        }
        return (samples, alignment)
    }

    /// Encoded sRGB (what renders and JPEGs hold) to Redlamp's table space.
    static func toWorking(_ srgb: SIMD3<Float>) -> SIMD3<Float> {
        ColorMath.srgbEncode(simd_max(ColorMath.rec709ToRec2020 * ColorMath.srgbDecode(srgb), .zero))
    }

    // MARK: - Alignment

    /// The scale and offset that best overlay the camera's frame on ours, by correlating
    /// luminance gradients: coarse at quarter size, then refined.
    static func align(_ ours: PixelImage, _ theirs: PixelImage) -> Alignment {
        let a = edges(downsample(ours, to: 256)), b = edges(downsample(theirs, to: 256))
        func score(_ s: Float, _ d: SIMD2<Float>) -> Float {
            var sab: Float = 0, saa: Float = 0, sbb: Float = 0, sa: Float = 0, sb: Float = 0, count: Float = 0
            for y in stride(from: Int(Float(a.height) * 0.1), to: Int(Float(a.height) * 0.9), by: 2) {
                for x in stride(from: Int(Float(a.width) * 0.1), to: Int(Float(a.width) * 0.9), by: 2) {
                    let u = ((Float(x) + 0.5) / Float(a.width) - 0.5) * s + 0.5 + d.x
                    let v = ((Float(y) + 0.5) / Float(a.height) - 0.5) * s + 0.5 + d.y
                    let p = a.values[y * a.width + x]
                    let q = bilinear(b, u * Float(b.width) - 0.5, v * Float(b.height) - 0.5)
                    sab += p * q
                    saa += p * p
                    sbb += q * q
                    sa += p
                    sb += q
                    count += 1
                }
            }
            let cov = sab / count - (sa / count) * (sb / count)
            let va = saa / count - (sa / count) * (sa / count), vb = sbb / count - (sb / count) * (sb / count)
            return cov / max((va * vb).squareRoot(), 1e-9)
        }
        var best = Alignment(scale: 1, offset: .zero, correlation: score(1, .zero))
        let pixel = 1 / Float(a.width)
        for s in stride(from: Float(0.92), through: 1.08, by: 0.01) {
            for dy in stride(from: -8, through: 8, by: 2) {
                for dx in stride(from: -8, through: 8, by: 2) {
                    let d = SIMD2(Float(dx), Float(dy)) * pixel
                    let c = score(s, d)
                    if c > best.correlation {
                        best = Alignment(scale: s, offset: d, correlation: c)
                    }
                }
            }
        }
        let coarse = best
        for s in stride(from: coarse.scale - 0.01, through: coarse.scale + 0.01, by: 0.0025) {
            for dy in stride(from: -2, through: 2, by: 0.5) {
                for dx in stride(from: -2, through: 2, by: 0.5) {
                    let d = coarse.offset + SIMD2(Float(dx), Float(dy)) * pixel
                    let c = score(s, d)
                    if c > best.correlation {
                        best = Alignment(scale: s, offset: d, correlation: c)
                    }
                }
            }
        }
        return best
    }

    struct Plane {
        var width: Int
        var height: Int
        var values: [Float]
    }

    static func downsample(_ image: PixelImage, to width: Int) -> PixelImage {
        let height = max(1, Int(Float(image.height) * Float(width) / Float(image.width)))
        var pixels = [SIMD3<Float>](repeating: .zero, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                pixels[y * width + x] = bilinear(
                    image, (Float(x) + 0.5) * Float(image.width) / Float(width) - 0.5,
                    (Float(y) + 0.5) * Float(image.height) / Float(height) - 0.5,
                )
            }
        }
        return PixelImage(width: width, height: height, pixels: pixels)
    }

    static func edges(_ image: PixelImage) -> Plane {
        let luma = image.pixels.map { simd_dot($0, ColorMath.rec709Luma) }
        var values = [Float](repeating: 0, count: luma.count)
        for y in 1 ..< image.height - 1 {
            for x in 1 ..< image.width - 1 {
                let i = y * image.width + x
                values[i] = abs(luma[i + 1] - luma[i - 1]) + abs(luma[i + image.width] - luma[i - image.width])
            }
        }
        return Plane(width: image.width, height: image.height, values: values)
    }

    static func blur(_ image: PixelImage, radius: Int = 2) -> PixelImage {
        var out = image
        for y in 0 ..< image.height {
            for x in 0 ..< image.width {
                var sum = SIMD3<Float>.zero, count: Float = 0
                for dy in -radius ... radius {
                    for dx in -radius ... radius {
                        let xx = min(max(x + dx, 0), image.width - 1), yy = min(max(y + dy, 0), image.height - 1)
                        sum += image[xx, yy]
                        count += 1
                    }
                }
                out[x, y] = sum / count
            }
        }
        return out
    }

    static func bilinear(_ image: PixelImage, _ x: Float, _ y: Float) -> SIMD3<Float> {
        let x0 = min(max(Int(floor(x)), 0), image.width - 1), y0 = min(max(Int(floor(y)), 0), image.height - 1)
        let x1 = min(x0 + 1, image.width - 1), y1 = min(y0 + 1, image.height - 1)
        let fx = min(max(x - Float(x0), 0), 1), fy = min(max(y - Float(y0), 0), 1)
        let top = image[x0, y0] * (1 - fx) + image[x1, y0] * fx
        let bottom = image[x0, y1] * (1 - fx) + image[x1, y1] * fx
        return top * (1 - fy) + bottom * fy
    }

    static func bilinear(_ plane: Plane, _ x: Float, _ y: Float) -> Float {
        let x0 = min(max(Int(floor(x)), 0), plane.width - 1), y0 = min(max(Int(floor(y)), 0), plane.height - 1)
        let x1 = min(x0 + 1, plane.width - 1), y1 = min(y0 + 1, plane.height - 1)
        let fx = min(max(x - Float(x0), 0), 1), fy = min(max(y - Float(y0), 0), 1)
        let v = plane.values
        let top = v[y0 * plane.width + x0] * (1 - fx) + v[y0 * plane.width + x1] * fx
        let bottom = v[y1 * plane.width + x0] * (1 - fx) + v[y1 * plane.width + x1] * fx
        return top * (1 - fy) + bottom * fy
    }

    // MARK: - Profiling

    /// Fits a table to every pair, choosing the smoothness by leaving scenes out.
    public func profile(
        _ pairs: [Pair],
        previous: LookTable? = nil,
        smoothnessCandidates: [Float] = [0.3, 1, 3, 10, 30, 100, 300],
        size: Int = 25,
        accept: (LookTable) async -> Bool = { _ in true },
        log: (String) -> Void = { _ in },
    ) async throws -> Report {
        var byScene: [String: [ProfileSample]] = [:]
        var alignments: [String: Alignment] = [:]
        for pair in pairs {
            let (samples, alignment) = try await samples(for: pair)
            alignments[pair.raw.lastPathComponent] = alignment
            byScene[pair.scene, default: []] += samples
            log(
                "  \(pair.raw.lastPathComponent): \(samples.count) samples, alignment ×\(String(format: "%.3f", alignment.scale)) r=\(String(format: "%.2f", alignment.correlation))",
            )
        }
        let scenes = byScene.keys.sorted()
        normalizeExposure(&byScene, log: log)
        let folds = min(5, scenes.count)
        func held(_ fold: Int) -> (train: [ProfileSample], test: [ProfileSample]) {
            var train: [ProfileSample] = [], test: [ProfileSample] = []
            for (index, scene) in scenes.enumerated() {
                if folds > 1, index % folds == fold {
                    test += byScene[scene] ?? []
                } else {
                    train += byScene[scene] ?? []
                }
            }
            return (train, folds > 1 ? test : train)
        }
        var heldOut: [(smoothness: Float, error: Double)] = []
        for smoothness in smoothnessCandidates {
            var total = 0.0, count = 0
            for fold in 0 ..< folds {
                let (train, test) = held(fold)
                let table = LatticeFit.fit(train, size: size, smoothness: smoothness)
                total += LatticeFit.error(table, test).mean * Double(test.count)
                count += test.count
            }
            let error = total / Double(max(count, 1))
            heldOut.append((smoothness, error))
            log("  smoothness \(smoothness): held-out ΔE \(String(format: "%.2f", error))")
        }
        let all = scenes.flatMap { byScene[$0] ?? [] }
        // The most accurate fit that also passes the guardrails (smooth, monotonic); the
        // smoothest candidate is the fallback.
        var best = heldOut.last!
        var table = LatticeFit.fit(all, size: size, smoothness: best.smoothness)
        for candidate in heldOut.sorted(by: { $0.error < $1.error }) {
            let fitted = LatticeFit.fit(all, size: size, smoothness: candidate.smoothness)
            if await accept(fitted) {
                best = candidate
                table = fitted
                break
            }
            log("  smoothness \(candidate.smoothness) fails lint; trying smoother")
        }
        // Held-out error of the chosen smoothness, fold by fold.
        var fittedErrors: [Double] = [], fittedP90: [Double] = [], weights: [Double] = []
        for fold in 0 ..< folds {
            let (train, test) = held(fold)
            let e = LatticeFit.error(LatticeFit.fit(train, size: size, smoothness: best.smoothness), test)
            fittedErrors.append(e.mean)
            fittedP90.append(e.p90)
            weights.append(Double(test.count))
        }
        let totalWeight = max(weights.reduce(0, +), 1)
        return Report(
            table: table,
            smoothness: best.smoothness, scenes: scenes.count, samples: all.count,
            neutral: LatticeFit.error(nil, all),
            previous: previous.map { LatticeFit.error($0, all) },
            fitted: (
                zip(fittedErrors, weights).map(*).reduce(0, +) / totalWeight,
                zip(fittedP90, weights).map(*).reduce(0, +) / totalWeight,
            ),
            alignments: alignments,
        )
    }

    /// Each camera meters and scales its raw a little differently from Redlamp, so a scene's
    /// JPEG can sit a fraction of a stop or a tint away from our render for reasons that have
    /// nothing to do with the look. Each scene's own channel gains (camera over ours, in
    /// linear light, over midtones) are divided by the scenes' geometric mean and removed
    /// from its inputs, so the fit learns what all cameras share: the film simulation.
    func normalizeExposure(_ byScene: inout [String: [ProfileSample]], log: (String) -> Void) {
        func gains(_ samples: [ProfileSample]) -> SIMD3<Float>? {
            var ratios: [[Float]] = [[], [], []]
            for sample in samples {
                let x = ColorMath.srgbDecode(sample.input), y = ColorMath.srgbDecode(sample.target)
                let luma = simd_dot(x, ColorMath.rec2020Luma)
                guard luma > 0.05, luma < 0.45 else { continue }
                for c in 0 ..< 3 where x[c] > 0.01 {
                    ratios[c].append(y[c] / x[c])
                }
            }
            guard ratios.allSatisfy({ $0.count > 50 }) else { return nil }
            let medians = ratios.map { $0.sorted()[$0.count / 2] }
            return SIMD3(medians[0], medians[1], medians[2])
        }
        let perScene = byScene.compactMapValues(gains)
        guard perScene.count > 1 else { return }
        let logs = perScene.values.map { SIMD3(log2($0.x), log2($0.y), log2($0.z)) }
        let meanLog = logs.reduce(.zero, +) / Float(logs.count)
        for (scene, gain) in perScene.sorted(by: { $0.key < $1.key }) {
            let relative = SIMD3(log2(gain.x), log2(gain.y), log2(gain.z)) - meanLog
            let correction = SIMD3(exp2(relative.x), exp2(relative.y), exp2(relative.z))
            log(
                "  \(scene): exposure \(String(format: "%+.2f", simd_dot(relative, ColorMath.rec2020Luma))) EV relative to the others",
            )
            byScene[scene] = byScene[scene]?.map { sample in
                let adjusted = ColorMath.srgbDecode(sample.input) * correction
                return ProfileSample(
                    input: ColorMath.srgbEncode(simd_clamp(adjusted, .zero, SIMD3(repeating: 1))),
                    target: sample.target,
                    weight: sample.weight,
                )
            }
        }
    }

    /// Rows of neutral render, fitted look and the camera's JPEG, for checking by eye.
    public func comparisonSheet(_ pairs: [Pair], look: Recipe, tile: Int = 360) async throws -> CGImage {
        let tileHeight = tile * 2 / 3, gap = 6, label = 22
        let width = gap + 3 * (tile + gap), height = label + gap + pairs.count * (tileHeight + gap)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (column, title) in ["Redlamp Color", look.name, "Camera JPEG"].enumerated() {
            RecipeRenderer.draw(
                text: title,
                in: context,
                at: CGPoint(x: gap + column * (tile + gap) + 2, y: height - label + 6),
                width: CGFloat(tile),
            )
        }
        for (row, pair) in pairs.enumerated() {
            let images = try await [
                renderer.render(nil, image: pair.raw, maxLongEdge: tile * 2),
                renderer.render(look, image: pair.raw, maxLongEdge: tile * 2),
                CameraJPEG.extract(from: pair.raw, maxLongEdge: tile * 2),
            ]
            let y = height - label - gap - (row + 1) * (tileHeight + gap) + gap
            for (column, image) in images.enumerated() {
                let box = CGRect(x: gap + column * (tile + gap), y: y, width: tile, height: tileHeight)
                context.saveGState()
                context.clip(to: box)
                context.interpolationQuality = .high
                context.draw(
                    image,
                    in: RecipeRenderer.aspectFit(CGSize(width: image.width, height: image.height), in: box),
                )
                context.restoreGState()
            }
        }
        guard let sheet = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return sheet
    }
}
