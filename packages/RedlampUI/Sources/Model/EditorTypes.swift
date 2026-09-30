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

    /// Camera-style controls that Fujifilm-style recipe cards map onto, in the Effects panel.
    public static let cameraRecipeParameters: [ParameterID] = [
        .dynamicRange, .colorChrome, .colorChromeBlue, .wbShiftRed, .wbShiftBlue,
    ]

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
            ] + PanelID.cameraRecipeParameters
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

/// How Before / After (`\`) shows the original against the edit. It sticks between uses;
/// `Y` and `⇧Y` cycle through the layouts.
public enum CompareLayout: String, CaseIterable, Identifiable, Sendable {
    /// The original replaces the edit on the whole canvas.
    case toggle
    case sideBySide
    /// One canvas, cut diagonally: the original top-left, the edit bottom-right.
    case split

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .toggle: "Full Frame"
        case .sideBySide: "Side by Side"
        case .split: "Diagonal Split"
        }
    }

    public var symbol: String {
        switch self {
        case .toggle: "rectangle.2.swap"
        case .sideBySide: "rectangle.split.2x1"
        case .split: "square.split.diagonal"
        }
    }

    public func cycled(by offset: Int) -> CompareLayout {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[((index + offset) % all.count + all.count) % all.count]
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

/// A mask's structure without its adjustments or geometry: name, visibility and components.
/// Shapes live in `EditorModel.maskShapes`, so dragging a shape doesn't rebuild mask lists.
public struct MaskOutline: Hashable, Identifiable, Sendable {
    public struct Component: Hashable, Identifiable, Sendable {
        public let id: UUID
        public let kind: MaskKind
        public let operation: MaskOperation
        public let inverted: Bool
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
            Component(id: $0.id, kind: $0.shape.kind, operation: $0.operation, inverted: $0.inverted)
        }
    }
}
