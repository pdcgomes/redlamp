import CoreGraphics
import Foundation
import RedlampEngineAPI
import simd

public enum AppLookImportError: Error, CustomStringConvertible, Equatable {
    case markersNotFound(file: String)
    case latticeCut(file: String, visible: Double)
    case unknownChart(file: String)
    case noCharts
    case severalCompact(files: [String])

    public var description: String {
        switch self {
        case let .markersNotFound(file):
            "\(file): no capture-chart markers found (is it a kit chart, exported without rotation?)"
        case let .latticeCut(file, visible):
            "\(file): the app cut the colour lattice (\(String(format: "%.0f", visible * 100))% of it is visible). "
                + "Export again at the original aspect ratio, without a crop."
        case let .unknownChart(file):
            "\(file): the chart number can't be read; keep the kit's file name (…-chart-1.png) or re-export"
        case .noCharts:
            "no capture charts among the exports"
        case let .severalCompact(files):
            "several one-image kit exports (\(files.joined(separator: ", "))): "
                + "import each filter's export from its own folder"
        }
    }
}

/// Turns phone-app exports of the capture kit into a Base Look table plus measured spatial
/// effects. See `CaptureLayout` for the layouts and docs/recipes/app-looks.md for the workflow.
public enum AppLookImport {
    public struct Export: Sendable {
        public var name: String
        public var image: PixelImage
        /// The chart index (0-based) the file name suggests, used if the barcode can't be read.
        public var chartHint: Int?

        public init(name: String, image: PixelImage, chartHint: Int? = nil) {
            self.name = name
            self.image = image
            self.chartHint = chartHint
        }
    }

    /// Where a chart is in an export.
    public struct Location: Sendable {
        public var layout: CaptureLayout
        /// 0-based, from the barcode; nil when it can't be read.
        public var chart: Int?
        public var transform: ChartTransform
        public var markersFound: Int
        public var markerResidual: Float
    }

    public struct Result: Sendable {
        /// sRGB-encoded sRGB in and out, like a `.cube` or HaldCLUT, whatever `space` says:
        /// `baseLookTable()` converts it with `LookTableImport.adapt`.
        public var table: LookTable
        public var report: AppLookReport

        public func baseLookTable() throws -> LookTable {
            try LookTableImport.adapt({ table.sample($0) }, from: .sRGB, size: LookTableImport.storedSize)
        }
    }

    struct NodeSample {
        var node: SIMD3<Int>
        var input: SIMD3<Float>
        var output: SIMD3<Float>
        var spread: Float
    }

    struct RampSample {
        var input: Float
        var output: SIMD3<Float>
        var spread: Float
    }

    struct VignetteFit {
        var model: VignetteModel
        var frame: String
        var rms: Float
        var cornerGain: Float
        var irregularity: Float
        var cornerTint: SIMD3<Float>
    }

    struct GrainSample {
        var luma: Float
        var chroma: Float
        var correlation: Float
    }

    struct ChartMeasurement {
        var nodes: [NodeSample]
        var rejected: Int
        var ramp: [RampSample]
        var vignette: VignetteFit?
        var grain: GrainSample?
        var greyLevel: Float
        var report: AppLookReport.Chart
        var resolution: AppLookReport.Resolution?
    }

    // MARK: - Locating

    /// Finds a capture chart in an image; nil when it has no markers (a photo).
    /// The layout whose barcode reads as its own wins; then the one with more markers.
    public static func locate(_ image: PixelImage) -> Location? {
        let candidates = ChartDetection.candidates(in: image)
        var best: (location: Location, confirmed: Bool)?
        for layout in CaptureLayout.all {
            guard let fit = ChartDetection.fit(candidates, layout: layout) else { continue }
            let code = readBarcode(image, fit.transform, layout: layout)
            let confirmed = code?.layout == layout
            let location = Location(
                layout: layout,
                chart: confirmed ? code?.chart : nil,
                transform: fit.transform,
                markersFound: fit.markers.count,
                markerResidual: (fit.residual / Float(max(fit.markers.count, 1))).squareRoot(),
            )
            if let current = best {
                let better = confirmed != current.confirmed ? confirmed
                    : location.markersFound != current.location.markersFound
                    ? location.markersFound > current.location.markersFound
                    : location.markerResidual < current.location.markerResidual
                guard better else { continue }
            }
            best = (location, confirmed)
        }
        return best?.location
    }

    static func readBarcode(
        _ image: PixelImage,
        _ transform: ChartTransform,
        layout: CaptureLayout,
    ) -> (layout: CaptureLayout, chart: Int)? {
        for copy in layout.barcodeCopies {
            let levels = copy.map { rect -> Float? in
                let cell = transform.apply(rect.insetBy(dx: rect.width / 4, dy: rect.height / 4))
                let pixels = image.pixels(in: cell)
                return pixels.isEmpty ? nil : median(pixels.map { simd_dot($0, ColorMath.rec709Luma) })
            }
            guard levels.allSatisfy({ $0 != nil }) else { continue }
            let values = levels.compactMap(\.self)
            let threshold = (values[0] + values[1]) / 2
            guard values[1] - values[0] > 0.1,
                  let code = CaptureLayout.decodeBarcode(values.map { $0 < threshold }) else { continue }
            return code
        }
        return nil
    }

    // MARK: - Reading

    /// The kit files the exports were made from. Without them the layouts' own values are
    /// used for the lattice, and a compact export's photo tiles aren't measured.
    public struct Originals: Sendable {
        /// Full-kit charts by 0-based index.
        public var charts: [Int: PixelImage]
        public var compact: PixelImage?
        /// What each compact photo tile shows, in tile order.
        public var tileNames: [String]

        public init(charts: [Int: PixelImage] = [:], compact: PixelImage? = nil, tileNames: [String] = []) {
            self.charts = charts
            self.compact = compact
            self.tileNames = tileNames
        }
    }

    public static func read(_ exports: [Export], originals: [Int: PixelImage] = [:]) throws -> Result {
        try read(exports, sources: Originals(charts: originals))
    }

    /// Measures the exports and builds the table. They can be full-kit charts or one compact
    /// export; the barcode says which. Full charts win when a folder holds both.
    public static func read(_ exports: [Export], sources: Originals) throws -> Result {
        guard !exports.isEmpty else { throw AppLookImportError.noCharts }
        var located: [(export: Export, location: Location)] = []
        for export in exports {
            guard let location = locate(export.image) else {
                throw AppLookImportError.markersNotFound(file: export.name)
            }
            try checkLattice(location, in: export)
            located.append((export, location))
        }
        let compact = located.filter { $0.location.layout.kind == .compact }
        let full = located.filter { $0.location.layout.kind == .full }
        var warnings: [String] = []
        if !full.isEmpty {
            if !compact.isEmpty {
                warnings.append(
                    "\(compact.map(\.export.name).joined(separator: ", ")): one-image kit exports ignored; "
                        + "the full charts were used",
                )
            }
            return try readFull(full, originals: sources.charts, warnings: warnings)
        }
        guard compact.count == 1, let item = compact.first else {
            throw AppLookImportError.severalCompact(files: compact.map(\.export.name))
        }
        warnings += geometryWarnings(item.export, item.location)
        let measurement = measure(chart: 0, export: item.export, location: item.location, original: sources.compact)
        var result = try assemble([measurement], layout: .compact, warnings: warnings)
        if let original = sources.compact {
            let photos = tilePhotos(
                item.export, item.location, original: original, names: sources.tileNames, result: result,
            )
            let tiles = item.location.layout.photoTiles.count
            if photos.count < tiles {
                result.report.warnings
                    .append("\(tiles - photos.count) of \(tiles) photo tiles were cut off or too small")
            }
            result.report.add(photos: photos)
        }
        return result
    }

    static func measure(chart: Int, export: Export, location: Location, original: PixelImage?) -> ChartMeasurement {
        let image = export.image
        let layout = location.layout
        let transform = location.transform
        let s = transform.meanScale
        let width = Float(image.width), height = Float(image.height)

        let probes = layout.probes(chart: chart)
        var samples: [GainField.Sample] = []
        for probe in probes {
            let centre = transform.apply(probe.centre)
            let r = max(1, probe.radius * s)
            let rect = CGRect(
                x: CGFloat(centre.x - r),
                y: CGFloat(centre.y - r),
                width: CGFloat(2 * r),
                height: CGFloat(2 * r),
            )
            guard image.contains(rect) else { continue }
            let pixels = image.pixels(in: rect)
            if !pixels.isEmpty {
                samples.append(GainField.Sample(position: centre, value: median(pixels)))
            }
        }
        let field = GainField.fit(samples, width: width, height: height, spacing: max(width, height) / 24)
        let chartFrame = transform.apply(CGRect(x: 0, y: 0, width: layout.side, height: layout.side))
        let exportFrame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let vignette = samples.count >= 40
            ? fitVignette(field, positions: samples.map(\.position), frames: [
                ("export", exportFrame), ("chart", chartFrame),
            ])
            : nil
        let frame = vignette?.frame == "chart" ? chartFrame : exportFrame
        let reference = field.value(at: SIMD2(Float(frame.midX), Float(frame.midY)))
        func gain(_ p: SIMD2<Float>) -> SIMD3<Float> {
            samples.count >= 40 ? field.value(at: p) / simd_max(reference, SIMD3(repeating: 1e-3)) : .one
        }

        var nodes: [NodeSample] = []
        for patch in layout.patches(chart: chart) {
            let inner = patch.rect.insetBy(dx: patch.rect.width / 4, dy: patch.rect.height / 4)
            var pixels = image.pixels(in: transform.apply(inner))
            if pixels.isEmpty {
                let c = transform.apply(patch.centre)
                pixels = [image[min(max(Int(c.x), 0), image.width - 1), min(max(Int(c.y), 0), image.height - 1)]]
            }
            let luma = pixels.map { simd_dot($0, ColorMath.rec709Luma) }
            let middle = median(luma)
            let spread = 1.4826 * median(luma.map { abs($0 - middle) })
            let input = original.map { median($0.pixels(in: inner)) } ?? layout.nodeValue(patch.node)
            let output = median(pixels) / gain(transform.apply(patch.centre))
            nodes.append(NodeSample(node: patch.node, input: input, output: output, spread: spread))
        }
        let typical = median(nodes.map(\.spread))
        let limit = max(0.05, 6 * typical)
        let kept = nodes.filter { $0.spread <= limit }

        let ramp = rampSamples(image, transform, layout: layout, gain: gain)
        let margin = CGFloat(0.01 * max(width, height))
        let chartReport = AppLookReport.Chart(
            number: chart + 1, file: export.name, width: image.width, height: image.height, transform: transform,
            markersFound: location.markersFound, markerResidual: Double(location.markerResidual),
            probes: samples.count, patches: kept.count, rejectedPatches: nodes.count - kept.count,
            rampVisible: !ramp.isEmpty,
            borderDetected: chartFrame.minX > margin || chartFrame.minY > margin
                || chartFrame.maxX < exportFrame.maxX - margin || chartFrame.maxY < exportFrame.maxY - margin,
        )
        return ChartMeasurement(
            nodes: kept, rejected: nodes.count - kept.count, ramp: ramp, vignette: vignette,
            grain: grain(image, probes: probes, transform: transform),
            greyLevel: simd_dot(reference, ColorMath.rec709Luma), report: chartReport,
            resolution: resolution(image, location: location),
        )
    }
}

// MARK: - Measurements

extension AppLookImport {
    static func rampSamples(
        _ image: PixelImage,
        _ transform: ChartTransform,
        layout: CaptureLayout,
        gain: (SIMD2<Float>) -> SIMD3<Float>,
    ) -> [RampSample] {
        let ramp = layout.rampRect
        guard image.contains(transform.apply(ramp.insetBy(dx: 0, dy: 10))) else { return [] }
        let count = 64
        return (0 ..< count).compactMap { k in
            let x = Float(ramp.minX) + (Float(k) + 0.5) / Float(count) * Float(ramp.width)
            let rect = CGRect(x: CGFloat(x - 3), y: ramp.minY + 12, width: 6, height: ramp.height - 24)
            let pixels = image.pixels(in: transform.apply(rect))
            guard !pixels.isEmpty else { return nil }
            let luma = pixels.map { simd_dot($0, ColorMath.rec709Luma) }
            let mean = luma.reduce(0, +) / Float(luma.count)
            let variance = luma.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(max(luma.count - 1, 1))
            let centre = transform.apply(SIMD2(x, Float(ramp.midY)))
            return RampSample(
                input: layout.rampLevel(x: x),
                output: median(pixels) / gain(centre),
                spread: variance.squareRoot(),
            )
        }
    }

    static func fitVignette(
        _ field: GainField,
        positions: [SIMD2<Float>],
        frames: [(String, CGRect)],
    ) -> VignetteFit? {
        var best: VignetteFit?
        for (name, frame) in frames {
            let centre = field.value(at: SIMD2(Float(frame.midX), Float(frame.midY)))
            let level = simd_dot(centre, ColorMath.rec709Luma)
            guard level > 0.02 else { continue }
            let values = positions.map { field.value(at: $0) }
            let points = zip(positions, values).map {
                (radius: VignetteModel.radius($0.0, in: frame), gain: simd_dot($0.1, ColorMath.rec709Luma) / level)
            }
            let (model, rms) = VignetteModel.fit(points, level: level)
            guard rms < (best?.rms ?? .infinity) else { continue }
            let tints = zip(points, values).map { point, value -> SIMD3<Float> in
                value / simd_max(centre, SIMD3(repeating: 1e-3)) / max(point.gain, 1e-3)
            }
            let corner = zip(points, tints).filter { $0.0.radius > 1.2 }.map(\.1)
            let tint = corner.isEmpty ? SIMD3<Float>.one : median(corner)
            let irregularity = (tints.reduce(Float(0)) { $0 + simd_length_squared($1 - .one) }
                / Float(max(tints.count, 1))).squareRoot()
            best = VignetteFit(
                model: model, frame: name, rms: rms,
                cornerGain: model.gain(Float(2).squareRoot(), encoded: level), irregularity: irregularity,
                cornerTint: tint,
            )
        }
        return best
    }

    /// Residual statistics in open grey windows: grain strength, colour and coarseness.
    static func grain(_ image: PixelImage, probes: [CaptureLayout.Probe], transform: ChartTransform) -> GrainSample? {
        let half = max(2, Int((10 * transform.meanScale).rounded()))
        var lumas: [Float] = [], chromas: [Float] = [], correlations: [Float] = []
        for probe in probes where probe.open {
            let c = transform.apply(probe.centre)
            let x0 = Int(c.x) - half, y0 = Int(c.y) - half, n = 2 * half + 1
            guard x0 >= 0, y0 >= 0, x0 + n <= image.width, y0 + n <= image.height else { continue }
            var luma = [Float](repeating: 0, count: n * n)
            var colour = [SIMD3<Float>](repeating: .zero, count: n * n)
            for y in 0 ..< n {
                for x in 0 ..< n {
                    let p = image[x0 + x, y0 + y]
                    luma[y * n + x] = simd_dot(p, ColorMath.rec709Luma)
                    colour[y * n + x] = p
                }
            }
            let meanLuma = luma.reduce(0, +) / Float(luma.count)
            let meanColour = colour.reduce(.zero, +) / Float(colour.count)
            var sumSquares: Float = 0, lagged: Float = 0, chroma: Float = 0
            for y in 0 ..< n {
                for x in 0 ..< n {
                    let r = luma[y * n + x] - meanLuma
                    sumSquares += r * r
                    if x + 1 < n {
                        lagged += r * (luma[y * n + x + 1] - meanLuma)
                    }
                    let cr = colour[y * n + x] - meanColour - SIMD3(repeating: r)
                    chroma += simd_length_squared(cr) / 3
                }
            }
            lumas.append((sumSquares / Float(n * n - 1)).squareRoot())
            chromas.append((chroma / Float(n * n - 1)).squareRoot())
            correlations.append(sumSquares > 1e-10 ? lagged / sumSquares * Float(n) / Float(n - 1) : 0)
        }
        guard lumas.count >= 10 else { return nil }
        return GrainSample(luma: median(lumas), chroma: median(chromas), correlation: median(correlations))
    }
}
