import Foundation

/// What an app-look import measured, and how far to trust it.
public struct AppLookReport: Codable, Sendable {
    public struct Chart: Codable, Sendable {
        /// 1-based, as printed in the kit's file names.
        public var number: Int
        public var file: String
        public var width: Int
        public var height: Int
        public var transform: ChartTransform
        public var markersFound: Int
        /// RMS distance of the markers from the fitted transform, in export pixels.
        public var markerResidual: Double
        public var probes: Int
        public var patches: Int
        public var rejectedPatches: Int
        public var rampVisible: Bool
        /// The export shows more than the chart: the app added a border or letterbox.
        public var borderDetected: Bool
    }

    public struct Residuals: Codable, Sendable {
        /// Spread of the pixels inside a patch, in 8-bit levels: grain, JPEG and overlays.
        public var patchSpreadMedian: Double
        public var patchSpreadP95: Double
        /// The table against the grey ramp, whose levels lie between lattice points (OKLab ΔE × 100).
        public var rampMeanDeltaE: Double?
        public var rampMaxDeltaE: Double?
    }

    public struct Tone: Codable, Sendable {
        /// Output luminance falls somewhere as an input channel rises.
        public var nonMonotonic: Bool
        public var nonMonotonicFraction: Double
        public var clipped: Bool
        /// Lattice points pushed to 0 or 1 in a channel whose input wasn't there.
        public var clippedFraction: Double
        /// Grey input from which the output is white, when below 1.
        public var highlightClipFrom: Double?
        /// Grey input below which the output is black, when above 0.
        public var shadowCrushBelow: Double?
        /// The ramp: grey input → output luminance (encoded), when the ramp was visible.
        public var neutralCurve: [[Double]]
    }

    public struct Vignette: Codable, Sendable {
        public var model: VignetteModel
        /// `export` when the effect follows the exported frame, `chart` when it followed the
        /// chart before a crop.
        public var frame: String
        /// The measured gain at the frame's corner, relative to the centre.
        public var cornerGain: Double
        public var fitRMS: Double
        /// RMS of the measured field that the radial model can't explain: light leaks,
        /// off-centre or textured overlays.
        public var irregularity: Double
        /// Corner colour relative to the centre after removing the luminance gain, RGB.
        public var cornerTint: [Double]
        /// `charts` or `photos`.
        public var source: String
    }

    public struct Grain: Codable, Sendable {
        /// Standard deviation of the luminance residual on mid grey, encoded units.
        public var luma: Double
        public var chroma: Double
        /// Neighbouring-pixel correlation of the residual; higher means coarser grain.
        public var correlation: Double
        public var sizePixels: Double
        /// Grey level → luminance residual, from the ramp.
        public var byLevel: [[Double]]
        public var suggestedAmount: Double
        public var suggestedSize: Double
    }

    public struct Photo: Codable, Sendable {
        public var file: String
        public var kitPhoto: String
        public var matchedBy: String
        public var similarity: Double
        /// The export against the kit photo through the fitted table, gain removed.
        public var residualMeanDeltaE: Double
        public var residualP90DeltaE: Double
        public var vignette: VignetteModel?
        public var cornerGain: Double?
        public var grainLuma: Double
        /// Edge contrast of the export over the table-mapped kit photo: below 1 is blur or
        /// softening, above 1 sharpening.
        public var sharpness: Double
        /// Extra light beside bright areas (encoded units): glow, bloom or halation.
        public var glow: Double
    }

    /// How much of the kit's detail the export kept.
    public struct Resolution: Codable, Sendable {
        public var width: Int
        public var height: Int
        /// Export pixels per kit pixel, from the markers.
        public var scale: Double
        /// The scale the export's detail corresponds to, from the line pairs; below `scale`
        /// when the app softened the image or scaled it up from a smaller one.
        public var effectiveScale: Double?
        /// The line-pair period (kit pixels) where modulation falls to half; nil when even the
        /// finest group keeps it.
        public var resolvedPeriod: Double?
        /// A lattice patch's side in export pixels.
        public var patchPixels: Double
        /// The same, at the effective scale.
        public var effectivePatchPixels: Double
        /// Line-pair period (kit pixels) → modulation relative to the coarsest.
        public var modulation: [[Double]]
    }

    /// Where the look came from. Private: never shown as, or copied into, the recipe's name.
    public struct Provenance: Codable, Sendable {
        public var app: String?
        public var filter: String?
        public var captured: Date
    }

    public var kitVersion: Int
    /// nil in reports written before the compact kit, which were all `full`.
    public var layout: CaptureLayout.Kind?
    /// The measured lattice; the table is resampled from it.
    public var lattice: Int
    public var patchesTotal: Int
    public var patchesMeasured: Int
    public var patchesFilled: Int
    public var charts: [Chart]
    public var residuals: Residuals
    public var tone: Tone
    public var vignette: Vignette?
    public var grain: Grain?
    public var resolution: Resolution?
    public var photos: [Photo] = []
    public var provenance: Provenance?
    public var warnings: [String] = []
}

public extension AppLookReport {
    /// A few lines for the terminal.
    var summary: String {
        var lines = [
            "\((layout ?? .full).rawValue) kit, lattice \(lattice)³: \(patchesMeasured) of \(patchesTotal) points "
                + "measured, \(patchesFilled) interpolated",
            String(
                format: "patch spread %.1f levels (p95 %.1f)",
                residuals.patchSpreadMedian,
                residuals.patchSpreadP95,
            ),
        ]
        if let mean = residuals.rampMeanDeltaE, let max = residuals.rampMaxDeltaE {
            lines.append(String(format: "grey ramp against the table: ΔE mean %.2f, max %.2f", mean, max))
        }
        if let resolution {
            var line = String(
                format: "export %d×%d, scale %.3f, patches %.1f px",
                resolution.width, resolution.height, resolution.scale, resolution.patchPixels,
            )
            if let effective = resolution.effectiveScale {
                line += String(
                    format: "; detail as at scale %.3f (patches %.1f px effective)",
                    effective, resolution.effectivePatchPixels,
                )
            }
            lines.append(line)
        }
        if tone.nonMonotonic {
            lines.append(String(format: "non-monotonic: %.1f%% of lattice steps", tone.nonMonotonicFraction * 100))
        }
        if tone.clipped {
            lines.append(String(format: "clipped: %.1f%% of lattice points", tone.clippedFraction * 100))
        }
        if let vignette {
            lines.append(String(
                format: "vignette (%@, %@ frame): amount %.0f, midpoint %.0f, feather %.0f, corner gain %.2f",
                vignette.source, vignette.frame, vignette.model.amount, vignette.model.midpoint,
                vignette.model.feather, vignette.cornerGain,
            ))
        }
        if let grain {
            lines.append(String(
                format: "grain: luma %.4f, chroma %.4f, size %.1f px → amount %.0f, size %.0f",
                grain.luma, grain.chroma, grain.sizePixels, grain.suggestedAmount, grain.suggestedSize,
            ))
        }
        for photo in photos {
            lines.append(String(
                format: "%@ (%@): residual ΔE %.2f (p90 %.2f), sharpness %.2f, glow %.3f",
                photo.file, photo.kitPhoto, photo.residualMeanDeltaE, photo.residualP90DeltaE,
                photo.sharpness, photo.glow,
            ))
        }
        return (lines + warnings.map { "warning: \($0)" }).joined(separator: "\n")
    }
}
