import CoreGraphics
import Foundation
import RedlampEngineAPI
import simd

// MARK: - Resolution

extension AppLookImport {
    /// Export pixels per line-pair period where a clean resample keeps half the modulation,
    /// measured through CoreGraphics' high-quality downscale; the effective scale is this over
    /// the finest period kept.
    static let halfModulationPeriod: Float = 1.9

    /// Patches smaller than this in the export mix with their neighbours in the sampled centre.
    static let reliablePatchPixels: Float = 6

    static func resolution(_ image: PixelImage, location: Location) -> AppLookReport.Resolution {
        let layout = location.layout, transform = location.transform
        let scale = transform.meanScale
        var modulation: [(period: Float, amplitude: Float)] = []
        for group in layout.linePairs {
            let rect = transform.apply(group.rect.insetBy(dx: 2, dy: 8))
            guard image.contains(rect) else { continue }
            let x0 = Int(rect.minX.rounded(.up)), x1 = Int(rect.maxX.rounded(.down))
            let y0 = Int(rect.minY.rounded(.up)), y1 = Int(rect.maxY.rounded(.down))
            guard x1 - x0 >= 4, y1 > y0 else { continue }
            let profile = (x0 ..< x1).map { x in
                (y0 ..< y1).reduce(Float(0)) { $0 + simd_dot(image[x, $1], ColorMath.rec709Luma) } / Float(y1 - y0)
            }
            modulation.append((group.period, percentile(profile, 0.9) - percentile(profile, 0.1)))
        }
        var resolved: Float?, measured = false
        if let reference = modulation.first?.amplitude, reference > 0.1 {
            measured = true
            let relative = modulation.map { ($0.period, $0.amplitude / reference) }
            for (previous, current) in zip(relative, relative.dropFirst()) where current.1 < 0.5 {
                let t = (previous.1 - 0.5) / max(previous.1 - current.1, 1e-4)
                resolved = previous.0 + (current.0 - previous.0) * t
                break
            }
        }
        // Every group kept its contrast: the detail reaches at least the pixel scale.
        let effective = measured ? min(scale, resolved.map { halfModulationPeriod / $0 } ?? scale) : nil
        let patch = Float(layout.patch)
        let reference = modulation.first?.amplitude ?? 1
        return AppLookReport.Resolution(
            width: image.width, height: image.height, scale: Double(scale),
            effectiveScale: effective.map(Double.init), resolvedPeriod: resolved.map(Double.init),
            patchPixels: Double(patch * scale), effectivePatchPixels: Double(patch * (effective ?? scale)),
            modulation: modulation.map { [Double($0.period), Double($0.amplitude / max(reference, 1e-3))] },
        )
    }

    static func resolutionWarnings(_ resolution: AppLookReport.Resolution) -> [String] {
        var warnings: [String] = []
        let reliable = Double(reliablePatchPixels)
        if resolution.patchPixels < reliable {
            warnings.append(String(
                format: "patches are %.1f px in the %d×%d export (reliable from %.0f): export at a larger size",
                resolution.patchPixels, resolution.width, resolution.height, reliable,
            ))
        }
        if let effective = resolution.effectiveScale, effective < 0.8 * resolution.scale {
            warnings.append(String(
                format: "the export holds the detail of a %.0f px image, not %d px: the app softened it or "
                    + "scaled it up from a smaller one (patches %.1f px effective)",
                effective / resolution.scale * Double(max(resolution.width, resolution.height)),
                max(resolution.width, resolution.height), resolution.effectivePatchPixels,
            ))
            if resolution.effectivePatchPixels < reliable, resolution.patchPixels >= reliable {
                warnings.append("colours near patch edges are mixed: check the app's export size setting")
            }
        }
        return warnings
    }
}

// MARK: - Photo tiles

extension AppLookImport {
    /// Grain, sharpness, glow and residual for each photo tile of a compact export, against
    /// the same region of the kit image through the measured table. The gain is the vignette
    /// measured on the whole frame, since the app applied it to the whole frame.
    static func tilePhotos(
        _ export: Export,
        _ location: Location,
        original: PixelImage,
        names: [String],
        result: Result,
    ) -> [AppLookReport.Photo] {
        let layout = location.layout, transform = location.transform, image = export.image
        let vignette = result.report.vignette
        let frame = vignette?.frame == "chart"
            ? transform.apply(CGRect(x: 0, y: 0, width: layout.side, height: layout.side))
            : CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let kitScale = Float(original.width) / Float(layout.side)
        var photos: [AppLookReport.Photo] = []
        for (index, tile) in layout.photoTiles.enumerated() {
            let target = transform.apply(tile.insetBy(dx: 4, dy: 4))
            let x0 = Int(target.minX.rounded(.up)), y0 = Int(target.minY.rounded(.up))
            let x1 = Int(target.maxX.rounded(.down)), y1 = Int(target.maxY.rounded(.down))
            guard x0 >= 0, y0 >= 0, x1 <= image.width, y1 <= image.height, x1 - x0 >= 64, y1 - y0 >= 64 else {
                continue
            }
            let exported = image.region(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            let chart = SIMD2(Float(x0), Float(y0)) - transform.offset
            let source = CGRect(
                x: CGFloat(chart.x / transform.scale.x * kitScale),
                y: CGFloat(chart.y / transform.scale.y * kitScale),
                width: CGFloat(Float(x1 - x0) / transform.scale.x * kitScale),
                height: CGFloat(Float(y1 - y0) / transform.scale.y * kitScale),
            )
            guard let kit = PhotoPairAnalysis.resampled(original, from: source, width: x1 - x0, height: y1 - y0)
            else { continue }
            let origin = SIMD2(Float(x0), Float(y0)) + 0.5
            let gain: (SIMD2<Float>, Float) -> Float = { p, level in
                guard let model = vignette?.model else { return 1 }
                return model.gain(VignetteModel.radius(origin + p, in: frame), encoded: level)
            }
            guard let measures = PhotoPairAnalysis.measure(
                original: kit, exported: exported, table: result.table, gain: gain,
            ) else { continue }
            photos.append(AppLookReport.Photo(
                file: export.name,
                kitPhoto: index < names.count ? names[index] : "tile \(index + 1)",
                matchedBy: "compact tile \(index + 1)",
                similarity: PhotoPairAnalysis.similarity(kit, exported),
                measures: measures,
            ))
        }
        return photos
    }
}

extension PixelImage {
    func region(x: Int, y: Int, width: Int, height: Int) -> PixelImage {
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(width * height)
        for row in y ..< y + height {
            for column in x ..< x + width {
                pixels.append(self[column, row])
            }
        }
        return PixelImage(width: width, height: height, pixels: pixels)
    }
}
