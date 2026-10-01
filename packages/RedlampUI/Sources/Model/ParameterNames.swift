import RedlampEngineAPI

public extension ParameterID {
    /// The slider's name where its panel isn't in view: "Exposure", "Orange Saturation",
    /// "Shadows Hue", "Grain Size". History steps and the command palette use it.
    var displayName: String {
        let label = spec.label
        if let band = ColorBand.allCases.first(where: { $0.hueParameter == self }) {
            return "\(band.name) Hue"
        }
        if let band = ColorBand.allCases.first(where: { $0.saturationParameter == self }) {
            return "\(band.name) Saturation"
        }
        if let band = ColorBand.allCases.first(where: { $0.luminanceParameter == self }) {
            return "\(band.name) Luminance"
        }
        if let range = GradingRange.allCases.first(where: {
            [$0.hueParameter, $0.saturationParameter, $0.luminanceParameter].contains(self)
        }) {
            return "\(range.name) \(label)"
        }
        if let name = Self.names[self] {
            return name
        }
        if let group = AdjustmentSearch.groups[self] {
            return "\(group) \(label)"
        }
        if PanelID.toneCurve.parameters.contains(self) {
            return "Curve \(label)"
        }
        return label
    }

    /// Lightroom's own names where "group label" would read oddly.
    private static let names: [ParameterID: String] = [
        .noiseLuminance: "Luminance Noise Reduction",
        .noiseLuminanceDetail: "Luminance Detail",
        .noiseLuminanceContrast: "Luminance Contrast",
        .noiseColor: "Color Noise Reduction",
        .noiseColorDetail: "Color Detail",
        .noiseColorSmoothness: "Color Smoothness",
        .vignetteAmount: "Vignette Amount",
        .vignetteMidpoint: "Vignette Midpoint",
        .vignetteRoundness: "Vignette Roundness",
        .vignetteFeather: "Vignette Feather",
        .vignetteHighlights: "Vignette Highlights",
    ]
}
