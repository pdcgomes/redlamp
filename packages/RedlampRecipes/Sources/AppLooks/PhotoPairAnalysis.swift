import CoreGraphics
import Foundation
import RedlampEngineAPI
import simd

/// Best-effort spatial measurements from a kit photo and the app's export of it, once the
/// charts have given the colour table: the export is compared with the kit photo passed
/// through that table, so what remains is what the table can't express.
///
/// Limits: the pair is aligned by a centred aspect crop and a resize only; per-image
/// adaptive filters show up as a large residual rather than as a separate effect; and grain,
/// blur and glow estimates are confounded by JPEG and by the app's own resampling.
public enum PhotoPairAnalysis {
    public static let analysisSize = 768

    public struct Measures: Sendable {
        public var residualMean: Float
        public var residualP90: Float
        public var vignette: VignetteModel?
        public var cornerGain: Float?
        public var vignetteRMS: Float
        public var grainLuma: Float
        public var sharpness: Float
        public var glow: Float
    }

    /// How alike two images' structures are (−1…1), after cropping the first to the second's
    /// aspect, so renamed exports can be matched. It correlates the high-pass of log
    /// luminance: a tone curve keeps its edges, and a vignette's gain becomes a smooth offset
    /// that the high-pass removes.
    public static func similarity(_ kit: PixelImage, _ export: PixelImage) -> Float {
        let aspect = Float(export.width) / Float(export.height)
        let side = 64
        let (w, h) = aspect >= 1 ? (side, max(16, Int(Float(side) / aspect))) : (
            max(16, Int(Float(side) * aspect)),
            side,
        )
        guard let a = resampled(cropped(kit, toAspect: aspect), width: w, height: h),
              let b = resampled(export, width: w, height: h) else { return -1 }
        func detail(_ image: PixelImage) -> [Float] {
            let logLuma = image.pixels.map { log(luma($0) + 0.02) }
            var blurred = logLuma
            for _ in 0 ..< 3 {
                blurred = boxBlur(blurred, width: w, height: h)
            }
            return zip(logLuma, blurred).map { $0 - $1 }
        }
        let da = detail(a), db = detail(b)
        let num = zip(da, db).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let den = (da.reduce(Float(0)) { $0 + $1 * $1 } * db.reduce(Float(0)) { $0 + $1 * $1 }).squareRoot()
        return den > 1e-9 ? num / den : -1
    }

    public static func analyse(kit: PixelImage, export: PixelImage, table: LookTable) -> Measures? {
        let aspect = Float(export.width) / Float(export.height)
        let long = min(analysisSize, max(export.width, export.height))
        let (w, h) = aspect >= 1 ? (long, Int(Float(long) / aspect)) : (Int(Float(long) * aspect), long)
        guard w >= 64, h >= 64,
              let original = resampled(cropped(kit, toAspect: aspect), width: w, height: h),
              let exported = resampled(export, width: w, height: h) else { return nil }
        return measure(original: original, exported: exported, table: table, gain: nil)
    }

    /// Measures an export against the same-sized original. `gain` (position in pixels from
    /// the top left, encoded level) is the spatial gain the app applied, when it's already
    /// known; otherwise a vignette is fitted.
    public static func measure(
        original: PixelImage,
        exported: PixelImage,
        table: LookTable,
        gain known: ((SIMD2<Float>, Float) -> Float)?,
    ) -> Measures? {
        let w = exported.width, h = exported.height
        guard w >= 16, h >= 16, original.width == w, original.height == h else { return nil }
        let mapped = original.pixels.map { table.sample($0) }
        let la = mapped.map(luma), le = exported.pixels.map(luma)
        let frame = CGRect(x: 0, y: 0, width: w, height: h)

        let fit = known == nil
            ? fitVignette(la, le, width: w, height: h, frame: frame)
            : PhotoVignette(model: nil, rms: 0, level: 0.5)
        let vignette = fit.model, level = fit.level
        let gains = la.indices.map { i -> Float in
            let p = SIMD2(Float(i % w) + 0.5, Float(i / w) + 0.5)
            if let known {
                return known(p - 0.5, la[i])
            }
            return vignette.map { $0.gain(VignetteModel.radius(p, in: frame), encoded: level) } ?? 1
        }
        func gain(_ i: Int) -> Float {
            gains[i]
        }

        var errors: [Float] = []
        for i in stride(from: 0, to: w * h, by: 3) {
            errors.append(AppLookImport.deltaE(mapped[i] * gain(i), exported.pixels[i]))
        }
        let expected = la.indices.map { la[$0] * gain($0) }
        return Measures(
            residualMean: errors.reduce(0, +) / Float(max(errors.count, 1)),
            residualP90: percentile(errors, 0.9),
            vignette: vignette,
            cornerGain: vignette.map { $0.gain(Float(2).squareRoot(), encoded: level) },
            vignetteRMS: fit.rms,
            grainLuma: grain(expected, le, width: w, height: h),
            sharpness: sharpness(expected, le, width: w, height: h),
            glow: glow(expected, le, width: w, height: h),
        )
    }

    /// An image through the table and a vignette, for previews of sources the engine can't
    /// render neutrally (the engine's pass over an already rendered JPEG isn't an identity).
    public static func preview(_ image: PixelImage, table: LookTable, vignette: VignetteModel?) -> PixelImage {
        var result = image
        let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        for y in 0 ..< image.height {
            for x in 0 ..< image.width {
                let looked = table.sample(image[x, y])
                var gain: Float = 1
                if let vignette {
                    let d = VignetteModel.radius(SIMD2(Float(x) + 0.5, Float(y) + 0.5), in: frame)
                    gain = vignette.gain(d, encoded: luma(looked))
                }
                result[x, y] = simd_clamp(looked * gain, .zero, .one)
            }
        }
        return result
    }

    // MARK: - Effects

    /// The ratio of export to table-mapped luminance, block by block, as a vignette.
    static func fitVignette(
        _ la: [Float],
        _ le: [Float],
        width w: Int,
        height h: Int,
        frame: CGRect,
    ) -> PhotoVignette {
        let columns = 16, rows = max(4, Int((Float(columns) * Float(h) / Float(w)).rounded()))
        var blocks: [(radius: Float, ratio: Float)] = []
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                var ratios: [Float] = []
                for y in row * h / rows ..< (row + 1) * h / rows {
                    for x in column * w / columns ..< (column + 1) * w / columns {
                        let i = y * w + x
                        if la[i] > 0.1, la[i] < 0.92, le[i] > 0.02, le[i] < 0.98 {
                            ratios.append(le[i] / la[i])
                        }
                    }
                }
                guard ratios.count >= 20 else { continue }
                let p = SIMD2(
                    (Float(column) + 0.5) * Float(w) / Float(columns),
                    (Float(row) + 0.5) * Float(h) / Float(rows),
                )
                blocks.append((VignetteModel.radius(p, in: frame), median(ratios)))
            }
        }
        let centre = median(blocks.filter { $0.radius < 0.35 }.map(\.ratio))
        guard blocks.count >= 24, centre > 0.05 else { return PhotoVignette(model: nil, rms: 0, level: 0.5) }
        let level = median(le)
        let (model, rms) = VignetteModel.fit(blocks.map { ($0.radius, $0.ratio / centre) }, level: level)
        return PhotoVignette(model: abs(model.amount) >= 2 ? model : nil, rms: rms, level: level)
    }

    struct PhotoVignette {
        var model: VignetteModel?
        var rms: Float
        /// The export's median encoded luminance, which a brightening vignette's gain depends on.
        var level: Float
    }

    static func boxBlur(_ v: [Float], width w: Int, height h: Int) -> [Float] {
        var out = v
        for y in 1 ..< h - 1 {
            for x in 1 ..< w - 1 {
                var sum: Float = 0
                for dy in -1 ... 1 {
                    for dx in -1 ... 1 {
                        sum += v[(y + dy) * w + x + dx]
                    }
                }
                out[y * w + x] = sum / 9
            }
        }
        return out
    }

    /// Extra high-frequency variance in the export, in flat mid-tones.
    static func grain(_ expected: [Float], _ le: [Float], width w: Int, height h: Int) -> Float {
        let be = boxBlur(le, width: w, height: h), bx = boxBlur(expected, width: w, height: h)
        let slopes = gradients(expected, width: w, height: h).map(simd_length)
        let flat = percentile(slopes, 0.4)
        var extra: Float = 0, count: Float = 0
        for i in expected.indices where slopes[i] <= flat && expected[i] > 0.15 && expected[i] < 0.85 {
            let he = le[i] - be[i], hx = expected[i] - bx[i]
            extra += he * he - hx * hx
            count += 1
        }
        return count > 100 ? max(extra / count, 0).squareRoot() : 0
    }

    /// Edge contrast of the export relative to the table-mapped photo.
    static func sharpness(_ expected: [Float], _ le: [Float], width w: Int, height h: Int) -> Float {
        let gx = gradients(expected, width: w, height: h).map(simd_length)
        let ge = gradients(le, width: w, height: h).map(simd_length)
        let edge = percentile(gx, 0.85)
        var a: Float = 0, b: Float = 0
        for i in gx.indices where gx[i] >= edge {
            a += ge[i]
            b += gx[i]
        }
        return b > 1e-6 ? a / b : 1
    }

    /// Light spilled beside bright areas, over the same difference far from them.
    static func glow(_ expected: [Float], _ le: [Float], width w: Int, height h: Int) -> Float {
        let bright = expected.map { $0 > 0.85 }
        let radius = max(2, w / 60)
        let near = dilate(bright, width: w, height: h, radius: radius)
        let far = dilate(bright, width: w, height: h, radius: 3 * radius)
        var ring: [Float] = [], away: [Float] = []
        for i in expected.indices where !bright[i] && expected[i] < 0.6 {
            if near[i] {
                ring.append(le[i] - expected[i])
            } else if !far[i], expected[i] > 0.1 {
                away.append(le[i] - expected[i])
            }
        }
        guard ring.count >= 50, away.count >= 50 else { return 0 }
        return median(ring) - median(away)
    }

    // MARK: - Helpers

    static func luma(_ c: SIMD3<Float>) -> Float {
        simd_dot(c, ColorMath.rec709Luma)
    }

    static func gradients(_ v: [Float], width w: Int, height h: Int) -> [SIMD2<Float>] {
        var out = [SIMD2<Float>](repeating: .zero, count: v.count)
        for y in 1 ..< h - 1 {
            for x in 1 ..< w - 1 {
                let i = y * w + x
                out[i] = SIMD2(v[i + 1] - v[i - 1], v[i + w] - v[i - w]) / 2
            }
        }
        return out
    }

    static func dilate(_ mask: [Bool], width w: Int, height h: Int, radius r: Int) -> [Bool] {
        var integral = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0 ..< h {
            var row = 0
            for x in 0 ..< w {
                row += mask[y * w + x] ? 1 : 0
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        var out = [Bool](repeating: false, count: w * h)
        for y in 0 ..< h {
            let y0 = max(0, y - r), y1 = min(h, y + r + 1)
            for x in 0 ..< w {
                let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                out[y * w + x] = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1]
                    - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0] > 0
            }
        }
        return out
    }
}

// MARK: - Resampling

extension PhotoPairAnalysis {
    /// The largest centred region of `image` with the given width/height ratio.
    static func cropped(_ image: PixelImage, toAspect aspect: Float) -> PixelImage {
        let current = Float(image.width) / Float(image.height)
        guard abs(current / aspect - 1) > 0.005 else { return image }
        let w = current > aspect ? Int((Float(image.height) * aspect).rounded()) : image.width
        let h = current > aspect ? image.height : Int((Float(image.width) / aspect).rounded())
        let x0 = (image.width - w) / 2, y0 = (image.height - h) / 2
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(w * h)
        for y in y0 ..< y0 + h {
            for x in x0 ..< x0 + w {
                pixels.append(image[x, y])
            }
        }
        return PixelImage(width: w, height: h, pixels: pixels)
    }

    /// The part of `image` inside `rect` (pixels, fractional) resampled to `width` × `height`.
    static func resampled(_ image: PixelImage, from rect: CGRect, width: Int, height: Int) -> PixelImage? {
        let box = rect.insetBy(dx: -3, dy: -3).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !box.isNull, box.width >= 1, box.height >= 1 else { return nil }
        let part = image.region(x: Int(box.minX), y: Int(box.minY), width: Int(box.width), height: Int(box.height))
        guard let cg = part.cgImage(), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGImageByteOrderInfo.order16Little.rawValue,
              ) else { return nil }
        let sx = CGFloat(width) / rect.width, sy = CGFloat(height) / rect.height
        let top = (box.minY - rect.minY) * sy
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(
            x: (box.minX - rect.minX) * sx,
            y: CGFloat(height) - top - box.height * sy,
            width: box.width * sx,
            height: box.height * sy,
        ))
        return context.makeImage().flatMap { PixelImage($0) }
    }

    static func resampled(_ image: PixelImage, width: Int, height: Int) -> PixelImage? {
        guard let cg = image.cgImage(), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGImageByteOrderInfo.order16Little.rawValue,
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().flatMap { PixelImage($0) }
    }
}
