/// Every scalar editing parameter Redlamp knows about.
///
/// The raw value is the stable key used in sidecar files, so it must never change once
/// shipped. Names and ordering follow Lightroom's Develop module.
public enum ParameterID: String, CaseIterable, Codable, Sendable, Hashable {
    // White balance
    case temperature = "wb.temperature"
    case tint = "wb.tint"

    // Basic: tone
    case exposure = "basic.exposure"
    case contrast = "basic.contrast"
    case highlights = "basic.highlights"
    case shadows = "basic.shadows"
    case whites = "basic.whites"
    case blacks = "basic.blacks"

    // Basic: presence
    case texture = "basic.texture"
    case clarity = "basic.clarity"
    case dehaze = "basic.dehaze"
    case vibrance = "basic.vibrance"
    case saturation = "basic.saturation"

    // Tone curve (parametric)
    case curveHighlights = "toneCurve.highlights"
    case curveLights = "toneCurve.lights"
    case curveDarks = "toneCurve.darks"
    case curveShadows = "toneCurve.shadows"
    case curveSplitShadows = "toneCurve.split.shadows"
    case curveSplitMidtones = "toneCurve.split.midtones"
    case curveSplitHighlights = "toneCurve.split.highlights"

    // Color mixer: hue
    case hueRed = "mixer.hue.red"
    case hueOrange = "mixer.hue.orange"
    case hueYellow = "mixer.hue.yellow"
    case hueGreen = "mixer.hue.green"
    case hueAqua = "mixer.hue.aqua"
    case hueBlue = "mixer.hue.blue"
    case huePurple = "mixer.hue.purple"
    case hueMagenta = "mixer.hue.magenta"

    // Color mixer: saturation
    case saturationRed = "mixer.saturation.red"
    case saturationOrange = "mixer.saturation.orange"
    case saturationYellow = "mixer.saturation.yellow"
    case saturationGreen = "mixer.saturation.green"
    case saturationAqua = "mixer.saturation.aqua"
    case saturationBlue = "mixer.saturation.blue"
    case saturationPurple = "mixer.saturation.purple"
    case saturationMagenta = "mixer.saturation.magenta"

    // Color mixer: luminance
    case luminanceRed = "mixer.luminance.red"
    case luminanceOrange = "mixer.luminance.orange"
    case luminanceYellow = "mixer.luminance.yellow"
    case luminanceGreen = "mixer.luminance.green"
    case luminanceAqua = "mixer.luminance.aqua"
    case luminanceBlue = "mixer.luminance.blue"
    case luminancePurple = "mixer.luminance.purple"
    case luminanceMagenta = "mixer.luminance.magenta"

    // Color grading
    case gradeShadowsHue = "grading.shadows.hue"
    case gradeShadowsSaturation = "grading.shadows.saturation"
    case gradeShadowsLuminance = "grading.shadows.luminance"
    case gradeMidtonesHue = "grading.midtones.hue"
    case gradeMidtonesSaturation = "grading.midtones.saturation"
    case gradeMidtonesLuminance = "grading.midtones.luminance"
    case gradeHighlightsHue = "grading.highlights.hue"
    case gradeHighlightsSaturation = "grading.highlights.saturation"
    case gradeHighlightsLuminance = "grading.highlights.luminance"
    case gradeGlobalHue = "grading.global.hue"
    case gradeGlobalSaturation = "grading.global.saturation"
    case gradeGlobalLuminance = "grading.global.luminance"
    case gradeBlending = "grading.blending"
    case gradeBalance = "grading.balance"

    // Detail
    case sharpenAmount = "detail.sharpen.amount"
    case sharpenRadius = "detail.sharpen.radius"
    case sharpenDetail = "detail.sharpen.detail"
    case sharpenMasking = "detail.sharpen.masking"
    case noiseLuminance = "detail.noise.luminance"
    case noiseLuminanceDetail = "detail.noise.luminanceDetail"
    case noiseLuminanceContrast = "detail.noise.luminanceContrast"
    case noiseColor = "detail.noise.color"
    case noiseColorDetail = "detail.noise.colorDetail"
    case noiseColorSmoothness = "detail.noise.colorSmoothness"

    // Lens corrections
    case lensDistortion = "lens.distortion"
    case lensVignetting = "lens.vignetting"
    case lensVignettingMidpoint = "lens.vignettingMidpoint"

    // Transform
    case transformVertical = "transform.vertical"
    case transformHorizontal = "transform.horizontal"
    case transformRotate = "transform.rotate"
    case transformAspect = "transform.aspect"
    case transformScale = "transform.scale"
    case transformOffsetX = "transform.offsetX"
    case transformOffsetY = "transform.offsetY"

    // Effects
    case vignetteAmount = "effects.vignette.amount"
    case vignetteMidpoint = "effects.vignette.midpoint"
    case vignetteRoundness = "effects.vignette.roundness"
    case vignetteFeather = "effects.vignette.feather"
    case vignetteHighlights = "effects.vignette.highlights"
    case grainAmount = "effects.grain.amount"
    case grainSize = "effects.grain.size"
    case grainRoughness = "effects.grain.roughness"

    // Calibration
    case calibrationShadowsTint = "calibration.shadowsTint"
    case calibrationRedHue = "calibration.red.hue"
    case calibrationRedSaturation = "calibration.red.saturation"
    case calibrationGreenHue = "calibration.green.hue"
    case calibrationGreenSaturation = "calibration.green.saturation"
    case calibrationBlueHue = "calibration.blue.hue"
    case calibrationBlueSaturation = "calibration.blue.saturation"

    // Local adjustments (per mask). Stored on `MaskLayer`, never in the global recipe.
    case localTemperature = "local.temperature"
    case localTint = "local.tint"
    case localExposure = "local.exposure"
    case localContrast = "local.contrast"
    case localHighlights = "local.highlights"
    case localShadows = "local.shadows"
    case localWhites = "local.whites"
    case localBlacks = "local.blacks"
    case localTexture = "local.texture"
    case localClarity = "local.clarity"
    case localDehaze = "local.dehaze"
    case localHue = "local.hue"
    case localSaturation = "local.saturation"
    case localSharpness = "local.sharpness"
    case localNoise = "local.noise"
    case localMoire = "local.moire"
    case localDefringe = "local.defringe"

    /// The local adjustments, in Lightroom's masking-panel order.
    public static let localParameters: [ParameterID] = [
        .localTemperature, .localTint, .localExposure, .localContrast, .localHighlights, .localShadows,
        .localWhites, .localBlacks, .localTexture, .localClarity, .localDehaze, .localHue, .localSaturation,
        .localSharpness, .localNoise, .localMoire, .localDefringe,
    ]

    // Mask properties shown as sliders (stored on the mask or component, not as adjustments).
    case maskAmount = "mask.amount"
    case maskFeather = "mask.feather"

    /// A per-mask adjustment, stored in `MaskLayer.adjustments`.
    public var isLocal: Bool {
        rawValue.hasPrefix("local.")
    }

    /// Anything edited per mask; never stored in the global recipe.
    public var isMaskScoped: Bool {
        isLocal || rawValue.hasPrefix("mask.")
    }
}

/// The eight hue bands of the color mixer, in Lightroom's order.
public enum ColorBand: Int, CaseIterable, Codable, Sendable, Hashable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    public var name: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .aqua: "Aqua"
        case .blue: "Blue"
        case .purple: "Purple"
        case .magenta: "Magenta"
        }
    }

    /// Band centre as an OKLCh hue angle in degrees. The engine and the UI's gradient
    /// tracks both read this, so a slider's colors always match what it edits.
    public var hueDegrees: Double {
        switch self {
        case .red: 25
        case .orange: 55
        case .yellow: 100
        case .green: 140
        case .aqua: 195
        case .blue: 255
        case .purple: 300
        case .magenta: 340
        }
    }

    public var hueParameter: ParameterID {
        [.hueRed, .hueOrange, .hueYellow, .hueGreen, .hueAqua, .hueBlue, .huePurple, .hueMagenta][rawValue]
    }

    public var saturationParameter: ParameterID {
        [
            .saturationRed, .saturationOrange, .saturationYellow, .saturationGreen,
            .saturationAqua, .saturationBlue, .saturationPurple, .saturationMagenta,
        ][rawValue]
    }

    public var luminanceParameter: ParameterID {
        [
            .luminanceRed, .luminanceOrange, .luminanceYellow, .luminanceGreen,
            .luminanceAqua, .luminanceBlue, .luminancePurple, .luminanceMagenta,
        ][rawValue]
    }
}

/// The four color-grading wheels.
public enum GradingRange: String, CaseIterable, Codable, Sendable, Hashable {
    case shadows, midtones, highlights, global

    public var name: String {
        rawValue.capitalized
    }

    public var hueParameter: ParameterID {
        switch self {
        case .shadows: .gradeShadowsHue
        case .midtones: .gradeMidtonesHue
        case .highlights: .gradeHighlightsHue
        case .global: .gradeGlobalHue
        }
    }

    public var saturationParameter: ParameterID {
        switch self {
        case .shadows: .gradeShadowsSaturation
        case .midtones: .gradeMidtonesSaturation
        case .highlights: .gradeHighlightsSaturation
        case .global: .gradeGlobalSaturation
        }
    }

    public var luminanceParameter: ParameterID {
        switch self {
        case .shadows: .gradeShadowsLuminance
        case .midtones: .gradeMidtonesLuminance
        case .highlights: .gradeHighlightsLuminance
        case .global: .gradeGlobalLuminance
        }
    }
}
