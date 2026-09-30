/// Redlamp's own base looks. Each is a set of rendering parameters applied on top of
/// the camera's calibration; imported DCPs and LUTs will sit alongside these.
public enum BuiltInProfile: String, CaseIterable, Sendable {
    case color = "redlamp.color"
    case neutral = "redlamp.neutral"
    case vivid = "redlamp.vivid"
    case landscape = "redlamp.landscape"
    case portrait = "redlamp.portrait"
    case monochrome = "redlamp.monochrome"

    public var name: String {
        switch self {
        case .color: "Redlamp Color"
        case .neutral: "Redlamp Neutral"
        case .vivid: "Redlamp Vivid"
        case .landscape: "Redlamp Landscape"
        case .portrait: "Redlamp Portrait"
        case .monochrome: "Redlamp Monochrome"
        }
    }

    public var reference: ProfileReference {
        ProfileReference(id: rawValue, name: name)
    }

    public init?(reference: ProfileReference) {
        self.init(rawValue: reference.id)
    }

    public var look: ProfileLook {
        switch self {
        case .color: ProfileLook(contrast: 1.0, saturation: 1.0, warmth: 0)
        case .neutral: ProfileLook(contrast: 0.72, saturation: 0.9, warmth: 0)
        case .vivid: ProfileLook(contrast: 1.15, saturation: 1.28, warmth: 0)
        case .landscape: ProfileLook(contrast: 1.08, saturation: 1.15, warmth: -0.02, greenBoost: 0.12)
        case .portrait: ProfileLook(contrast: 0.9, saturation: 0.94, warmth: 0.03, skinSoftening: 0.25)
        case .monochrome: ProfileLook(contrast: 1.05, saturation: 0, warmth: 0, isMonochrome: true)
        }
    }
}

/// The rendering parameters behind a built-in profile.
public struct ProfileLook: Sendable, Hashable {
    /// Multiplier on the base tone curve's contrast.
    public var contrast: Double
    /// Chroma multiplier.
    public var saturation: Double
    /// Shift along the blue–yellow axis, in OKLab units.
    public var warmth: Double
    /// Extra chroma for greens and aquas.
    public var greenBoost: Double
    /// Pulls chroma out of skin hues.
    public var skinSoftening: Double
    public var isMonochrome: Bool

    public init(
        contrast: Double,
        saturation: Double,
        warmth: Double,
        greenBoost: Double = 0,
        skinSoftening: Double = 0,
        isMonochrome: Bool = false,
    ) {
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
        self.greenBoost = greenBoost
        self.skinSoftening = skinSoftening
        self.isMonochrome = isMonochrome
    }
}
