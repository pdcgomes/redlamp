import Foundation
import RedlampDocument
import RedlampEngineAPI

public struct LibraryItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public var hasEdits: Bool
    public var metadata = PhotoMetadata()

    public var id: URL {
        url
    }

    public var name: String {
        url.lastPathComponent
    }
}

public struct HistoryStep: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let name: String
    public let recipe: EditRecipe
}

/// The Develop panels, in Lightroom's order.
public enum PanelID: String, CaseIterable, Identifiable, Sendable {
    case basic, toneCurve, colorMixer, colorGrading, detail, lens, transform, effects, calibration

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .basic: "Basic"
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

    public var parameters: [ParameterID] {
        switch self {
        case .basic:
            [
                .temperature,
                .tint,
                .exposure,
                .contrast,
                .highlights,
                .shadows,
                .whites,
                .blacks,
                .texture,
                .clarity,
                .dehaze,
                .vibrance,
                .saturation,
            ]
        case .toneCurve:
            [
                .curveHighlights,
                .curveLights,
                .curveDarks,
                .curveShadows,
                .curveSplitShadows,
                .curveSplitMidtones,
                .curveSplitHighlights,
            ]
        case .colorMixer:
            ColorBand.allCases.flatMap { [$0.hueParameter, $0.saturationParameter, $0.luminanceParameter] }
        case .colorGrading:
            GradingRange.allCases.flatMap { [$0.hueParameter, $0.saturationParameter, $0.luminanceParameter] }
                + [.gradeBlending, .gradeBalance]
        case .detail:
            [
                .sharpenAmount,
                .sharpenRadius,
                .sharpenDetail,
                .sharpenMasking,
                .noiseLuminance,
                .noiseLuminanceDetail,
                .noiseLuminanceContrast,
                .noiseColor,
                .noiseColorDetail,
                .noiseColorSmoothness,
            ]
        case .lens:
            [.lensDistortion, .lensVignetting, .lensVignettingMidpoint]
        case .transform:
            [
                .transformVertical,
                .transformHorizontal,
                .transformRotate,
                .transformAspect,
                .transformScale,
                .transformOffsetX,
                .transformOffsetY,
            ]
        case .effects:
            [
                .vignetteAmount,
                .vignetteMidpoint,
                .vignetteRoundness,
                .vignetteFeather,
                .vignetteHighlights,
                .grainAmount,
                .grainSize,
                .grainRoughness,
            ]
        case .calibration:
            [
                .calibrationShadowsTint,
                .calibrationRedHue,
                .calibrationRedSaturation,
                .calibrationGreenHue,
                .calibrationGreenSaturation,
                .calibrationBlueHue,
                .calibrationBlueSaturation,
            ]
        }
    }
}

/// The tool strip under the histogram.
public enum EditTool: String, CaseIterable, Identifiable, Sendable {
    case edit, crop, heal, redEye, masking

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .edit: "Edit"
        case .crop: "Crop & Straighten"
        case .heal: "Healing"
        case .redEye: "Red Eye Correction"
        case .masking: "Masking"
        }
    }

    public var symbol: String {
        switch self {
        case .edit: "slider.horizontal.3"
        case .crop: "crop"
        case .heal: "bandage"
        case .redEye: "eye"
        case .masking: "circle.dashed.inset.filled"
        }
    }

    public var shortcut: String {
        switch self {
        case .edit: "D"
        case .crop: "R"
        case .heal: "Q"
        case .redEye: ""
        case .masking: "⇧W"
        }
    }

    /// Where the tool lands on the roadmap; `nil` once it is live.
    public var plannedPhase: String? {
        switch self {
        case .edit, .masking: nil
        case .crop: "Phase 2"
        case .heal, .redEye: "Phase 3"
        }
    }

    public var summary: String {
        switch self {
        case .edit: ""
        case .crop: "Crop with aspect presets and overlays, straighten with the level tool, rotate and flip."
        case .heal: "Content-aware Remove, Heal and Clone brushes with Visualize Spots."
        case .redEye: "Red Eye and Pet Eye correction."
        case .masking: "Linear and radial gradients, brush, color and luminance range, and AI subject, sky, background and people masks."
        }
    }
}

/// A mask without its adjustments: name, visibility and components (with their shapes,
/// for the canvas guides).
public struct MaskOutline: Hashable, Identifiable, Sendable {
    public struct Component: Hashable, Identifiable, Sendable {
        public let id: UUID
        public let shape: MaskShape
        public let operation: MaskOperation
        public let inverted: Bool

        public var kind: MaskKind {
            shape.kind
        }
    }

    public let id: UUID
    public let name: String
    public let isVisible: Bool
    public let components: [Component]

    init(_ mask: MaskLayer) {
        id = mask.id
        name = mask.name
        isVisible = mask.isVisible
        components = mask.components.map {
            Component(id: $0.id, shape: $0.shape, operation: $0.operation, inverted: $0.inverted)
        }
    }
}
