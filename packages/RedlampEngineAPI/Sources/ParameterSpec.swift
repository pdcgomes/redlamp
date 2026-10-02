import Foundation

/// How a parameter's value is displayed.
public enum ValueFormat: Sendable, Hashable {
    /// `+25`, `0`, `-40`
    case signedInteger
    /// `25`
    case integer
    /// `+0.50` with the given number of fraction digits.
    case signedDecimal(Int)
    /// `1.0` with the given number of fraction digits.
    case decimal(Int)
    /// `5500`
    case kelvin
}

/// The visual style of a slider track. The UI renders these; the colors live here so
/// the engine and the UI agree on what a band looks like.
public enum TrackStyle: Sendable, Hashable {
    case plain
    case temperature
    case tint
    case hue(ColorBand)
    case saturation(ColorBand)
    case luminance(ColorBand)
    case gradingHue
    case monochrome
}

/// How slider position maps to value.
public enum SliderScale: Sendable, Hashable {
    case linear
    /// Linear in mireds (1e6 / kelvin), which is how color temperature is perceived.
    case mired
}

/// Whether the engine renders a parameter yet.
public enum Availability: Sendable, Hashable {
    case live
    /// Present in the UI for layout fidelity, rendered in a later phase.
    case planned(phase: String)

    public var isLive: Bool {
        if case .live = self {
            return true
        }
        return false
    }
}

public struct ParameterSpec: Sendable, Hashable, Identifiable {
    public let id: ParameterID
    public let label: String
    public let range: ClosedRange<Double>
    public let defaultValue: Double
    /// Keyboard step (arrow keys); Shift multiplies it by ten.
    public let step: Double
    public let format: ValueFormat
    public let track: TrackStyle
    public let scale: SliderScale
    public let availability: Availability

    public init(
        _ id: ParameterID,
        _ label: String,
        range: ClosedRange<Double> = -100 ... 100,
        default defaultValue: Double = 0,
        step: Double = 1,
        format: ValueFormat = .signedInteger,
        track: TrackStyle = .plain,
        scale: SliderScale = .linear,
        availability: Availability = .live,
    ) {
        self.id = id
        self.label = label
        self.range = range
        self.defaultValue = defaultValue
        self.step = step
        self.format = format
        self.track = track
        self.scale = scale
        self.availability = availability
    }

    /// Whether the slider is centred on zero, which draws a centre tick.
    public var isBipolar: Bool {
        range.lowerBound < 0 && range.upperBound > 0
    }

    public func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Normalised slider position in 0...1 for a value.
    public func position(for value: Double) -> Double {
        switch scale {
        case .linear:
            return (clamp(value) - range.lowerBound) / (range.upperBound - range.lowerBound)
        case .mired:
            let lo = 1e6 / range.upperBound
            let hi = 1e6 / range.lowerBound
            let mired = 1e6 / clamp(value)
            return 1 - (mired - lo) / (hi - lo)
        }
    }

    /// The value at a normalised slider position in 0...1.
    public func value(atPosition position: Double) -> Double {
        let t = min(max(position, 0), 1)
        switch scale {
        case .linear:
            return range.lowerBound + t * (range.upperBound - range.lowerBound)
        case .mired:
            let lo = 1e6 / range.upperBound
            let hi = 1e6 / range.lowerBound
            return 1e6 / (hi - t * (hi - lo))
        }
    }

    /// Snaps a value to the parameter's display precision.
    public func quantize(_ value: Double) -> Double {
        let clamped = clamp(value)
        switch format {
        case .signedInteger, .integer: return clamped.rounded()
        case .kelvin: return (clamped / 50).rounded() * 50
        case let .signedDecimal(digits), let .decimal(digits):
            let scale = pow(10, Double(digits))
            return (clamped * scale).rounded() / scale
        }
    }

    public func formatted(_ value: Double) -> String {
        switch format {
        case .signedInteger:
            let rounded = Int(value.rounded())
            return rounded > 0 ? "+\(rounded)" : "\(rounded)"
        case .integer:
            return "\(Int(value.rounded()))"
        case let .signedDecimal(digits):
            let text = String(format: "%.\(digits)f", value)
            return value > 0.5 / pow(10, Double(digits)) ? "+\(text)" : text
        case let .decimal(digits):
            return String(format: "%.\(digits)f", value)
        case .kelvin:
            return "\(Int((value / 50).rounded() * 50))"
        }
    }

    /// Parses user-typed text back into a value: a number or arithmetic (`+ - * /`, parentheses),
    /// where `x` is `current`, so "x+10" or "x/2" adjust what's there. A trailing unit (K, %, EV)
    /// is ignored.
    public func parse(_ text: String, current: Double? = nil) -> Double? {
        var expression = text.lowercased().filter { !$0.isWhitespace }
        for unit in ["ev", "k", "%", "°"] where expression.hasSuffix(unit) {
            expression.removeLast(unit.count)
        }
        var parser = ExpressionParser(characters: Array(expression), variable: current)
        guard let value = parser.parse(), value.isFinite else { return nil }
        return clamp(value)
    }
}

/// A small recursive-descent parser for value fields.
private struct ExpressionParser {
    let characters: [Character]
    let variable: Double?
    var index = 0

    mutating func parse() -> Double? {
        guard let value = sum(), index == characters.count else { return nil }
        return value
    }

    private var next: Character? {
        index < characters.count ? characters[index] : nil
    }

    private mutating func sum() -> Double? {
        guard var value = product() else { return nil }
        while let op = next, op == "+" || op == "-" {
            index += 1
            guard let right = product() else { return nil }
            value = op == "+" ? value + right : value - right
        }
        return value
    }

    private mutating func product() -> Double? {
        guard var value = unary() else { return nil }
        while let op = next, op == "*" || op == "/" || op == "×" || op == "÷" {
            index += 1
            guard let right = unary() else { return nil }
            value = op == "*" || op == "×" ? value * right : value / right
        }
        return value
    }

    private mutating func unary() -> Double? {
        if let sign = next, sign == "+" || sign == "-" {
            index += 1
            return unary().map { sign == "-" ? -$0 : $0 }
        }
        return primary()
    }

    private mutating func primary() -> Double? {
        if next == "(" {
            index += 1
            guard let value = sum(), next == ")" else { return nil }
            index += 1
            return value
        }
        if next == "x" {
            index += 1
            return variable
        }
        let start = index
        while let c = next, c.isNumber || c == "." || c == "," {
            index += 1
        }
        return Double(String(characters[start ..< index]).replacingOccurrences(of: ",", with: "."))
    }
}

public extension ParameterID {
    var spec: ParameterSpec {
        ParameterCatalog.specs[self]!
    }
}

public enum ParameterCatalog {
    private static let detail = Availability.planned(phase: "Phase 2")
    private static let geometry = Availability.planned(phase: "Phase 2")

    public static let all: [ParameterSpec] = [
        ParameterSpec(
            .temperature, "Temp", range: 2000 ... 50000, default: 5500, step: 50,
            format: .kelvin, track: .temperature, scale: .mired,
        ),
        ParameterSpec(.tint, "Tint", range: -150 ... 150, track: .tint),
        ParameterSpec(.wbShiftRed, "Red Shift"),
        ParameterSpec(.wbShiftBlue, "Blue Shift"),

        ParameterSpec(
            .exposure, "Exposure", range: -5 ... 5, step: 0.05, format: .signedDecimal(2),
            track: .monochrome,
        ),
        ParameterSpec(.contrast, "Contrast"),
        ParameterSpec(.highlights, "Highlights"),
        ParameterSpec(.shadows, "Shadows"),
        ParameterSpec(.whites, "Whites"),
        ParameterSpec(.blacks, "Blacks"),
        ParameterSpec(
            .dynamicRange, "Dynamic Range", range: 100 ... 400, default: 100, step: 100, format: .integer,
        ),

        ParameterSpec(.texture, "Texture"),
        ParameterSpec(.clarity, "Clarity"),
        ParameterSpec(.dehaze, "Dehaze"),
        ParameterSpec(.vibrance, "Vibrance"),
        ParameterSpec(.saturation, "Saturation"),

        ParameterSpec(.curveHighlights, "Highlights"),
        ParameterSpec(.curveLights, "Lights"),
        ParameterSpec(.curveDarks, "Darks"),
        ParameterSpec(.curveShadows, "Shadows"),
        ParameterSpec(.curveSplitShadows, "Shadows split", range: 10 ... 40, default: 25, format: .integer),
        ParameterSpec(.curveSplitMidtones, "Midtones split", range: 30 ... 70, default: 50, format: .integer),
        ParameterSpec(.curveSplitHighlights, "Highlights split", range: 60 ... 90, default: 75, format: .integer),
    ]
        + ColorBand.allCases.flatMap { band in
            [
                ParameterSpec(band.hueParameter, band.name, track: .hue(band)),
                ParameterSpec(band.saturationParameter, band.name, track: .saturation(band)),
                ParameterSpec(band.luminanceParameter, band.name, track: .luminance(band)),
            ]
        }

        + GradingRange.allCases.flatMap { range in
            [
                ParameterSpec(
                    range.hueParameter, "Hue", range: 0 ... 360, format: .integer, track: .gradingHue,
                ),
                ParameterSpec(range.saturationParameter, "Saturation", range: 0 ... 100, format: .integer),
                ParameterSpec(range.luminanceParameter, "Luminance", track: .monochrome),
            ]
        }

        + [
            ParameterSpec(.gradeBlending, "Blending", range: 0 ... 100, default: 50, format: .integer),
            ParameterSpec(.gradeBalance, "Balance"),

            ParameterSpec(
                .sharpenAmount, "Amount", range: 0 ... 150, default: 40, format: .integer,
            ),
            ParameterSpec(
                .sharpenRadius, "Radius", range: 0.5 ... 3, default: 1, step: 0.1, format: .decimal(1),
            ),
            ParameterSpec(
                .sharpenDetail, "Detail", range: 0 ... 100, default: 25, format: .integer,
            ),
            ParameterSpec(.sharpenMasking, "Masking", range: 0 ... 100, format: .integer),
            ParameterSpec(.noiseLuminance, "Luminance", range: 0 ... 100, format: .integer),
            ParameterSpec(
                .noiseLuminanceDetail, "Detail", range: 0 ... 100, default: 50, format: .integer,
            ),
            ParameterSpec(
                .noiseLuminanceContrast, "Contrast", range: 0 ... 100, format: .integer,
            ),
            ParameterSpec(
                .noiseColor, "Color", range: 0 ... 100, default: 25, format: .integer,
            ),
            ParameterSpec(
                .noiseColorDetail, "Detail", range: 0 ... 100, default: 50, format: .integer,
            ),
            ParameterSpec(
                .noiseColorSmoothness, "Smoothness", range: 0 ... 100, default: 50, format: .integer,
            ),

            ParameterSpec(.lensDistortion, "Distortion"),
            ParameterSpec(.lensVignetting, "Vignetting"),
            ParameterSpec(.lensVignettingMidpoint, "Midpoint", range: 0 ... 100, default: 50, format: .integer),
            ParameterSpec(.lensProfile, "Enable Profile Corrections", range: 0 ... 1, default: 1, format: .integer),
            ParameterSpec(.lensProfileDistortion, "Distortion", range: 0 ... 200, default: 100, format: .integer),
            ParameterSpec(.lensProfileVignetting, "Vignetting", range: 0 ... 200, default: 100, format: .integer),
            ParameterSpec(
                .lensRemoveChromaticAberration,
                "Remove Chromatic Aberration",
                range: 0 ... 1,
                format: .integer,
            ),
            ParameterSpec(.defringePurpleAmount, "Purple Amount", range: 0 ... 20, format: .integer),
            ParameterSpec(.defringePurpleHueLow, "Purple Hue Low", range: 0 ... 100, default: 30, format: .integer),
            ParameterSpec(.defringePurpleHueHigh, "Purple Hue High", range: 0 ... 100, default: 70, format: .integer),
            ParameterSpec(.defringeGreenAmount, "Green Amount", range: 0 ... 20, format: .integer),
            ParameterSpec(.defringeGreenHueLow, "Green Hue Low", range: 0 ... 100, default: 40, format: .integer),
            ParameterSpec(.defringeGreenHueHigh, "Green Hue High", range: 0 ... 100, default: 60, format: .integer),

            ParameterSpec(
                .cropAngle, "Angle", range: -45 ... 45, step: 0.01, format: .signedDecimal(2),
            ),

            ParameterSpec(.transformVertical, "Vertical"),
            ParameterSpec(.transformHorizontal, "Horizontal"),
            ParameterSpec(
                .transformRotate, "Rotate", range: -10 ... 10, step: 0.1, format: .signedDecimal(1),
            ),
            ParameterSpec(.transformAspect, "Aspect"),
            ParameterSpec(
                .transformScale, "Scale", range: 50 ... 150, default: 100, format: .integer,
            ),
            ParameterSpec(
                .transformOffsetX, "X Offset", range: -100 ... 100, step: 0.1, format: .signedDecimal(1),
            ),
            ParameterSpec(
                .transformOffsetY, "Y Offset", range: -100 ... 100, step: 0.1, format: .signedDecimal(1),
            ),

            ParameterSpec(.vignetteAmount, "Amount", track: .monochrome),
            ParameterSpec(.vignetteMidpoint, "Midpoint", range: 0 ... 100, default: 50, format: .integer),
            ParameterSpec(.vignetteRoundness, "Roundness"),
            ParameterSpec(.vignetteFeather, "Feather", range: 0 ... 100, default: 50, format: .integer),
            ParameterSpec(
                .vignetteHighlights, "Highlights", range: 0 ... 100, format: .integer,
                availability: .planned(phase: "Phase 2"),
            ),
            ParameterSpec(.grainAmount, "Amount", range: 0 ... 100, format: .integer),
            ParameterSpec(.grainSize, "Size", range: 0 ... 100, default: 25, format: .integer),
            ParameterSpec(.grainRoughness, "Roughness", range: 0 ... 100, default: 50, format: .integer),
            ParameterSpec(.grainColor, "Color", range: 0 ... 100, format: .integer),
            ParameterSpec(.halationAmount, "Amount", range: 0 ... 100, format: .integer),
            ParameterSpec(.halationSize, "Size", range: 0 ... 100, default: 50, format: .integer),
            ParameterSpec(.bloomAmount, "Amount", range: 0 ... 100, format: .integer),
            ParameterSpec(.bloomSize, "Size", range: 0 ... 100, default: 50, format: .integer),
            ParameterSpec(.leakAmount, "Amount", range: 0 ... 100, format: .integer),
            ParameterSpec(
                .leakWarmth,
                "Warmth",
                range: -100 ... 100,
                default: 60,
                format: .integer,
                track: .temperature,
            ),
            ParameterSpec(.leakVariation, "Variation", range: 0 ... 100, format: .integer),
            ParameterSpec(.dustAmount, "Dust", range: 0 ... 100, format: .integer),
            ParameterSpec(.scratchAmount, "Scratches", range: 0 ... 100, format: .integer),
            ParameterSpec(.frameStyle, "Style", range: 0 ... 4, format: .integer),
            ParameterSpec(.frameSize, "Size", range: 0 ... 100, default: 50, format: .integer),
            ParameterSpec(.colorChrome, "Color Chrome", range: 0 ... 100, format: .integer),
            ParameterSpec(.colorChromeBlue, "Chrome FX Blue", range: 0 ... 100, format: .integer),

            ParameterSpec(.calibrationShadowsTint, "Tint", track: .tint, availability: .planned(phase: "Phase 2")),
            ParameterSpec(.calibrationRedHue, "Hue", availability: .planned(phase: "Phase 2")),
            ParameterSpec(.calibrationRedSaturation, "Saturation", availability: .planned(phase: "Phase 2")),
            ParameterSpec(.calibrationGreenHue, "Hue", availability: .planned(phase: "Phase 2")),
            ParameterSpec(.calibrationGreenSaturation, "Saturation", availability: .planned(phase: "Phase 2")),
            ParameterSpec(.calibrationBlueHue, "Hue", availability: .planned(phase: "Phase 2")),
            ParameterSpec(.calibrationBlueSaturation, "Saturation", availability: .planned(phase: "Phase 2")),

            ParameterSpec(.localTemperature, "Temp", track: .temperature),
            ParameterSpec(.localTint, "Tint", track: .tint),
            ParameterSpec(
                .localExposure, "Exposure", range: -4 ... 4, step: 0.05, format: .signedDecimal(2),
                track: .monochrome,
            ),
            ParameterSpec(.localContrast, "Contrast"),
            ParameterSpec(.localHighlights, "Highlights"),
            ParameterSpec(.localShadows, "Shadows"),
            ParameterSpec(.localWhites, "Whites"),
            ParameterSpec(.localBlacks, "Blacks"),
            ParameterSpec(.localTexture, "Texture"),
            ParameterSpec(.localClarity, "Clarity"),
            ParameterSpec(.localDehaze, "Dehaze"),
            ParameterSpec(
                .localHue,
                "Hue",
                range: -180 ... 180,
                step: 0.5,
                format: .signedDecimal(1),
                track: .gradingHue,
            ),
            ParameterSpec(.localSaturation, "Saturation"),
            ParameterSpec(.localSharpness, "Sharpness"),
            ParameterSpec(.localNoise, "Noise"),
            ParameterSpec(.localMoire, "Moiré", availability: detail),
            ParameterSpec(.localDefringe, "Defringe", range: -100 ... 100, availability: geometry),
            ParameterSpec(.localHalation, "Halation"),
            ParameterSpec(.localBloom, "Bloom"),
            ParameterSpec(.maskAmount, "Amount", range: 0 ... 200, default: 100, format: .integer),
            ParameterSpec(.maskFeather, "Feather", range: 0 ... 100, default: 50, format: .integer),
            ParameterSpec(.maskBrushSize, "Size", range: 1 ... 100, default: 25, format: .integer),
            ParameterSpec(.maskBrushFeather, "Feather", range: 0 ... 100, default: 50, format: .integer),
            ParameterSpec(.maskBrushFlow, "Flow", range: 1 ... 100, default: 100, format: .integer),
            ParameterSpec(.maskBrushDensity, "Density", range: 1 ... 100, default: 100, format: .integer),
            ParameterSpec(.maskDetail, "Detail", range: -100 ... 100),
            ParameterSpec(.maskColorRefine, "Refine", range: 0 ... 100, default: 50, format: .integer),
        ]

    public static let specs: [ParameterID: ParameterSpec] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) },
    )
}
