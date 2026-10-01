import RedlampEngineAPI

/// ⌘F adjustment search: finds a Develop slider by its name, its panel, or the words people use
/// for it (Lightroom's older names among them).
public enum AdjustmentSearch {
    public struct Result: Hashable, Identifiable, Sendable {
        public var parameter: ParameterID
        public var panel: PanelID

        public var id: ParameterID {
            parameter
        }

        /// "Dehaze", or "Luminance · Detail" where the name alone is ambiguous.
        public var title: String {
            let label = parameter.spec.label
            let shared = Self.ambiguousLabels.contains(label)
            return shared ? "\(label) · \(context)" : label
        }

        /// Where the slider lives, for the second line.
        public var context: String {
            if let band = ColorBand.allCases.first(where: {
                [$0.hueParameter, $0.saturationParameter, $0.luminanceParameter].contains(parameter)
            }) {
                return "\(panel.title), \(band.name)"
            }
            if let range = GradingRange.allCases.first(where: {
                [$0.hueParameter, $0.saturationParameter, $0.luminanceParameter].contains(parameter)
            }) {
                return "\(panel.title), \(range.name)"
            }
            if let group = AdjustmentSearch.groups[parameter] {
                return "\(panel.title), \(group)"
            }
            return panel.title
        }

        private static let ambiguousLabels: Set<String> = {
            var counts: [String: Int] = [:]
            for parameter in AdjustmentSearch.searchable.map(\.parameter) {
                counts[parameter.spec.label, default: 0] += 1
            }
            return Set(counts.filter { $0.value > 1 }.keys)
        }()
    }

    /// The best matches for `query`, most relevant first.
    public static func results(for query: String, limit: Int = 8) -> [Result] {
        let words = normalized(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let scored = searchable.compactMap { result -> (Result, Int)? in
            let terms = searchTerms(result)
            var total = 0
            for word in words {
                guard let best = terms.map({ score(word, $0) }).max(), best > 0 else { return nil }
                total += best
            }
            return (result, total)
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : order[$0.0.parameter]! < order[$1.0.parameter]! }
            .prefix(limit)
            .map(\.0)
    }

    /// Live sliders in the Develop panels, in panel order.
    static let searchable: [Result] = PanelID.allCases.flatMap { panel in
        panel.parameters.filter(\.spec.availability.isLive).map { Result(parameter: $0, panel: panel) }
    }

    private static let order: [ParameterID: Int] = Dictionary(
        uniqueKeysWithValues: searchable.enumerated().map { ($0.element.parameter, $0.offset) },
    )

    private static func searchTerms(_ result: Result) -> [String] {
        ([result.parameter.spec.label, result.context] + (synonyms[result.parameter] ?? [])).map(normalized)
    }

    /// Exact word 3, word prefix 2, substring 1.
    private static func score(_ word: String, _ term: String) -> Int {
        let termWords = term.split(separator: " ").map(String.init)
        if termWords.contains(word) {
            return 3
        }
        if termWords.contains(where: { $0.hasPrefix(word) }) {
            return 2
        }
        return word.count >= 3 && term.contains(word) ? 1 : 0
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "colour", with: "color")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "·", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Groups within a panel, for the context line.
    static let groups: [ParameterID: String] = [
        .sharpenAmount: "Sharpening", .sharpenRadius: "Sharpening", .sharpenDetail: "Sharpening",
        .sharpenMasking: "Sharpening",
        .noiseLuminance: "Noise Reduction", .noiseLuminanceDetail: "Noise Reduction",
        .noiseLuminanceContrast: "Noise Reduction", .noiseColor: "Noise Reduction",
        .noiseColorDetail: "Noise Reduction", .noiseColorSmoothness: "Noise Reduction",
        .vignetteAmount: "Post-Crop Vignetting", .vignetteMidpoint: "Post-Crop Vignetting",
        .vignetteRoundness: "Post-Crop Vignetting", .vignetteFeather: "Post-Crop Vignetting",
        .grainAmount: "Grain", .grainSize: "Grain", .grainRoughness: "Grain", .grainColor: "Grain",
        .halationAmount: "Halation", .halationSize: "Halation", .bloomAmount: "Bloom", .bloomSize: "Bloom",
    ]

    /// The words people use: Lightroom's current and older names, and plain descriptions.
    static let synonyms: [ParameterID: [String]] = [
        .temperature: ["white balance", "wb", "kelvin", "warm", "cool", "warmth"],
        .tint: ["white balance", "wb", "magenta", "green"],
        .exposure: ["brightness", "ev", "brighten", "darken", "exposure"],
        .contrast: ["punch", "flat"],
        .highlights: ["recovery", "highlight recovery", "bright areas"],
        .shadows: ["fill light", "fill", "lift", "dark areas"],
        .whites: ["white point", "white clipping"],
        .blacks: ["black point", "black clipping", "crush"],
        .texture: ["detail", "fine detail", "skin", "smooth"],
        .clarity: ["local contrast", "midtone contrast", "punch", "soften"],
        .dehaze: ["haze", "fog", "mist", "atmosphere", "smog"],
        .vibrance: ["color", "intensity", "muted", "saturation"],
        .saturation: ["color", "intensity", "vivid", "desaturate", "black and white"],
        .curveHighlights: ["curve", "tone curve", "parametric"],
        .curveLights: ["curve", "tone curve", "parametric"],
        .curveDarks: ["curve", "tone curve", "parametric"],
        .curveShadows: ["curve", "tone curve", "parametric"],
        .sharpenAmount: ["sharpening", "sharpen", "sharpness", "crisp"],
        .sharpenRadius: ["sharpening", "sharpen", "sharpness"],
        .sharpenDetail: ["sharpening", "sharpen", "halo"],
        .sharpenMasking: ["sharpening", "sharpen", "edge mask"],
        .noiseLuminance: ["noise", "noise reduction", "nr", "denoise", "grainy", "luminance noise"],
        .noiseLuminanceDetail: ["noise", "noise reduction", "nr", "denoise"],
        .noiseLuminanceContrast: ["noise", "noise reduction", "nr", "denoise"],
        .noiseColor: ["noise", "noise reduction", "nr", "denoise", "color noise", "chroma noise"],
        .noiseColorDetail: ["noise", "noise reduction", "nr", "color noise"],
        .noiseColorSmoothness: ["noise", "noise reduction", "nr", "color noise", "mottling"],
        .vignetteAmount: ["vignette", "vignetting", "corners", "edges"],
        .vignetteMidpoint: ["vignette", "vignetting"],
        .vignetteRoundness: ["vignette", "vignetting"],
        .vignetteFeather: ["vignette", "vignetting", "soft"],
        .grainAmount: ["grain", "film grain", "film"],
        .grainSize: ["grain", "film grain"],
        .grainRoughness: ["grain", "film grain"],
        .grainColor: ["grain", "film grain", "color grain", "chroma grain"],
        .halationAmount: ["halation", "glow", "film", "cinestill", "red glow"],
        .halationSize: ["halation", "glow"],
        .bloomAmount: ["bloom", "glow", "diffusion", "mist", "pro-mist", "soft"],
        .bloomSize: ["bloom", "glow", "diffusion", "mist"],
        .gradeBlending: ["split toning", "color grading", "toning"],
        .gradeBalance: ["split toning", "color grading", "toning"],
    ].merging(mixerAndGradingSynonyms) { $0 + $1 }

    private static var mixerAndGradingSynonyms: [ParameterID: [String]] {
        var result: [ParameterID: [String]] = [:]
        for band in ColorBand.allCases {
            result[band.hueParameter] = ["hsl", "color mixer", "hue"]
            result[band.saturationParameter] = ["hsl", "color mixer", "saturation"]
            result[band.luminanceParameter] = ["hsl", "color mixer", "luminance"]
        }
        for range in GradingRange.allCases {
            for parameter in [range.hueParameter, range.saturationParameter, range.luminanceParameter] {
                result[parameter] = ["split toning", "color grading", "toning", "color wheels"]
            }
        }
        return result
    }
}

public extension EditorModel {
    /// Opens the slider's panel, focuses it and scrolls it into view.
    func reveal(_ parameter: ParameterID) {
        if let panel = PanelID.allCases.first(where: { $0.parameters.contains(parameter) }) {
            expandedPanels.insert(panel)
        }
        focusedParameter = parameter
        revealedParameter = parameter
        showAdjustmentSearch = false
    }
}
