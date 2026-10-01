import CoreGraphics
import Foundation
import simd

/// Where a capture chart landed in an export: `export = scale × chart + offset`, in pixels.
/// Phone apps resize and crop but don't rotate, so there is no rotation term.
public struct ChartTransform: Codable, Sendable, Hashable {
    public var scale: SIMD2<Float>
    public var offset: SIMD2<Float>

    public init(scale: SIMD2<Float>, offset: SIMD2<Float>) {
        self.scale = scale
        self.offset = offset
    }

    public func apply(_ p: SIMD2<Float>) -> SIMD2<Float> {
        scale * p + offset
    }

    public func apply(_ rect: CGRect) -> CGRect {
        let a = apply(SIMD2(Float(rect.minX), Float(rect.minY)))
        let b = apply(SIMD2(Float(rect.maxX), Float(rect.maxY)))
        return CGRect(x: CGFloat(a.x), y: CGFloat(a.y), width: CGFloat(b.x - a.x), height: CGFloat(b.y - a.y))
    }

    /// The mean of the two axis scales.
    public var meanScale: Float {
        (scale.x + scale.y) / 2
    }
}

/// Finds the capture chart's finder markers and fits the chart's transform to them.
enum ChartDetection {
    struct Candidate {
        var centre: SIMD2<Float>
        var module: Float
        var hits: Int
    }

    struct Fit {
        var transform: ChartTransform
        /// Detected centre of each model marker that was found.
        var markers: [Int: SIMD2<Float>]
        var residual: Float
    }

    static func luminance(_ image: PixelImage) -> [Float] {
        image.pixels.map { simd_dot($0, ColorMath.rec709Luma) }
    }

    // MARK: - Markers

    /// Finder-pattern centres: 1:1:3:1:1 dark-light-dark runs across both axes, on a
    /// binarisation against the local mean, so a filter's tone curve and vignette don't matter.
    static func candidates(in image: PixelImage) -> [Candidate] {
        let w = image.width, h = image.height
        let dark = binarise(luminance(image), width: w, height: h)
        var found: [Candidate] = []
        var runs: [(start: Int, length: Int)] = []
        for y in 0 ..< h {
            runs.removeAll(keepingCapacity: true)
            let row = y * w
            var start = 0
            for x in 1 ... w where x == w || dark[row + x] != dark[row + x - 1] {
                runs.append((start, x - start))
                start = x
            }
            let firstDark = dark[row] ? 0 : 1
            for i in stride(from: firstDark, to: runs.count - 4, by: 2) {
                let lengths = (0 ..< 5).map { runs[i + $0].length }
                guard let module = finderModule(lengths) else { continue }
                let x = runs[i + 2].start + runs[i + 2].length / 2
                guard let vertical = crossCheck(count: h, at: y, isDark: { dark[$0 * w + x] }),
                      abs(vertical.module - module) < 0.45 * module,
                      let horizontal = crossCheck(count: w, at: x, isDark: { dark[Int(vertical.centre) * w + $0] })
                else { continue }
                found.append(Candidate(
                    centre: SIMD2(horizontal.centre, vertical.centre),
                    module: (horizontal.module + vertical.module) / 2,
                    hits: 1,
                ))
            }
        }
        return cluster(found)
    }

    /// Dark where luminance is below the mean of a window about a twelfth of the image.
    static func binarise(_ lum: [Float], width w: Int, height h: Int) -> [Bool] {
        var integral = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0 ..< h {
            var row = 0.0
            for x in 0 ..< w {
                row += Double(lum[y * w + x])
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        let half = max(4, min(w, h) / 24)
        var dark = [Bool](repeating: false, count: w * h)
        for y in 0 ..< h {
            let y0 = max(0, y - half), y1 = min(h, y + half + 1)
            for x in 0 ..< w {
                let x0 = max(0, x - half), x1 = min(w, x + half + 1)
                let sum = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1]
                    - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                dark[y * w + x] = Double(lum[y * w + x]) < sum / Double((y1 - y0) * (x1 - x0))
            }
        }
        return dark
    }

    /// The module size when five runs look like a finder pattern.
    static func finderModule(_ lengths: [Int]) -> Float? {
        let module = Float(lengths.reduce(0, +)) / 7
        guard module >= 1.2 else { return nil }
        for (i, length) in lengths.enumerated() {
            let expected: Float = i == 2 ? 3 : 1
            let tolerance: Float = i == 2 ? 1.1 : 0.6
            if abs(Float(length) - expected * module) > tolerance * module {
                return nil
            }
        }
        return module
    }

    /// Re-reads the pattern through `start` along the other axis.
    static func crossCheck(count: Int, at start: Int, isDark: (Int) -> Bool) -> (centre: Float, module: Float)? {
        guard start >= 0, start < count, isDark(start) else { return nil }
        var lo = start, hi = start
        while lo > 0, isDark(lo - 1) {
            lo -= 1
        }
        while hi < count - 1, isDark(hi + 1) {
            hi += 1
        }
        func run(from: Int, step: Int, dark: Bool) -> Int {
            var k = from, length = 0
            while k >= 0, k < count, isDark(k) == dark {
                length += 1
                k += step
            }
            return length
        }
        let upLight = run(from: lo - 1, step: -1, dark: false)
        let upDark = run(from: lo - 1 - upLight, step: -1, dark: true)
        let downLight = run(from: hi + 1, step: 1, dark: false)
        let downDark = run(from: hi + 1 + downLight, step: 1, dark: true)
        guard let module = finderModule([upDark, upLight, hi - lo + 1, downLight, downDark]) else { return nil }
        return (Float(lo) + Float(hi - lo + 1) / 2, module)
    }

    static func cluster(_ found: [Candidate]) -> [Candidate] {
        var clusters: [Candidate] = []
        var sums: [SIMD3<Float>] = []
        for candidate in found {
            if let index = clusters.firstIndex(where: {
                simd_distance($0.centre, candidate.centre) < 1.5 * max($0.module, candidate.module)
            }) {
                sums[index] += SIMD3(candidate.centre.x, candidate.centre.y, candidate.module)
                clusters[index].hits += 1
                let mean = sums[index] / Float(clusters[index].hits)
                clusters[index].centre = SIMD2(mean.x, mean.y)
                clusters[index].module = mean.z
            } else {
                clusters.append(candidate)
                sums.append(SIMD3(candidate.centre.x, candidate.centre.y, candidate.module))
            }
        }
        return clusters.filter { $0.hits >= 3 }.sorted { $0.hits > $1.hits }
    }

    // MARK: - Transform

    /// The scale and offset that put the most model markers on detected ones.
    static func fit(_ found: [Candidate], layout: CaptureLayout) -> Fit? {
        let model = layout.markerCentres
        let unit = Float(layout.markerModule)
        let candidates = Array(found.prefix(60))
        var best: Fit?
        for a in candidates.indices {
            for b in candidates.indices where b > a {
                let dc = candidates[b].centre - candidates[a].centre
                for i in model.indices {
                    for j in model.indices where j != i {
                        let dm = model[j] - model[i]
                        let s = simd_length(dc) / simd_length(dm)
                        guard s > 0.08, s < 4, simd_dot(dc, dm) > 0,
                              abs(dm.x * dc.y - dm.y * dc.x) < 0.035 * simd_length(dm) * simd_length(dc),
                              abs(candidates[a].module - s * unit) < 0.4 * s * unit
                        else { continue }
                        let transform = ChartTransform(
                            scale: SIMD2(repeating: s),
                            offset: candidates[a].centre - s * model[i],
                        )
                        let fit = score(transform, candidates, model: model, unit: unit)
                        if best.map({ fit.markers.count > $0.markers.count
                                || (fit.markers.count == $0.markers.count && fit.residual < $0.residual)
                        }) ?? true {
                            best = fit
                        }
                    }
                }
            }
        }
        guard let best, best.markers.count >= 2 else { return nil }
        return refine(best, candidates: candidates, model: model, unit: unit)
    }

    static func score(
        _ transform: ChartTransform,
        _ candidates: [Candidate],
        model: [SIMD2<Float>],
        unit: Float,
    ) -> Fit {
        let tolerance = max(2, 1.5 * transform.meanScale * unit)
        var markers: [Int: SIMD2<Float>] = [:]
        var residual: Float = 0
        for (k, centre) in model.enumerated() {
            let predicted = transform.apply(centre)
            guard let nearest = candidates.min(by: {
                simd_distance($0.centre, predicted) < simd_distance($1.centre, predicted)
            }) else { continue }
            let distance = simd_distance(nearest.centre, predicted)
            if distance < tolerance {
                markers[k] = nearest.centre
                residual += distance * distance
            }
        }
        return Fit(transform: transform, markers: markers, residual: residual)
    }

    /// Least squares over the matched markers: one scale per axis where the markers span
    /// it, and a shared one when the axes agree or only one is spanned.
    static func refine(_ fit: Fit, candidates: [Candidate], model: [SIMD2<Float>], unit: Float) -> Fit {
        let pairs = fit.markers.map { (model[$0.key], $0.value) }
        func axis(_ component: Int) -> (scale: Float, offset: Float)? {
            let m = pairs.map { $0.0[component] }, c = pairs.map { $0.1[component] }
            guard let lo = m.min(), let hi = m.max(), hi - lo > 500 else { return nil }
            let mm = m.reduce(0, +) / Float(m.count), cm = c.reduce(0, +) / Float(c.count)
            let num = zip(m, c).reduce(Float(0)) { $0 + ($1.0 - mm) * ($1.1 - cm) }
            let den = m.reduce(Float(0)) { $0 + ($1 - mm) * ($1 - mm) }
            let s = num / den
            return (s, cm - s * mm)
        }
        func offsets(_ s: Float) -> SIMD2<Float> {
            pairs.reduce(SIMD2<Float>.zero) { $0 + ($1.1 - s * $1.0) } / Float(pairs.count)
        }
        var transform = fit.transform
        switch (axis(0), axis(1)) {
        case let (x?, y?) where abs(x.scale / y.scale - 1) > 0.01:
            transform = ChartTransform(scale: SIMD2(x.scale, y.scale), offset: SIMD2(x.offset, y.offset))
        case let (x?, y?):
            let s = (x.scale + y.scale) / 2
            transform = ChartTransform(scale: SIMD2(repeating: s), offset: offsets(s))
        case let (x?, nil):
            transform = ChartTransform(scale: SIMD2(repeating: x.scale), offset: offsets(x.scale))
        case let (nil, y?):
            transform = ChartTransform(scale: SIMD2(repeating: y.scale), offset: offsets(y.scale))
        case (nil, nil):
            break
        }
        let refined = score(transform, candidates, model: model, unit: unit)
        return refined.markers.count >= fit.markers.count ? refined : fit
    }
}
