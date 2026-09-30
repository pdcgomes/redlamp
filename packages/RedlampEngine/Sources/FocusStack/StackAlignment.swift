import Foundation
import simd

/// A single-channel float image on the CPU, row-major: the encoded luminance alignment works on.
struct LumaImage {
    let width: Int
    let height: Int
    var pixels: [Float]

    init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    subscript(x: Int, y: Int) -> Float {
        pixels[y * width + x]
    }

    /// Bilinear sample; nil outside the image.
    func sample(_ x: Float, _ y: Float) -> Float? {
        guard x >= 0, y >= 0, x <= Float(width - 1), y <= Float(height - 1) else { return nil }
        let x0 = min(Int(x), width - 2)
        let y0 = min(Int(y), height - 2)
        let fx = x - Float(x0)
        let fy = y - Float(y0)
        let top = pixels[y0 * width + x0] * (1 - fx) + pixels[y0 * width + x0 + 1] * fx
        let bottom = pixels[(y0 + 1) * width + x0] * (1 - fx) + pixels[(y0 + 1) * width + x0 + 1] * fx
        return top * (1 - fy) + bottom * fy
    }

    /// Half the size, averaging 2 x 2 blocks.
    func halved() -> LumaImage {
        let w = max(1, width / 2)
        let h = max(1, height / 2)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let x0 = min(2 * x, width - 1)
                let y0 = min(2 * y, height - 1)
                let x1 = min(x0 + 1, width - 1)
                let y1 = min(y0 + 1, height - 1)
                out[y * w + x] = 0.25 * (self[x0, y0] + self[x1, y0] + self[x0, y1] + self[x1, y1])
            }
        }
        return LumaImage(width: w, height: h, pixels: out)
    }
}

/// A similarity transform mapping reference coordinates to a frame's coordinates, in pixels of
/// the image it was estimated on: x' = a x - b y + tx, y' = b x + a y + ty.
struct Similarity: Equatable, Codable {
    var a: Float = 1
    var b: Float = 0
    var tx: Float = 0
    var ty: Float = 0

    static let identity = Similarity()

    var scale: Float {
        (a * a + b * b).squareRoot()
    }

    func apply(_ x: Float, _ y: Float) -> (Float, Float) {
        (a * x - b * y + tx, b * x + a * y + ty)
    }

    /// This transform for images `factor` times larger.
    func scaled(by factor: Float) -> Similarity {
        Similarity(a: a, b: b, tx: tx * factor, ty: ty * factor)
    }

    /// First `other`, then this: self(other(p)).
    func composed(after other: Similarity) -> Similarity {
        Similarity(
            a: a * other.a - b * other.b,
            b: a * other.b + b * other.a,
            tx: a * other.tx - b * other.ty + tx,
            ty: b * other.tx + a * other.ty + ty,
        )
    }

    var inverse: Similarity {
        let d = a * a + b * b
        let ia = a / d
        let ib = -b / d
        return Similarity(a: ia, b: ib, tx: -(ia * tx - ib * ty), ty: -(ib * tx + ia * ty))
    }
}

/// Enhanced correlation coefficient alignment (Evangelidis & Psarakis, TPAMI 2008) of a frame to a
/// template, for a similarity transform, coarse to fine. ECC maximises the correlation of the
/// zero-mean, normalised images, so it tolerates the brightness and blur differences between
/// frames focused at different depths.
enum ECCAligner {
    struct Result {
        var transform: Similarity
        /// The final correlation coefficient over the overlap, -1 ... 1.
        var correlation: Float
    }

    /// Aligns `image` to `template` (same size). `initial` maps template to image coordinates.
    /// Pyramid levels are built down to under 400 px; each level runs up to `iterations` steps,
    /// stopping once no image corner moves more than `tolerance` pixels.
    static func align(
        template: LumaImage,
        image: LumaImage,
        initial: Similarity = .identity,
        iterations: Int = 50,
        tolerance: Float = 0.01,
    ) -> Result {
        var templates = [template]
        var images = [image]
        while max(templates.last!.width, templates.last!.height) > 400 {
            templates.append(templates.last!.halved())
            images.append(images.last!.halved())
        }
        let levels = templates.count
        var transform = initial.scaled(by: 1 / Float(1 << (levels - 1)))
        var correlation: Float = 0
        for level in (0 ..< levels).reversed() {
            if level < levels - 1 {
                transform = transform.scaled(by: 2)
            }
            let result = refine(
                template: templates[level], image: images[level], initial: transform,
                iterations: iterations, tolerance: tolerance,
            )
            transform = result.transform
            correlation = result.correlation
        }
        return Result(transform: transform, correlation: correlation)
    }

    /// Gauss-Newton ECC iterations at one scale.
    static func refine(
        template: LumaImage,
        image: LumaImage,
        initial: Similarity,
        iterations: Int,
        tolerance: Float,
    ) -> Result {
        var p = initial
        var correlation: Float = 0
        let width = template.width
        let height = template.height
        // Image gradients, central differences.
        var gx = [Float](repeating: 0, count: width * height)
        var gy = [Float](repeating: 0, count: width * height)
        for y in 0 ..< image.height {
            for x in 0 ..< image.width {
                let xl = max(x - 1, 0)
                let xr = min(x + 1, image.width - 1)
                let yu = max(y - 1, 0)
                let yd = min(y + 1, image.height - 1)
                gx[y * image.width + x] = 0.5 * (image[xr, y] - image[xl, y])
                gy[y * image.width + x] = 0.5 * (image[x, yd] - image[x, yu])
            }
        }
        let gradX = LumaImage(width: image.width, height: image.height, pixels: gx)
        let gradY = LumaImage(width: image.width, height: image.height, pixels: gy)

        for _ in 0 ..< iterations {
            // Warped image, its gradients and the steepest-descent images over the valid overlap.
            var count = 0
            var sumT: Double = 0
            var sumI: Double = 0
            var warped = [Float](repeating: 0, count: width * height)
            var valid = [Bool](repeating: false, count: width * height)
            var steepest = [SIMD4<Float>](repeating: .zero, count: width * height)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let (u, v) = p.apply(Float(x), Float(y))
                    guard let value = image.sample(u, v), let ix = gradX.sample(u, v), let iy = gradY.sample(u, v)
                    else { continue }
                    let index = y * width + x
                    // Image gradient times d(u, v)/d(a, b, tx, ty), for u = a x - b y + tx, v = b x + a y + ty.
                    steepest[index] = SIMD4(
                        ix * Float(x) + iy * Float(y), -ix * Float(y) + iy * Float(x), ix, iy,
                    )
                    warped[index] = value
                    valid[index] = true
                    sumT += Double(template.pixels[index])
                    sumI += Double(value)
                    count += 1
                }
            }
            guard count > 64 else { break }
            let meanT = Float(sumT / Double(count))
            let meanI = Float(sumI / Double(count))
            var hessian = simd_float4x4()
            var projI = SIMD4<Float>.zero
            var projT = SIMD4<Float>.zero
            var normI: Float = 0
            var normT: Float = 0
            var dot: Float = 0
            var meanG = SIMD4<Float>.zero
            for index in 0 ..< width * height where valid[index] {
                meanG += steepest[index]
            }
            meanG /= Float(count)
            for index in 0 ..< width * height where valid[index] {
                let g = steepest[index] - meanG
                let i = warped[index] - meanI
                let t = template.pixels[index] - meanT
                hessian += simd_float4x4(columns: (g * g.x, g * g.y, g * g.z, g * g.w))
                projI += g * i
                projT += g * t
                normI += i * i
                normT += t * t
                dot += i * t
            }
            correlation = dot / max((normI * normT).squareRoot(), 1e-12)
            let inverse = hessian.inverse
            let hI = inverse * projI
            let hT = inverse * projT
            let numerator = normI - simd_dot(projI, hI)
            let denominator = dot - simd_dot(projT, hI)
            guard denominator > 1e-12 else { break }
            let lambda = numerator / denominator
            // Update: H^-1 G^T (lambda t - i).
            let delta = lambda * hT - hI
            p.a += delta.x
            p.b += delta.y
            p.tx += delta.z
            p.ty += delta.w
            // The largest move of an image corner this step, in pixels.
            let shift = abs(delta.x) * Float(width) + abs(delta.y) * Float(height) + abs(delta.z) + abs(delta.w)
            if shift < tolerance {
                break
            }
        }
        return Result(transform: p, correlation: correlation)
    }
}
