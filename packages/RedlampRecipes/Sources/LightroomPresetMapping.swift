import Foundation
import RedlampEngineAPI

/// How a Camera Raw setting carries over to a recipe.
enum LightroomRule: Sendable {
    /// Redlamp's control on Lightroom's scale.
    case parameter(ParameterID)
    /// HSL Luminance, which Lightroom applies to colour photos only.
    case colorLuminance(ColorBand)
    /// The B&W mix, which Lightroom applies to black-and-white photos only.
    case grayMix(ColorBand)
    case treatment
    case whiteBalance
    /// Kelvin or tint, which Lightroom applies to raw photos.
    case kelvin(ParameterID)
    /// Lightroom's relative white balance (−100…100), which it applies to JPEGs and other
    /// rendered photos only.
    case incremental
    case pointCurve
    case channelCurve
    case vignetteStyle
    case lensProfile
    case look
    /// A Lightroom feature Redlamp doesn't have, reported only when it, or the setting that
    /// switches it, is on.
    case unlessOff(String, switchedBy: String? = nil)
    case ignored(String)
    /// The preset's own description or Lightroom's bookkeeping rather than a setting.
    case metadata

    var isMetadata: Bool {
        if case .metadata = self {
            return true
        }
        return false
    }
}

extension LightroomPreset {
    /// How each Camera Raw setting carries over, in Lightroom's panel order, which the report
    /// follows. A key ending in `*` covers the keys that start with it and no earlier entry names.
    static let rules: [(key: String, rule: LightroomRule)] = metadataRules + basicRules + curveRules + mixerRules
        + gradingRules + detailRules + lensRules + transformRules + effectsRules + calibrationRules + cropRules
        + localRules

    private static let metadataRules: [(key: String, rule: LightroomRule)] = [
        "Name", "ShortName", "SortName", "Group", "Description", "UUID", "Cluster", "PresetType", "Copyright",
        "ContactInfo", "Version", "CompatibleVersion", "ProcessVersion", "HasSettings", "AlreadyApplied",
        "RawFileName", "Converter", "SupportsAmount", "SupportsColor", "SupportsMonochrome", "SupportsHighDynamicRange",
        "SupportsNormalDynamicRange", "SupportsSceneReferred", "SupportsOutputReferred", "JPEGHandling",
        "TIFFHandling", "What", "DNGIgnoreSidecars", "NegativeCache*", "ClipboardAspectRatio", "ClipboardOrientation",
        "ToggleStyleAmount", "ToggleStyleDigest", "DefaultAutoTone", "DefaultAutoGray", "DefaultsSpecificToISO",
        "DefaultsSpecificToSerial", "AutoToneDigest", "AutoToneDigestNoSat", "AutoWhiteVersion", "CameraProfileDigest",
        "ToneCurveName2012", "GrainSeed", "LensProfileDigest", "LensProfileFilename", "LensProfileIsEmbedded",
        "LensProfileMatchKey*", "UprightDependentDigest", "UprightGuidedDependentDigest", "UprightPreview",
        "UprightTransformCount", "UprightTransform_*", "UprightFourSegmentsCount", "UprightFourSegments_*",
    ].map { ($0, .metadata) }

    private static let basicRules: [(key: String, rule: LightroomRule)] = [
        ("CameraModelRestriction", .ignored(Note.camera)),
        ("ConvertToGrayscale", .treatment),
        ("CameraProfile", .ignored(Note.profile)),
        ("Look", .look),
        ("WhiteBalance", .whiteBalance),
        ("Temperature", .kelvin(.temperature)),
        ("Tint", .kelvin(.tint)),
        ("IncrementalTemperature", .incremental),
        ("IncrementalTint", .incremental),
        ("AutoTone", .unlessOff(Note.auto)),
        ("Exposure2012", .parameter(.exposure)),
        ("Contrast2012", .parameter(.contrast)),
        ("Highlights2012", .parameter(.highlights)),
        ("Shadows2012", .parameter(.shadows)),
        ("Whites2012", .parameter(.whites)),
        ("Blacks2012", .parameter(.blacks)),
        ("Texture", .parameter(.texture)),
        ("Clarity2012", .parameter(.clarity)),
        ("Dehaze", .parameter(.dehaze)),
        ("Vibrance", .parameter(.vibrance)),
        ("Saturation", .parameter(.saturation)),
        ("Exposure", .ignored(Note.replaced("Exposure", by: "Exposure2012"))),
        ("HighlightRecovery", .ignored(Note.replaced("Recovery", by: "Highlights2012"))),
        ("FillLight", .ignored(Note.replaced("Fill Light", by: "Shadows2012"))),
        ("Shadows", .ignored(Note.replaced("Blacks", by: "Blacks2012"))),
        ("Brightness", .ignored("Process 2010's Brightness, which Process 2012 doesn't have.")),
        ("Contrast", .ignored(Note.replaced("Contrast", by: "Contrast2012"))),
        ("Clarity", .ignored(Note.replaced("Clarity", by: "Clarity2012"))),
        ("AutoExposure", .unlessOff(Note.auto)),
        ("AutoContrast", .unlessOff(Note.auto)),
        ("AutoBrightness", .unlessOff(Note.auto)),
        ("AutoShadows", .unlessOff(Note.auto)),
    ]

    private static let curveRules: [(key: String, rule: LightroomRule)] = [
        ("ToneCurvePV2012", .pointCurve),
        ("ToneCurvePV2012Red", .channelCurve),
        ("ToneCurvePV2012Green", .channelCurve),
        ("ToneCurvePV2012Blue", .channelCurve),
        ("ParametricShadows", .parameter(.curveShadows)),
        ("ParametricDarks", .parameter(.curveDarks)),
        ("ParametricLights", .parameter(.curveLights)),
        ("ParametricHighlights", .parameter(.curveHighlights)),
        ("ParametricShadowSplit", .parameter(.curveSplitShadows)),
        ("ParametricMidtoneSplit", .parameter(.curveSplitMidtones)),
        ("ParametricHighlightSplit", .parameter(.curveSplitHighlights)),
    ] + ["ToneCurve", "ToneCurveName", "ToneCurveRed", "ToneCurveGreen", "ToneCurveBlue"].map {
        ($0, .ignored(Note.replaced("point curve", by: "ToneCurvePV2012")))
    }

    private static let mixerRules: [(key: String, rule: LightroomRule)] =
        ColorBand.allCases.map { ("HueAdjustment\($0.name)", .parameter($0.hueParameter)) }
            + ColorBand.allCases.map { ("SaturationAdjustment\($0.name)", .parameter($0.saturationParameter)) }
            + ColorBand.allCases.map { ("LuminanceAdjustment\($0.name)", .colorLuminance($0)) }
            + ColorBand.allCases.map { ("GrayMixer\($0.name)", .grayMix($0)) }

    /// Color Grading kept Split Toning's keys for the shadows and highlights wheels and Balance.
    private static let gradingRules: [(key: String, rule: LightroomRule)] = [
        ("SplitToningShadowHue", .parameter(.gradeShadowsHue)),
        ("SplitToningShadowSaturation", .parameter(.gradeShadowsSaturation)),
        ("ColorGradeShadowLum", .parameter(.gradeShadowsLuminance)),
        ("ColorGradeMidtoneHue", .parameter(.gradeMidtonesHue)),
        ("ColorGradeMidtoneSat", .parameter(.gradeMidtonesSaturation)),
        ("ColorGradeMidtoneLum", .parameter(.gradeMidtonesLuminance)),
        ("SplitToningHighlightHue", .parameter(.gradeHighlightsHue)),
        ("SplitToningHighlightSaturation", .parameter(.gradeHighlightsSaturation)),
        ("ColorGradeHighlightLum", .parameter(.gradeHighlightsLuminance)),
        ("ColorGradeGlobalHue", .parameter(.gradeGlobalHue)),
        ("ColorGradeGlobalSat", .parameter(.gradeGlobalSaturation)),
        ("ColorGradeGlobalLum", .parameter(.gradeGlobalLuminance)),
        ("ColorGradeBlending", .parameter(.gradeBlending)),
        ("SplitToningBalance", .parameter(.gradeBalance)),
    ]

    private static let detailRules: [(key: String, rule: LightroomRule)] = [
        ("Sharpness", .parameter(.sharpenAmount)),
        ("SharpenRadius", .parameter(.sharpenRadius)),
        ("SharpenDetail", .parameter(.sharpenDetail)),
        ("SharpenEdgeMasking", .parameter(.sharpenMasking)),
        ("LuminanceSmoothing", .parameter(.noiseLuminance)),
        ("LuminanceNoiseReductionDetail", .parameter(.noiseLuminanceDetail)),
        ("LuminanceNoiseReductionContrast", .parameter(.noiseLuminanceContrast)),
        ("ColorNoiseReduction", .parameter(.noiseColor)),
        ("ColorNoiseReductionDetail", .parameter(.noiseColorDetail)),
        ("ColorNoiseReductionSmoothness", .parameter(.noiseColorSmoothness)),
    ]

    private static let lensRules: [(key: String, rule: LightroomRule)] = [("LensProfileEnable", .lensProfile)] + [
        "LensProfile*", "AutoLateralCA", "ChromaticAberrationR", "ChromaticAberrationB", "Defringe",
        "DefringePurpleAmount", "DefringePurpleHueLo", "DefringePurpleHueHi", "DefringeGreenAmount",
        "DefringeGreenHueLo", "DefringeGreenHueHi", "LensManualDistortionAmount", "VignetteAmount", "VignetteMidpoint",
    ].map { ($0, .ignored(Note.lens)) }

    private static let transformRules: [(key: String, rule: LightroomRule)] =
        ["PerspectiveUpright", "UprightVersion", "Upright*"].map { ($0, .ignored(Note.upright)) } + [
            "PerspectiveVertical", "PerspectiveHorizontal", "PerspectiveRotate", "PerspectiveScale",
            "PerspectiveAspect", "PerspectiveX", "PerspectiveY",
        ].map { ($0, .ignored(Note.transform)) }

    private static let effectsRules: [(key: String, rule: LightroomRule)] = [
        ("PostCropVignetteAmount", .parameter(.vignetteAmount)),
        ("PostCropVignetteMidpoint", .parameter(.vignetteMidpoint)),
        ("PostCropVignetteRoundness", .parameter(.vignetteRoundness)),
        ("PostCropVignetteFeather", .parameter(.vignetteFeather)),
        ("PostCropVignetteHighlightContrast", .parameter(.vignetteHighlights)),
        ("PostCropVignetteStyle", .vignetteStyle),
        ("GrainAmount", .parameter(.grainAmount)),
        ("GrainSize", .parameter(.grainSize)),
        ("GrainFrequency", .parameter(.grainRoughness)),
    ]

    private static let calibrationRules: [(key: String, rule: LightroomRule)] = [
        "ShadowTint", "RedHue", "RedSaturation", "GreenHue", "GreenSaturation", "BlueHue", "BlueSaturation",
    ].map { ($0, .ignored(Note.calibration)) }

    private static let cropRules: [(key: String, rule: LightroomRule)] = [
        "HasCrop", "CropTop", "CropLeft", "CropBottom", "CropRight", "CropAngle", "CropConstrainToWarp",
        "CropConstrainToUnitSquare",
    ].map { ($0, .ignored(Note.crop)) }
        + ["CropWidth", "CropHeight", "CropUnit", "CropUnits"].map { ($0, .ignored(Note.cropSize)) }

    private static let localRules: [(key: String, rule: LightroomRule)] = [
        "MaskGroupBasedCorrections", "GradientBasedCorrections", "CircularGradientBasedCorrections",
        "PaintBasedCorrections", "DepthBasedCorrections", "RangeMaskMapInfo", "DepthMapInfo",
    ].map { ($0, .ignored(Note.masks)) } + [
        ("RetouchAreas", .ignored(Note.spots)),
        ("RetouchInfo", .ignored(Note.spots)),
        ("RedEyeInfo", .ignored(Note.redEye)),
        ("LensBlur", .ignored(Note.lensBlur)),
        ("PointColors", .ignored(Note.pointColor)),
        ("HDREditMode", .unlessOff(Note.hdr)),
    ] + ["HDRMaxValue", "SDRBlend", "SDRBrightness", "SDRContrast", "SDRHighlights", "SDRShadows", "SDRWhites"].map {
        ($0, .unlessOff(Note.hdr, switchedBy: "HDREditMode"))
    }

    /// The preset's settings in report order, each with its rule: nil for one Redlamp doesn't know.
    static func orderedSettings(_ settings: CameraRawSettings) -> [(key: String, rule: LightroomRule?)] {
        var remaining = Set(settings.values.keys)
        var ordered: [(key: String, rule: LightroomRule?)] = []
        for (pattern, rule) in rules {
            let matches = pattern.hasSuffix("*")
                ? remaining.filter { $0.hasPrefix(pattern.dropLast()) }.sorted()
                : remaining.contains(pattern) ? [pattern] : []
            for key in matches {
                remaining.remove(key)
                ordered.append((key, rule))
            }
        }
        return ordered + remaining.sorted().map { ($0, nil) }
    }
}

extension LightroomPreset {
    /// The report's reasons and explanations.
    enum Note {
        static let unknown = "Redlamp doesn't read this setting."
        static let unreadable = "Its value can't be read."
        static let camera = "Redlamp's recipes apply to photos from every camera."
        static let profile = "Redlamp doesn't convert Lightroom's profiles, so the photo keeps its Base Look."
        static let auto = "Lightroom works Auto out for each photo, and a recipe holds fixed values."
        static let lens = "Redlamp keeps lens corrections with each photo, so recipes don't carry them."
        static let lensProfileOn = lens + " Redlamp applies a photo's own lens profile unless it's switched off."
        static let lensProfileOff = lens + " This preset switches the lens profile off; Redlamp applies it by default."
        static let upright = "Upright is worked out for each photo, and Redlamp keeps Transform with each photo, "
            + "so recipes don't carry it."
        static let transform = "Redlamp keeps Transform with each photo, so recipes don't carry it."
        static let calibration = "Redlamp keeps calibration with each photo, so recipes don't carry it."
        static let crop = "Redlamp keeps the crop with each photo, so recipes don't carry it."
        static let cropSize = "The size Camera Raw crops to; Redlamp sets the size when exporting."
        static let masks = "Redlamp keeps masks with each photo, so recipes don't carry them."
        static let spots = "Redlamp keeps Heal and Clone spots with each photo, so recipes don't carry them."
        static let redEye = "Red-eye corrections belong to each photo, so recipes don't carry them."
        static let lensBlur = "Redlamp has no Lens Blur yet."
        static let pointColor = "Redlamp has no Point Color yet."
        static let hdr = "Redlamp doesn't edit in HDR yet."
        static let kelvinUsed = "Redlamp has one white balance for raw and rendered photos, so the preset's Temperature "
            + "and Tint are used."
        static let incremental = "Lightroom's relative white balance for JPEGs and other rendered photos, carried as Red "
            + "and Blue Shift, one unit for one (±100 is ±0.3 EV on red or blue, not yet measured against Lightroom). "
            + "Redlamp applies the shift to raw photos too."
        static let incrementalCustom = "Custom white balance from IncrementalTemperature and IncrementalTint, carried "
            + "as Red and Blue Shift."
        static let customWithoutValues = "Custom white balance, but the preset has no temperature or tint to set."
        static let grayMix = "Redlamp has no separate B&W mix: its Color Mixer's Luminance brightens or darkens each "
            + "colour before the photo turns grey."
        static let grayMixInColor = "Lightroom applies the B&W mix only to black-and-white photos, and this preset "
            + "doesn't make one."
        static let luminanceInBlackAndWhite = "Lightroom doesn't apply HSL Luminance to a black-and-white photo; "
            + "Redlamp's Luminance sliders hold the B&W mix instead."
        static let channelCurve = "Redlamp's point curve is one curve for all three channels."
        static let straightChannelCurve = "A straight line, which Redlamp's single curve matches."
        static let pointCurveSize = "Redlamp's point curve holds up to 64 points."
        static let vignetteStyle = "Rendered as Highlight Priority, the only style Redlamp's vignette has."
        static let splitToningBlending = "Not in this Split Toning preset: Lightroom renders Split Toning with "
            + "Blending at 100."

        static func replaced(_ control: String, by key: String) -> String {
            "Process 2010's \(control), which Process 2012 replaced with \(key)."
        }

        static func setByMode(_ mode: WhiteBalanceMode) -> String {
            "The white balance, \(mode.name), sets it."
        }

        static func unknownWhiteBalance(_ name: String) -> String {
            "Lightroom's white balance “\(name)” isn't one Redlamp has."
        }

        static func clamped(_ text: String) -> String {
            "Clamped to \(text), the end of Redlamp's range."
        }

        static func look(_ name: String) -> String {
            "The profile “\(name)” isn't carried over: \(profile)"
        }
    }
}
