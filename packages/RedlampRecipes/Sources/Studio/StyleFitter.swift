import CoreGraphics
import Foundation
import RedlampEngineAPI

/// Moves a recipe towards a target fingerprint by rendering candidates through the real
/// engine on a set of photos: a seeded pattern search, so runs are reproducible.
///
/// It gives the Colorist a starting point; it never decides what's good.
public final class StyleFitter {
    public struct Result: Sendable {
        public var recipe: Recipe
        public var distance: Double
        public var startDistance: Double
        public var evaluations: Int
        public var design: LookDesign?
    }

    /// One tunable dimension.
    struct Dimension {
        var name: String
        var range: ClosedRange<Double>
        var step: Double
        var get: (Candidate) -> Double
        var set: (inout Candidate, Double) -> Void
    }

    /// What the search moves: recipe values, and optionally a look design.
    struct Candidate {
        var values: [ParameterID: Double] = [:]
        var shadowTint = (a: 0.0, b: 0.0)
        var highlightTint = (a: 0.0, b: 0.0)
        var fade = 0.0
        var design = LookDesign()
    }

    private let renderer: RecipeRenderer
    private let images: [URL]
    public let renderSize: Int

    public init(renderer: RecipeRenderer, images: [URL], renderSize: Int = StyleFingerprint.analysisSize) {
        self.renderer = renderer
        self.images = images
        self.renderSize = renderSize
    }

    static let recipeParameters: [(ParameterID, ClosedRange<Double>, Double)] = [
        (.contrast, -60 ... 60, 12), (.highlights, -70 ... 40, 12), (.shadows, -40 ... 60, 12),
        (.whites, -40 ... 40, 10), (.blacks, -40 ... 40, 10), (.saturation, -80 ... 40, 12),
        (.vibrance, -50 ... 50, 12), (.colorChrome, 0 ... 100, 20), (.wbShiftRed, -60 ... 60, 12),
        (.wbShiftBlue, -60 ... 60, 12), (.hueOrange, -30 ... 30, 8), (.hueGreen, -40 ... 40, 10),
        (.hueBlue, -30 ... 30, 8), (.saturationGreen, -60 ... 30, 12), (.saturationBlue, -60 ... 30, 12),
        (.grainAmount, 0 ... 50, 10), (.vignetteAmount, -50 ... 0, 10),
    ]

    func dimensions(useLookTable: Bool) -> [Dimension] {
        var result = Self.recipeParameters.map { parameter, range, step in
            Dimension(
                name: parameter.rawValue, range: range, step: step,
                get: { $0.values[parameter] ?? parameter.spec.defaultValue },
                set: { $0.values[parameter] = $1 },
            )
        }
        result += [
            Dimension(
                name: "shadowTint.a",
                range: -0.04 ... 0.04,
                step: 0.008,
                get: { $0.shadowTint.a },
                set: { $0.shadowTint.a = $1 },
            ),
            Dimension(
                name: "shadowTint.b",
                range: -0.04 ... 0.04,
                step: 0.008,
                get: { $0.shadowTint.b },
                set: { $0.shadowTint.b = $1 },
            ),
            Dimension(
                name: "highlightTint.a",
                range: -0.04 ... 0.04,
                step: 0.008,
                get: { $0.highlightTint.a },
                set: { $0.highlightTint.a = $1 },
            ),
            Dimension(
                name: "highlightTint.b",
                range: -0.04 ... 0.04,
                step: 0.008,
                get: { $0.highlightTint.b },
                set: { $0.highlightTint.b = $1 },
            ),
            Dimension(name: "fade", range: 0 ... 0.15, step: 0.03, get: { $0.fade }, set: { $0.fade = $1 }),
        ]
        if useLookTable {
            result += [
                Dimension(
                    name: "design.contrast",
                    range: -0.6 ... 0.6,
                    step: 0.15,
                    get: { $0.design.contrast },
                    set: { $0.design.contrast = $1 },
                ),
                Dimension(
                    name: "design.density",
                    range: 0 ... 1,
                    step: 0.2,
                    get: { $0.design.density },
                    set: { $0.design.density = $1 },
                ),
                Dimension(
                    name: "design.highlightDesaturation",
                    range: 0 ... 0.8,
                    step: 0.2,
                    get: { $0.design.highlightDesaturation },
                    set: { $0.design.highlightDesaturation = $1 },
                ),
                Dimension(
                    name: "design.shadowDesaturation",
                    range: 0 ... 0.8,
                    step: 0.2,
                    get: { $0.design.shadowDesaturation },
                    set: { $0.design.shadowDesaturation = $1 },
                ),
            ]
        }
        return result
    }

    /// The candidate as a recipe the renderer can apply.
    func recipe(_ candidate: Candidate, name: String, useLookTable: Bool, id: String) throws -> Recipe {
        var values = candidate.values
        func grade(_ tint: (a: Double, b: Double), hue: ParameterID, saturation: ParameterID) {
            let length = (tint.a * tint.a + tint.b * tint.b).squareRoot()
            guard length > 1e-4 else { return }
            var degrees = atan2(tint.b, tint.a) * 180 / .pi
            if degrees < 0 {
                degrees += 360
            }
            // The grading wheels' saturation 100 is an OKLab offset of 0.1 in shadows, 0.08 in highlights.
            values[hue] = degrees.rounded()
            values[saturation] = min(length / (hue == .gradeShadowsHue ? 0.001 : 0.0008), 100).rounded()
        }
        grade(candidate.shadowTint, hue: .gradeShadowsHue, saturation: .gradeShadowsSaturation)
        grade(candidate.highlightTint, hue: .gradeHighlightsHue, saturation: .gradeHighlightsSaturation)
        for (key, value) in values {
            values[key] = key.spec.quantize(value)
        }
        var curve: [CurvePoint]?
        if candidate.fade > 0.005 {
            curve = [
                CurvePoint(x: 0, y: candidate.fade),
                CurvePoint(x: 0.5, y: 0.5 + candidate.fade * 0.25),
                CurvePoint(x: 1, y: 1),
            ]
        }
        var looks: [BaseLookPackage] = []
        var baseLook: BaseLookReference?
        if useLookTable {
            let table = try LookSynthesizer.table(for: candidate.design, size: 17)
            let package = BaseLookPackage(id: id + "/look", name: name, summary: "Fitted look", table: table)
            looks = [package]
            baseLook = package.reference
        }
        var includes: Set<RecipeSettingGroup> = [
            .tone,
            .presence,
            .colorMixer,
            .colorGrading,
            .effects,
            .colorChrome,
            .whiteBalance,
            .toneCurve,
        ]
        if baseLook != nil {
            includes.insert(.baseLook)
        }
        return Recipe(
            id: id, name: name, group: "Fitted", tags: ["fitted"], includes: includes,
            settings: RecipeSettings(
                values: values.filter { abs($0.value - $0.key.spec.defaultValue) > 1e-9 },
                whiteBalanceMode: .asShot,
                pointCurve: curve,
            ),
            baseLook: baseLook, embeddedBaseLooks: looks, created: Date(),
        )
    }

    /// The mean fingerprint of a recipe's renders over the fitter's images.
    public func fingerprint(of recipe: Recipe?) async throws -> StyleFingerprint {
        var prints: [StyleFingerprint] = []
        for image in images {
            let rendered = try await renderer.render(recipe, image: image, maxLongEdge: renderSize)
            if let pixels = PixelImage(rendered) {
                prints.append(StyleFingerprint(pixels))
            }
        }
        return try StyleFingerprint.average(prints)
    }

    public func fit(
        to target: StyleFingerprint,
        name: String,
        start: Recipe? = nil,
        useLookTable: Bool = false,
        evaluations budget: Int = 160,
        seed: UInt64 = 1,
        id: String = RecipeNamespace.newLocalID(),
    ) async throws -> Result {
        let dimensions = dimensions(useLookTable: useLookTable)
        var best = Candidate()
        if let start {
            for (parameter, value) in start.settings.values {
                best.values[parameter] = value
            }
        }
        var evaluations = 0
        func score(_ candidate: Candidate) async throws -> Double {
            evaluations += 1
            return try await fingerprint(of: recipe(candidate, name: name, useLookTable: useLookTable, id: id))
                .distance(to: target)
        }
        var bestScore = try await score(best)
        let startDistance = bestScore
        var steps = dimensions.map(\.step)
        var generator = SeededGenerator(seed: seed)
        var improvedInPass = true
        while evaluations < budget, improvedInPass || steps.contains(where: { $0 > 0 }) {
            improvedInPass = false
            for index in dimensions.indices.shuffled(using: &generator) where evaluations < budget {
                let dimension = dimensions[index]
                guard steps[index] > dimension.step / 8 else { continue }
                var moved = false
                for direction in [1.0, -1.0] where evaluations < budget {
                    var candidate = best
                    let value = min(
                        max(dimension.get(best) + direction * steps[index], dimension.range.lowerBound),
                        dimension.range.upperBound,
                    )
                    guard value != dimension.get(best) else { continue }
                    dimension.set(&candidate, value)
                    let candidateScore = try await score(candidate)
                    if candidateScore < bestScore - 1e-4 {
                        best = candidate
                        bestScore = candidateScore
                        moved = true
                        improvedInPass = true
                        break
                    }
                }
                if !moved {
                    steps[index] /= 2
                }
            }
            if !improvedInPass, steps.allSatisfy({ $0 <= 0 }) {
                break
            }
            if !improvedInPass, zip(steps, dimensions).allSatisfy({ $0 <= $1.step / 8 }) {
                break
            }
        }
        var fitted = try recipe(best, name: name, useLookTable: useLookTable, id: id)
        if useLookTable, let package = fitted.embeddedBaseLooks.first {
            // Store the final look at full resolution.
            let table = try LookSynthesizer.table(for: best.design)
            let full = BaseLookPackage(id: package.id, name: package.name, summary: package.summary, table: table)
            fitted.embeddedBaseLooks = [full]
            fitted.baseLook = full.reference
        }
        fitted.summary = "Fitted to a reference fingerprint (distance \(String(format: "%.2f", bestScore)))."
        return Result(
            recipe: fitted,
            distance: bestScore,
            startDistance: startDistance,
            evaluations: evaluations,
            design: useLookTable ? best.design : nil,
        )
    }
}

/// SplitMix64: a small, seedable generator for reproducible searches.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
