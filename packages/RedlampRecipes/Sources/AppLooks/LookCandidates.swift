import CoreGraphics
import Foundation
import RedlampEngineAPI
import simd

/// How close a candidate look comes to the app's own exports (TON-37), measured on the kit's
/// photos rendered with the candidate and compared with what the app made of them.
public struct LookScore: Codable, Sendable, Hashable {
    /// 0–100, higher is closer: 100 less the weighted errors below.
    public var total: Double
    /// OKLab ΔE × 100 between the render and the app's export, over the photos.
    public var photoMean: Double?
    public var photoP90: Double?
    /// Grain the export has beyond the render's (negative: the render has more), encoded levels.
    public var grain: Double?
    /// The export's edge contrast over the render's: 1 is equal, below 1 the app softened.
    public var sharpness: Double?
    /// Light the export spills beside highlights beyond the render's.
    public var glow: Double?
    /// ΔE between the candidate's table and the charts' measurement, over the colour cube.
    public var chartDeparture: Double
    public var photos: Int
    /// Every photo was scored by a fit that hadn't seen it.
    public var heldOut: Bool

    /// "2 photos" or "the charts only".
    public var basis: String {
        photos == 0 ? "the charts only" : "\(photos) photo\(photos == 1 ? "" : "s")"
    }
}

public struct LookCandidate: Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case measured
        case smoothed
        case chartsAndPhotos = "charts-and-photos"
        case filmEffects = "film-effects"

        public var title: String {
            switch self {
            case .measured: "Measured"
            case .smoothed: "Smoothed"
            case .chartsAndPhotos: "Charts and photos"
            case .filmEffects: "With film effects"
            }
        }
    }

    public var kind: Kind
    public var id: String {
        kind.rawValue
    }

    /// What this candidate is, in a sentence.
    public var detail: String
    public var recipe: Recipe
    public var table: LookTable
    public var score: LookScore
    /// The candidate's render of each photo, at the analysis size, by the photo's name.
    public var renders: [String: PixelImage]
}

/// Candidate looks for one capture, each scored the same way, best first.
public enum LookCandidates {
    public static let analysisSize = 768
    static let smoothness: [Float] = [3, 30, 300]

    /// What the scorer compares: a kit photo (or a one-image kit's tile) and the app's export of it.
    struct Pair {
        var name: String
        var kitFile: URL?
        var kitImage: PixelImage
        /// The tile inside the kit image, in its pixels; nil for a whole photo.
        var region: CGRect?
        var export: PixelImage
    }

    /// Fits and scores the candidates. Without a renderer the photos are previewed through the
    /// table and vignette alone, and the film-effects candidate is skipped.
    public static func make(
        _ inputs: CaptureInputs,
        result: AppLookImport.Result,
        name: String,
        renderer: RecipeRenderer?,
        progress: (@Sendable (String) -> Void)? = nil,
    ) async throws -> [LookCandidate] {
        let pairs = pairs(inputs, result: result)
        let scorer = Scorer(pairs: pairs, renderer: renderer, measured: result.table)
        var candidates: [LookCandidate] = []

        progress?("Scoring the measured table")
        let measuredRecipe = try AppLookRecipe.make(result, name: name)
        let measured = try await scorer.score(measuredRecipe, table: result.table)
        candidates.append(LookCandidate(
            kind: .measured, detail: "The table as the charts measured it, with the vignette and grain they showed.",
            recipe: measuredRecipe, table: result.table, score: measured.score, renders: measured.renders,
        ))

        progress?("Fitting smoothed tables")
        let samples = chartSamples(result.table)
        var bestSmooth: (LookCandidate, Float)?
        for smoothness in smoothness {
            let table = LatticeFit.fit(samples, size: result.table.size, smoothness: smoothness)
            var smoothed = result
            smoothed.table = table
            let recipe = try AppLookRecipe.make(smoothed, name: name)
            let scored = try await scorer.score(recipe, table: table)
            if bestSmooth.map({ scored.score.total > $0.0.score.total }) ?? true {
                bestSmooth = (LookCandidate(
                    kind: .smoothed,
                    detail: "The measured table smoothed (smoothness \(Int(smoothness))), so JPEG noise and patch spread don't become kinks.",
                    recipe: recipe, table: table, score: scored.score, renders: scored.renders,
                ), smoothness)
            }
        }
        if let (candidate, _) = bestSmooth {
            candidates.append(candidate)
        }

        let photoPairs = pairs.filter { $0.region == nil }
        if photoPairs.count >= 2 {
            progress?("Fitting the charts and photos together")
            let smoothness = bestSmooth?.1 ?? 30
            let vignette = result.report.vignette?.model
            let folds = [
                photoPairs.indices.filter { $0.isMultiple(of: 2) },
                photoPairs.indices.filter { !$0.isMultiple(of: 2) },
            ]
            var heldOutRenders: [String: PixelImage] = [:]
            var heldOutScores: [Scorer.PhotoScore] = []
            for fold in folds {
                let train = photoPairs.indices.filter { !fold.contains($0) }.map { photoPairs[$0] }
                let table = LatticeFit.fit(
                    samples + photoSamples(train, vignette: vignette), size: result.table.size, smoothness: smoothness,
                )
                var fitted = result
                fitted.table = table
                let recipe = try AppLookRecipe.make(fitted, name: name)
                for index in fold {
                    let scored = try await scorer.photo(photoPairs[index], recipe: recipe, table: table)
                    heldOutScores.append(scored)
                    heldOutRenders[photoPairs[index].name] = scored.render
                }
            }
            let table = LatticeFit.fit(
                samples + photoSamples(photoPairs, vignette: vignette), size: result.table.size, smoothness: smoothness,
            )
            var fitted = result
            fitted.table = table
            let recipe = try AppLookRecipe.make(fitted, name: name)
            let score = Scorer.combine(heldOutScores, departure: departure(table, result.table), heldOut: true)
            candidates.append(LookCandidate(
                kind: .chartsAndPhotos,
                detail: "Fitted to the charts and the photos' own colours, each photo scored by a fit that left it out.",
                recipe: recipe, table: table, score: score, renders: heldOutRenders,
            ))
        }

        if renderer != nil, !pairs.isEmpty, let base = candidates.max(by: { $0.score.total < $1.score.total }) {
            progress?("Fitting grain, bloom and halation")
            if let effects = try await filmEffects(base, scorer: scorer, result: result) {
                candidates.append(effects)
            }
        }
        return candidates.sorted { $0.score.total > $1.score.total }
    }

    /// The best of `base` with grain, bloom or halation, when one of them scores better.
    static func filmEffects(
        _ base: LookCandidate,
        scorer: Scorer,
        result: AppLookImport.Result,
    ) async throws -> LookCandidate? {
        var best = base
        var changed: [String] = []
        func attempt(_ values: [ParameterID: Double], label: String) async throws {
            var recipe = best.recipe
            recipe.includes.insert(.effects)
            for (parameter, value) in values {
                recipe.settings.values[parameter] = value
            }
            let scored = try await scorer.score(recipe, table: best.table)
            if scored.score.total > best.score.total + 0.25 {
                best = LookCandidate(
                    kind: .filmEffects, detail: "", recipe: recipe, table: best.table,
                    score: scored.score, renders: scored.renders,
                )
                changed.removeAll { $0.hasPrefix(label.prefix(5)) }
                changed.append(label)
            }
        }
        let grain = base.score.grain ?? 0
        let suggested = result.report.grain?.suggestedAmount ?? 0
        let size = result.report.grain?.suggestedSize ?? 25
        if abs(grain) > 0.002 || suggested > 0 {
            let start = base.recipe.settings.values[.grainAmount] ?? 0
            let ladder = start > 0 ? [0, start * 0.5, start * 1.5, start + 15] : [10, 25, 40, 60]
            for amount in Set(ladder.map { ($0 / 5).rounded() * 5 }).sorted() where amount != start {
                try await attempt([.grainAmount: min(amount, 100), .grainSize: size], label: "grain \(Int(amount))")
            }
        }
        if (base.score.glow ?? 0) > 0.006 {
            for amount in [15.0, 30, 50] {
                try await attempt([.bloomAmount: amount], label: "bloom \(Int(amount))")
                try await attempt([.halationAmount: amount], label: "halation \(Int(amount))")
            }
        }
        guard !changed.isEmpty else { return nil }
        best.detail = "\(base.kind.title), with \(changed.joined(separator: " and ")) fitted to the photos' grain and glow."
        return best
    }

    // MARK: - Pairs and samples

    static func pairs(_ inputs: CaptureInputs, result _: AppLookImport.Result) -> [Pair] {
        var pairs = inputs.photos.compactMap { photo -> Pair? in
            let aspect = Float(photo.exportImage.width) / Float(photo.exportImage.height)
            let (w, h) = size(aspect: aspect)
            guard let export = PhotoPairAnalysis.resampled(photo.exportImage, width: w, height: h) else { return nil }
            return Pair(
                name: photo.kitPhoto,
                kitFile: photo.kitFile,
                kitImage: photo.kitImage,
                region: nil,
                export: export,
            )
        }
        // A one-image kit's photo tiles, found in its export through the markers.
        if let compact = inputs.originals.compact, let export = inputs.charts.first,
           let location = AppLookImport.locate(export.image), location.layout.kind == .compact {
            for (index, tile) in location.layout.photoTiles.enumerated() {
                let target = location.transform.apply(tile)
                let (w, h) = size(aspect: Float(tile.width / tile.height))
                guard target.minX >= 0, target.minY >= 0, target.maxX <= CGFloat(export.image.width),
                      target.maxY <= CGFloat(export.image.height),
                      let exported = PhotoPairAnalysis.resampled(export.image, from: target, width: w, height: h)
                else { continue }
                let name = index < inputs.originals.tileNames.count ? inputs.originals.tileNames[index] : "tile \(index + 1)"
                pairs.append(Pair(
                    name: name,
                    kitFile: inputs.compactKitFile,
                    kitImage: compact,
                    region: tile,
                    export: exported,
                ))
            }
        }
        return pairs
    }

    static func size(aspect: Float) -> (Int, Int) {
        aspect >= 1 ? (analysisSize, Int(Float(analysisSize) / aspect)) : (
            Int(Float(analysisSize) * aspect),
            analysisSize,
        )
    }

    /// The measured table at its lattice points, as samples a smoother fit can follow.
    static func chartSamples(_ table: LookTable) -> [ProfileSample] {
        let n = table.size, step = 1 / Float(n - 1)
        var samples: [ProfileSample] = []
        samples.reserveCapacity(n * n * n)
        for b in 0 ..< n {
            for g in 0 ..< n {
                for r in 0 ..< n {
                    let input = SIMD3(Float(r), Float(g), Float(b)) * step
                    samples.append(ProfileSample(input: input, target: table.sample(input)))
                }
            }
        }
        return samples
    }

    /// Each photo's colours: the kit photo's pixel and the export's, less the measured vignette.
    static func photoSamples(_ pairs: [Pair], vignette: VignetteModel?) -> [ProfileSample] {
        var generator = SeededGenerator(seed: 7)
        var samples: [ProfileSample] = []
        for pair in pairs {
            guard let kit = PhotoPairAnalysis.resampled(
                PhotoPairAnalysis.cropped(
                    pair.kitImage,
                    toAspect: Float(pair.export.width) / Float(pair.export.height),
                ),
                width: pair.export.width, height: pair.export.height,
            ) else { continue }
            let frame = CGRect(x: 0, y: 0, width: kit.width, height: kit.height)
            for _ in 0 ..< 3000 {
                let x = Int.random(in: 0 ..< kit.width, using: &generator)
                let y = Int.random(in: 0 ..< kit.height, using: &generator)
                var target = pair.export[x, y]
                if let vignette {
                    let r = VignetteModel.radius(SIMD2(Float(x) + 0.5, Float(y) + 0.5), in: frame)
                    target /= max(vignette.gain(r, encoded: PhotoPairAnalysis.luma(target)), 0.05)
                }
                samples.append(ProfileSample(input: kit[x, y], target: simd_clamp(target, .zero, .one), weight: 0.5))
            }
        }
        return samples
    }

    /// A table's outputs on a 9³ grid of the colour cube, to compare captures cheaply.
    public static func fingerprint(_ table: LookTable) -> [Float] {
        let n = 9
        return (0 ..< n * n * n).flatMap { i -> [Float] in
            let output = table.sample(SIMD3(Float(i % n), Float(i / n % n), Float(i / (n * n))) / Float(n - 1))
            return [output.x, output.y, output.z]
        }
    }

    /// Mean ΔE between two fingerprints; nil when they don't match in size.
    public static func distance(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var total: Float = 0
        for i in stride(from: 0, to: a.count, by: 3) {
            total += AppLookImport.deltaE(SIMD3(a[i], a[i + 1], a[i + 2]), SIMD3(b[i], b[i + 1], b[i + 2]))
        }
        return Double(total / Float(a.count / 3))
    }

    /// Mean ΔE between two tables over a 9³ grid of the colour cube.
    public static func departure(_ a: LookTable, _ b: LookTable) -> Double {
        var total: Float = 0
        let n = 9
        for i in 0 ..< n * n * n {
            let input = SIMD3(Float(i % n), Float(i / n % n), Float(i / (n * n))) / Float(n - 1)
            total += AppLookImport.deltaE(a.sample(input), b.sample(input))
        }
        return Double(total / Float(n * n * n))
    }

    // MARK: - Scoring

    struct Scorer {
        struct PhotoScore {
            var name: String
            var measures: PhotoPairAnalysis.Measures
            var grain: Float
            var render: PixelImage
        }

        let pairs: [Pair]
        let renderer: RecipeRenderer?
        let measured: LookTable

        func score(
            _ recipe: Recipe,
            table: LookTable,
        ) async throws -> (score: LookScore, renders: [String: PixelImage]) {
            var scores: [PhotoScore] = []
            var compactRender: PixelImage?
            for pair in pairs {
                if pair.region != nil, compactRender == nil {
                    compactRender = try await render(recipe, table: table, pair: pair, whole: true)
                }
                try await scores.append(photo(pair, recipe: recipe, table: table, compactRender: compactRender))
            }
            let renders = Dictionary(scores.map { ($0.name, $0.render) }) { first, _ in first }
            return (Self.combine(scores, departure: LookCandidates.departure(table, measured), heldOut: false), renders)
        }

        /// One photo rendered with the candidate and measured against the app's export.
        func photo(
            _ pair: Pair,
            recipe: Recipe,
            table: LookTable,
            compactRender: PixelImage? = nil,
        ) async throws -> PhotoScore {
            let w = pair.export.width, h = pair.export.height
            let rendered: PixelImage
            if let region = pair.region {
                let whole = if let compactRender {
                    compactRender
                } else {
                    try await render(recipe, table: table, pair: pair, whole: true)
                }
                let scale = CGFloat(whole.width) / CGFloat(pair.kitImage.width)
                let box = CGRect(
                    x: region.minX * scale,
                    y: region.minY * scale,
                    width: region.width * scale,
                    height: region.height * scale,
                )
                rendered = PhotoPairAnalysis.resampled(whole, from: box, width: w, height: h) ?? pair.export
            } else {
                let whole = try await render(recipe, table: table, pair: pair, whole: false)
                rendered = PhotoPairAnalysis.resampled(
                    PhotoPairAnalysis.cropped(whole, toAspect: Float(w) / Float(h)), width: w, height: h,
                ) ?? pair.export
            }
            let measures = PhotoPairAnalysis.measure(
                original: rendered, exported: pair.export, table: .identity(), gain: { _, _ in 1 },
            ) ?? PhotoPairAnalysis.Measures(
                residualMean: 99, residualP90: 99, vignette: nil, cornerGain: nil, vignetteRMS: 0,
                grainLuma: 0, sharpness: 1, glow: 0,
            )
            let grain = PhotoPairAnalysis.signedGrain(
                rendered.pixels.map(PhotoPairAnalysis.luma),
                pair.export.pixels.map(PhotoPairAnalysis.luma),
                width: w,
                height: h,
            )
            return PhotoScore(name: pair.name, measures: measures, grain: grain, render: rendered)
        }

        /// The kit image through the engine (as a bitmap, which renders as the file at defaults,
        /// so the candidate sees what the app saw), or through the table and vignette alone.
        private func render(_ recipe: Recipe, table: LookTable, pair: Pair, whole: Bool) async throws -> PixelImage {
            if let renderer, let file = pair.kitFile {
                let long = whole ? max(pair.kitImage.width, pair.kitImage.height) : LookCandidates.analysisSize * 2
                let image = try await renderer.render(recipe, image: file, maxLongEdge: long)
                if let pixels = PixelImage(image) {
                    return pixels
                }
            }
            let small = whole ? pair.kitImage : (pair.kitImage.cgImage().flatMap { PixelImage(
                $0,
                maxLongEdge: LookCandidates.analysisSize * 2,
            ) } ?? pair.kitImage)
            let vignette = recipe.settings.values[.vignetteAmount].map {
                VignetteModel(
                    amount: $0, midpoint: recipe.settings.values[.vignetteMidpoint] ?? 50,
                    feather: recipe.settings.values[.vignetteFeather] ?? 50,
                )
            }
            return PhotoPairAnalysis.preview(small, table: table, vignette: vignette)
        }

        /// The errors over every photo, weighted into one number: ΔE counts most, then grain,
        /// sharpness and glow, and a little how far the table strays from the charts.
        static func combine(_ scores: [PhotoScore], departure: Double, heldOut: Bool) -> LookScore {
            guard !scores.isEmpty else {
                return LookScore(
                    total: max(0, 100 - 3 * departure), photoMean: nil, photoP90: nil, grain: nil, sharpness: nil,
                    glow: nil, chartDeparture: departure, photos: 0, heldOut: false,
                )
            }
            func mean(_ values: [Float]) -> Double {
                Double(values.reduce(0, +) / Float(values.count))
            }
            let photoMean = mean(scores.map(\.measures.residualMean))
            let p90 = mean(scores.map(\.measures.residualP90))
            let grain = mean(scores.map(\.grain))
            let sharpness = mean(scores.map(\.measures.sharpness))
            let glow = mean(scores.map(\.measures.glow))
            let errors = 6 * photoMean + 2 * p90 + 300 * abs(grain) + 20 * abs(1 - sharpness) + 200 * abs(glow) +
                departure
            return LookScore(
                total: max(0, 100 - errors), photoMean: photoMean, photoP90: p90, grain: grain, sharpness: sharpness,
                glow: glow, chartDeparture: departure, photos: scores.count, heldOut: heldOut,
            )
        }
    }
}

extension PhotoPairAnalysis {
    /// Grain the export has beyond the expected image's, in flat mid-tones; negative when the
    /// expected image has more, so a candidate with too much grain scores worse too.
    static func signedGrain(_ expected: [Float], _ le: [Float], width w: Int, height h: Int) -> Float {
        let be = boxBlur(le, width: w, height: h), bx = boxBlur(expected, width: w, height: h)
        let slopes = gradients(expected, width: w, height: h).map(simd_length)
        let flat = percentile(slopes, 0.4)
        var extra: Float = 0, count: Float = 0
        for i in expected.indices where slopes[i] <= flat && expected[i] > 0.15 && expected[i] < 0.85 {
            let he = le[i] - be[i], hx = expected[i] - bx[i]
            extra += he * he - hx * hx
            count += 1
        }
        guard count > 100 else { return 0 }
        let mean = extra / count
        return mean >= 0 ? mean.squareRoot() : -(-mean).squareRoot()
    }
}
