import CoreGraphics
import Foundation
import RedlampEngineAPI
import simd

// MARK: - Reading

extension AppLookImport {
    static func readFull(
        _ located: [(export: Export, location: Location)],
        originals: [Int: PixelImage],
        warnings: [String],
    ) throws -> Result {
        let layout = CaptureLayout.full
        var measurements: [Int: ChartMeasurement] = [:]
        var warnings = warnings
        for (export, location) in located {
            guard let chart = location.chart ?? export.chartHint else {
                throw AppLookImportError.unknownChart(file: export.name)
            }
            if measurements[chart] != nil {
                warnings.append("\(export.name): chart \(chart + 1) appears twice; the first one was used")
                continue
            }
            warnings += geometryWarnings(export, location)
            measurements[chart] = measure(
                chart: chart, export: export, location: location, original: originals[chart],
            )
        }
        for chart in 0 ..< layout.chartCount where measurements[chart] == nil {
            let blues = layout.slices(chart: chart)
            warnings.append(String(
                format: "chart %d is missing: blue %.2f–%.2f is interpolated", chart + 1,
                Float(blues.lowerBound) / Float(layout.lattice - 1),
                Float(blues.upperBound - 1) / Float(layout.lattice - 1),
            ))
        }
        return try assemble(
            measurements.sorted { $0.key < $1.key }.map(\.value), layout: layout, warnings: warnings,
        )
    }

    static func geometryWarnings(_ export: Export, _ location: Location) -> [String] {
        var warnings: [String] = []
        if location.markersFound < 4 {
            warnings.append("\(export.name): only \(location.markersFound) of 8 markers found")
        }
        let scale = location.transform.scale
        if abs(scale.x / scale.y - 1) > 0.01 {
            warnings.append(String(
                format: "%@: the app stretched the image (x/y scale %.3f)", export.name, scale.x / scale.y,
            ))
        }
        return warnings
    }

    static func checkLattice(_ location: Location, in export: Export) throws {
        let transform = location.transform
        let lattice = transform.apply(location.layout.latticeRect)
        let slack = CGFloat(0.25 * Float(location.layout.patch) * transform.meanScale)
        let bounds = CGRect(x: 0, y: 0, width: export.image.width, height: export.image.height)
            .insetBy(dx: -slack, dy: -slack)
        let visible = lattice.intersection(bounds)
        let fraction = visible.isNull ? 0 : visible.width * visible.height / (lattice.width * lattice.height)
        if fraction < 0.999 {
            throw AppLookImportError.latticeCut(file: export.name, visible: Double(fraction))
        }
    }
}

// MARK: - Assembling

extension AppLookImport {
    static func assemble(
        _ measurements: [ChartMeasurement],
        layout: CaptureLayout,
        warnings: [String],
    ) throws -> Result {
        guard !measurements.isEmpty else { throw AppLookImportError.noCharts }
        let n = layout.lattice
        var values = [SIMD3<Float>?](repeating: nil, count: n * n * n)
        for measurement in measurements {
            for sample in measurement.nodes {
                values[(sample.node.z * n + sample.node.y) * n + sample.node.x] = sample.output
            }
        }
        let measured = values.count(where: { $0 != nil })
        let filled = fillMissing(values, size: n)
        let table = try LookTable(size: n, floats: filled.flatMap { value -> [Float] in
            let v = simd_clamp(value, .zero, SIMD3(repeating: 1.2))
            return [v.x, v.y, v.z]
        })
        let ramp = measurements.flatMap(\.ramp).sorted { $0.input < $1.input }
        let spreads = measurements.flatMap(\.nodes).map(\.spread)
        let rampErrors = ramp.map { sample in
            deltaE(table.sample(SIMD3(repeating: sample.input)), sample.output)
        }
        var warnings = warnings
        let rejected = measurements.reduce(0) { $0 + $1.rejected }
        if rejected > 0 {
            warnings.append("\(rejected) patches were covered by texture or overlays and are interpolated")
        }
        let vignette = combinedVignette(measurements)
        if let vignette, vignette.irregularity > 0.03 {
            warnings.append(String(
                format: "the spatial field isn't a plain vignette (colour irregularity %.3f): light leaks or overlays",
                vignette.irregularity,
            ))
        }
        let resolution = measurements.compactMap(\.resolution).min { $0.effectivePatchPixels < $1.effectivePatchPixels }
        if let resolution {
            warnings += resolutionWarnings(resolution)
        }
        let report = AppLookReport(
            kitVersion: CaptureChart.kitVersion,
            layout: layout.kind,
            lattice: n,
            patchesTotal: n * n * n,
            patchesMeasured: measured,
            patchesFilled: n * n * n - measured,
            charts: measurements.map(\.report),
            residuals: AppLookReport.Residuals(
                patchSpreadMedian: Double(median(spreads) * 255),
                patchSpreadP95: Double(percentile(spreads, 0.95) * 255),
                rampMeanDeltaE: rampErrors.isEmpty ? nil : Double(rampErrors.reduce(0, +) / Float(rampErrors.count)),
                rampMaxDeltaE: rampErrors.max().map(Double.init),
            ),
            tone: tone(table, ramp: ramp),
            vignette: vignette,
            grain: combinedGrain(measurements, ramp: ramp),
            resolution: resolution,
            warnings: warnings,
        )
        return Result(table: table, report: report)
    }

    /// Fills unmeasured lattice points with the smoothest continuation of the measured
    /// ones' difference from identity (a discrete Laplace equation).
    static func fillMissing(_ values: [SIMD3<Float>?], size n: Int) -> [SIMD3<Float>] {
        let step = 1 / Float(n - 1)
        func identity(_ i: Int) -> SIMD3<Float> {
            SIMD3(Float(i % n), Float(i / n % n), Float(i / (n * n))) * step
        }
        let known = values.indices.compactMap { i in values[i].map { $0 - identity(i) } }
        let mean = known.isEmpty ? SIMD3<Float>.zero : known.reduce(.zero, +) / Float(known.count)
        var offsets = values.indices.map { i in values[i].map { $0 - identity(i) } ?? mean }
        let missing = values.indices.filter { values[$0] == nil }
        if !missing.isEmpty, !known.isEmpty {
            for _ in 0 ..< 2000 {
                var change: Float = 0
                for i in missing {
                    let x = i % n, y = i / n % n, z = i / (n * n)
                    var sum = SIMD3<Float>.zero
                    var count: Float = 0
                    for (inside, neighbour) in [
                        (x > 0, i - 1), (x < n - 1, i + 1), (y > 0, i - n), (y < n - 1, i + n),
                        (z > 0, i - n * n), (z < n - 1, i + n * n),
                    ] where inside {
                        sum += offsets[neighbour]
                        count += 1
                    }
                    let next = sum / count
                    change = max(change, simd_length(next - offsets[i]))
                    offsets[i] = next
                }
                if change < 1e-5 {
                    break
                }
            }
        }
        return offsets.indices.map { identity($0) + offsets[$0] }
    }

    static func deltaE(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let unit = SIMD3<Float>(repeating: 1)
        return simd_distance(
            ColorMath.encodedSRGBToOKLab(simd_clamp(a, .zero, unit)),
            ColorMath.encodedSRGBToOKLab(simd_clamp(b, .zero, unit)),
        ) * 100
    }

    static func tone(_ table: LookTable, ramp: [RampSample]) -> AppLookReport.Tone {
        let n = table.size
        var edges = 0, falling = 0, clipped = 0
        for b in 0 ..< n {
            for g in 0 ..< n {
                for r in 0 ..< n {
                    let v = table.entry(r: r, g: g, b: b)
                    let y = simd_dot(v, ColorMath.rec709Luma)
                    for (dr, dg, db) in [(1, 0, 0), (0, 1, 0), (0, 0, 1)] where r + dr < n && g + dg < n && b + db < n {
                        edges += 1
                        if simd_dot(table.entry(r: r + dr, g: g + dg, b: b + db), ColorMath.rec709Luma) < y - 0.02 {
                            falling += 1
                        }
                    }
                    let input = SIMD3(Float(r), Float(g), Float(b)) / Float(n - 1)
                    if (0 ..< 3).contains(where: { (v[$0] >= 0.995 && input[$0] < 0.97)
                            || (v[$0] <= 0.005 && input[$0] > 0.03)
                    }) {
                        clipped += 1
                    }
                }
            }
        }
        let curve = ramp.map { [Double($0.input), Double(simd_dot($0.output, ColorMath.rec709Luma))] }
        let highlight = curve.first { $0[1] >= 0.99 && $0[0] < 0.97 }?[0]
        let shadow = curve.last { $0[1] <= 0.01 && $0[0] > 0.03 }?[0]
        let rampFalls = zip(curve, curve.dropFirst()).contains { $1[1] < $0[1] - 0.02 }
        let fallingFraction = Double(falling) / Double(max(edges, 1))
        let clippedFraction = Double(clipped) / Double(n * n * n)
        return AppLookReport.Tone(
            nonMonotonic: fallingFraction > 0.005 || rampFalls,
            nonMonotonicFraction: fallingFraction,
            clipped: clippedFraction > 0.02 || highlight != nil || shadow != nil,
            clippedFraction: clippedFraction,
            highlightClipFrom: highlight,
            shadowCrushBelow: shadow,
            neutralCurve: curve,
        )
    }

    /// The chart fit with the median amount, so one odd chart can't skew it.
    static func combinedVignette(_ measurements: [ChartMeasurement]) -> AppLookReport.Vignette? {
        let fits = measurements.compactMap(\.vignette).sorted { $0.model.amount < $1.model.amount }
        guard !fits.isEmpty else { return nil }
        let fit = fits[fits.count / 2]
        return AppLookReport.Vignette(
            model: fit.model,
            frame: fit.frame,
            cornerGain: Double(fit.cornerGain),
            fitRMS: Double(fit.rms),
            irregularity: Double(fit.irregularity),
            cornerTint: [Double(fit.cornerTint.x), Double(fit.cornerTint.y), Double(fit.cornerTint.z)],
            source: "charts",
        )
    }

    /// Residual JPEG leaves on flat grey without grain (measured: under 0.0005 at quality 80).
    static let grainFloor: Float = 0.0005

    static func combinedGrain(_ measurements: [ChartMeasurement], ramp: [RampSample]) -> AppLookReport.Grain? {
        let samples = measurements.compactMap(\.grain)
        guard !samples.isEmpty else { return nil }
        let luma = median(samples.map(\.luma))
        let correlation = median(samples.map(\.correlation))
        let level = median(measurements.map(\.greyLevel))
        let bins = 8
        let byLevel = (0 ..< bins).compactMap { bin -> [Double]? in
            let inside = ramp.filter { min(Int($0.input * Float(bins)), bins - 1) == bin }
            guard !inside.isEmpty else { return nil }
            return [(Double(bin) + 0.5) / Double(bins), Double(median(inside.map(\.spread)))]
        }
        let sizePixels = correlation > 0.01 ? max(0.5, -1 / log(min(correlation, 0.95))) : 0.5
        let settings = grainSettings(luma: luma, sizePixels: sizePixels, level: level)
        return AppLookReport.Grain(
            luma: Double(luma),
            chroma: Double(median(samples.map(\.chroma))),
            correlation: Double(correlation),
            sizePixels: Double(sizePixels),
            byLevel: byLevel,
            suggestedAmount: settings.amount,
            suggestedSize: settings.size,
        )
    }

    /// Redlamp's grain adds `noise × amount × 0.16 × midtone weight` to encoded values, where
    /// the value noise has a standard deviation of about 0.21; this inverts that at the grey
    /// level measured, and maps the correlation length onto the 0.6–3.5 px size range.
    static func grainSettings(luma: Float, sizePixels: Float, level: Float) -> (amount: Double, size: Double) {
        let sigma = max(luma * luma - grainFloor * grainFloor, 0).squareRoot()
        let weight = 0.35 + 2.6 * level * (1 - level)
        let amount = sigma < 0.0015 ? 0 : min(100, sigma / (0.16 * 0.2145 * weight) * 100)
        let size = min(max((sizePixels - 0.6) / 2.9 * 100, 0), 100)
        return (Double(amount.rounded()), Double(size.rounded()))
    }
}
