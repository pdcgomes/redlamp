import Foundation

/// The Develop panels a switch turns off, as Lightroom's panel switches do (UX-30): every panel
/// but Basic. A panel that's off does nothing, as though each of its settings were at the value
/// that leaves the photo alone, and keeps its settings for when it's turned back on. The raw
/// values are the sidecar's names for them (`EditRecipe.panelsOff`).
public enum SwitchablePanel: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case toneCurve, colorMixer, colorGrading, detail, lens, transform, effects, calibration

    public var name: String {
        switch self {
        case .toneCurve: "Tone Curve"
        case .colorMixer: "Color Mixer"
        case .colorGrading: "Color Grading"
        case .detail: "Detail"
        case .lens: "Lens Corrections"
        case .transform: "Transform"
        case .effects: "Effects"
        case .calibration: "Calibration"
        }
    }

    /// Every parameter the panel holds, the camera-recipe controls in Effects and the checkboxes
    /// in Lens Corrections included.
    public var parameters: [ParameterID] {
        switch self {
        case .toneCurve:
            [
                .curveHighlights, .curveLights, .curveDarks, .curveShadows, .curveSplitShadows, .curveSplitMidtones,
                .curveSplitHighlights,
            ]
        case .colorMixer:
            ColorBand.allCases.flatMap { [$0.hueParameter, $0.saturationParameter, $0.luminanceParameter] }
        case .colorGrading:
            GradingRange.allCases.flatMap { [$0.hueParameter, $0.saturationParameter, $0.luminanceParameter] }
                + [.gradeBlending, .gradeBalance]
        case .detail:
            [
                .sharpenAmount, .sharpenRadius, .sharpenDetail, .sharpenMasking, .noiseLuminance,
                .noiseLuminanceDetail, .noiseLuminanceContrast, .noiseColor, .noiseColorDetail,
                .noiseColorSmoothness,
            ]
        case .lens:
            [
                .lensProfile, .lensProfileDistortion, .lensProfileVignetting, .lensRemoveChromaticAberration,
                .defringePurpleAmount, .defringePurpleHueLow, .defringePurpleHueHigh, .defringeGreenAmount,
                .defringeGreenHueLow, .defringeGreenHueHigh, .lensDistortion, .lensVignetting,
                .lensVignettingMidpoint,
            ]
        case .transform:
            [
                .transformVertical, .transformHorizontal, .transformRotate, .transformAspect, .transformScale,
                .transformOffsetX, .transformOffsetY,
            ]
        case .effects:
            [
                .vignetteAmount, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather, .vignetteHighlights,
                .grainAmount, .grainSize, .grainRoughness, .grainColor, .halationAmount, .halationSize, .bloomAmount,
                .bloomSize, .leakAmount, .leakWarmth, .leakVariation, .dustAmount, .scratchAmount, .frameStyle,
                .frameSize, .dynamicRange, .colorChrome, .colorChromeBlue, .wbShiftRed, .wbShiftBlue,
            ]
        case .calibration:
            [
                .calibrationShadowsTint, .calibrationRedHue, .calibrationRedSaturation, .calibrationGreenHue,
                .calibrationGreenSaturation, .calibrationBlueHue, .calibrationBlueSaturation,
            ]
        }
    }

    /// The parts of an edit that aren't parameters the panel holds: Tone Curve's point curve, and
    /// Point Color's swatches on the edit, which the Color Mixer panel shows.
    public var fields: Set<EditField> {
        switch self {
        case .toneCurve: [.pointCurve]
        case .colorMixer: [.pointColor]
        default: []
        }
    }

    /// The panel holding `parameter`, if a switch turns it off.
    public init?(holding parameter: ParameterID) {
        guard let panel = Self.byParameter[parameter] else { return nil }
        self = panel
    }

    private static let byParameter: [ParameterID: SwitchablePanel] = Dictionary(
        uniqueKeysWithValues: allCases.flatMap { panel in panel.parameters.map { ($0, panel) } },
    )

    /// The value at which `parameter` leaves the photo alone: its default, but for the defaults
    /// that change it, sharpening's Amount, colour noise reduction and Enable Profile Corrections
    /// (which also applies the corrections a file carries).
    public static func neutralValue(_ parameter: ParameterID) -> Double {
        switch parameter {
        case .sharpenAmount, .noiseColor, .lensProfile: 0
        default: parameter.spec.defaultValue
        }
    }

    public static func < (lhs: SwitchablePanel, rhs: SwitchablePanel) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public extension EditRecipe {
    func isOn(_ panel: SwitchablePanel) -> Bool {
        !panelsOff.contains(panel)
    }

    mutating func setPanel(_ panel: SwitchablePanel, on: Bool) {
        if on {
            panelsOff.remove(panel)
        } else {
            panelsOff.insert(panel)
        }
    }

    /// The edit as the engine renders it: each switched-off panel's settings at the values that
    /// leave the photo alone, and every panel on. Everything that renders, maps or measures the
    /// photo reads this, so the canvas, export, thumbnails, the command line and overlays agree.
    var rendered: EditRecipe {
        guard !panelsOff.isEmpty else { return self }
        var result = self
        let off = panelsOff
        result.panelsOff = []
        for panel in off {
            for parameter in panel.parameters {
                result[parameter] = SwitchablePanel.neutralValue(parameter)
            }
            if panel.fields.contains(.pointCurve) {
                result.pointCurve = EditRecipe.linearPointCurve
            }
            if panel.fields.contains(.pointColor) {
                result.pointColor = []
            }
        }
        return result
    }
}
