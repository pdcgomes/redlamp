import Foundation

// Lightroom's Copy Settings checklist: which parts of an edit carry from one photo to another,
// when pasting, syncing a selection or auto-syncing (`docs/plans/2026-10-02-copy-paste-sync-design.md`).

/// The parts of an edit that aren't parameters.
public enum EditField: String, Sendable, Hashable, CaseIterable {
    case treatment
    /// The base look, with its Amount and the applied recipe's provenance.
    case baseLook
    case whiteBalanceMode
    case pointCurve
    case crop
    case orientation
    case processVersion
}

/// One line of the checklist.
public struct SettingsItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let parameters: [ParameterID]
    public let fields: Set<EditField>
    /// Ticked the first time the checklist opens: everything but a photo's own framing.
    public let selectedByDefault: Bool

    init(
        _ id: String, _ name: String, _ parameters: [ParameterID] = [], fields: Set<EditField> = [],
        selectedByDefault: Bool = true,
    ) {
        self.id = id
        self.name = name
        self.parameters = parameters
        self.fields = fields
        self.selectedByDefault = selectedByDefault
    }
}

/// A group of the checklist, as the Develop panels group their settings.
public struct SettingsGroup: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let items: [SettingsItem]

    /// The whole checklist but masks, which are the source's own (see `SettingsSelection`).
    public static let all: [SettingsGroup] = [
        SettingsGroup(id: "look", name: "Treatment and Base Look", items: [
            SettingsItem("look.treatment", "Treatment", fields: [.treatment]),
            SettingsItem("look.baseLook", "Base Look", fields: [.baseLook]),
        ]),
        SettingsGroup(id: "whiteBalance", name: "White Balance", items: [
            SettingsItem("whiteBalance", "White Balance", [.temperature, .tint], fields: [.whiteBalanceMode]),
        ]),
        SettingsGroup(id: "basic", name: "Basic Tone", items: [
            SettingsItem("basic.exposure", "Exposure", [.exposure]),
            SettingsItem("basic.contrast", "Contrast", [.contrast]),
            SettingsItem("basic.highlights", "Highlights", [.highlights]),
            SettingsItem("basic.shadows", "Shadows", [.shadows]),
            SettingsItem("basic.whites", "Whites", [.whites]),
            SettingsItem("basic.blacks", "Blacks", [.blacks]),
        ]),
        SettingsGroup(id: "presence", name: "Presence", items: [
            SettingsItem("presence.texture", "Texture", [.texture]),
            SettingsItem("presence.clarity", "Clarity", [.clarity]),
            SettingsItem("presence.dehaze", "Dehaze", [.dehaze]),
            SettingsItem("presence.vibrance", "Vibrance", [.vibrance]),
            SettingsItem("presence.saturation", "Saturation", [.saturation]),
        ]),
        SettingsGroup(id: "toneCurve", name: "Tone Curve", items: [
            SettingsItem("toneCurve.parametric", "Parametric Curve", [
                .curveHighlights, .curveLights, .curveDarks, .curveShadows, .curveSplitShadows,
                .curveSplitMidtones, .curveSplitHighlights,
            ]),
            SettingsItem("toneCurve.point", "Point Curve", fields: [.pointCurve]),
        ]),
        SettingsGroup(id: "colorMixer", name: "Color Mixer", items: [
            SettingsItem("colorMixer.hue", "Hue", ColorBand.allCases.map(\.hueParameter)),
            SettingsItem("colorMixer.saturation", "Saturation", ColorBand.allCases.map(\.saturationParameter)),
            SettingsItem("colorMixer.luminance", "Luminance", ColorBand.allCases.map(\.luminanceParameter)),
        ]),
        SettingsGroup(id: "colorGrading", name: "Color Grading", items: [
            SettingsItem(
                "colorGrading", "Color Grading",
                GradingRange.allCases.flatMap { [$0.hueParameter, $0.saturationParameter, $0.luminanceParameter] }
                    + [.gradeBlending, .gradeBalance],
            ),
        ]),
        SettingsGroup(id: "detail", name: "Detail", items: [
            SettingsItem(
                "detail.sharpening",
                "Sharpening",
                [.sharpenAmount, .sharpenRadius, .sharpenDetail, .sharpenMasking],
            ),
            SettingsItem("detail.noise", "Noise Reduction", [
                .noiseLuminance, .noiseLuminanceDetail, .noiseLuminanceContrast, .noiseColor, .noiseColorDetail,
                .noiseColorSmoothness,
            ]),
        ]),
        SettingsGroup(id: "lens", name: "Lens Corrections", items: [
            SettingsItem(
                "lens.profile",
                "Profile Corrections",
                [.lensProfile, .lensProfileDistortion, .lensProfileVignetting],
            ),
            SettingsItem("lens.chromaticAberration", "Remove Chromatic Aberration", [.lensRemoveChromaticAberration]),
            SettingsItem("lens.defringe", "Defringe", [
                .defringePurpleAmount, .defringePurpleHueLow, .defringePurpleHueHigh, .defringeGreenAmount,
                .defringeGreenHueLow, .defringeGreenHueHigh,
            ]),
            SettingsItem(
                "lens.manual", "Manual Distortion and Vignetting",
                [.lensDistortion, .lensVignetting, .lensVignettingMidpoint], selectedByDefault: false,
            ),
        ]),
        SettingsGroup(id: "transform", name: "Transform", items: [
            SettingsItem("transform", "Upright and Transform", [
                .transformVertical, .transformHorizontal, .transformRotate, .transformAspect, .transformScale,
                .transformOffsetX, .transformOffsetY,
            ], selectedByDefault: false),
        ]),
        SettingsGroup(id: "effects", name: "Effects", items: [
            SettingsItem("effects.vignette", "Vignette", [
                .vignetteAmount, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather, .vignetteHighlights,
            ]),
            SettingsItem("effects.grain", "Grain", [.grainAmount, .grainSize, .grainRoughness, .grainColor]),
            SettingsItem(
                "effects.glow",
                "Halation and Bloom",
                [.halationAmount, .halationSize, .bloomAmount, .bloomSize],
            ),
            SettingsItem("effects.leak", "Light Leak", [.leakAmount, .leakWarmth, .leakVariation]),
            SettingsItem("effects.dust", "Dust and Scratches", [.dustAmount, .scratchAmount]),
            SettingsItem("effects.frame", "Frame", [.frameStyle, .frameSize]),
            SettingsItem("effects.camera", "Camera Recipe Settings", [
                .dynamicRange, .colorChrome, .colorChromeBlue, .wbShiftRed, .wbShiftBlue,
            ]),
        ]),
        SettingsGroup(id: "calibration", name: "Calibration", items: [
            SettingsItem("calibration", "Calibration", [
                .calibrationShadowsTint, .calibrationRedHue, .calibrationRedSaturation, .calibrationGreenHue,
                .calibrationGreenSaturation, .calibrationBlueHue, .calibrationBlueSaturation,
            ]),
            SettingsItem("calibration.processVersion", "Process Version", fields: [.processVersion]),
        ]),
        SettingsGroup(id: "crop", name: "Crop", items: [
            SettingsItem("crop.frame", "Crop and Straighten", [.cropAngle], fields: [.crop], selectedByDefault: false),
            SettingsItem("crop.orientation", "Rotate and Flip", fields: [.orientation], selectedByDefault: false),
        ]),
    ]

    public static let allItems: [SettingsItem] = all.flatMap(\.items)
}

/// What the checklist ticks: items by id, and the source's masks (all of them unless left out).
public struct SettingsSelection: Codable, Sendable, Hashable {
    public var items: Set<String>
    /// Whether the source's masks are pasted.
    public var masks: Bool
    /// Masks of the source left out, when `masks` is on. Specific to one source: not remembered.
    public var excludedMasks: Set<UUID>

    public init(items: Set<String>, masks: Bool = true, excludedMasks: Set<UUID> = []) {
        self.items = items
        self.masks = masks
        self.excludedMasks = excludedMasks
    }

    /// The first time: everything but a photo's own framing, white balance included.
    public static let `default` = SettingsSelection(
        items: Set(SettingsGroup.allItems.filter(\.selectedByDefault).map(\.id)),
    )
    public static let everything = SettingsSelection(items: Set(SettingsGroup.allItems.map(\.id)))
    public static let nothing = SettingsSelection(items: [], masks: false)

    public func includes(_ item: SettingsItem) -> Bool {
        items.contains(item.id)
    }

    public func includes(mask id: UUID) -> Bool {
        masks && !excludedMasks.contains(id)
    }

    /// The choice to remember for next time: which masks were left out belongs to one source.
    public var remembered: SettingsSelection {
        SettingsSelection(items: items, masks: masks)
    }

    public var isEmpty: Bool {
        items.isEmpty && !masks
    }

    /// What changed from `old` to `new` (one history step, for Auto Sync): the items with a
    /// parameter or field that differs, and the masks added or changed. Masks taken away aren't:
    /// a paste only adds and replaces.
    public static func changes(from old: EditRecipe, to new: EditRecipe) -> SettingsSelection {
        let items = SettingsGroup.allItems.filter { item in
            item.parameters.contains { old[$0] != new[$0] } || item.fields.contains { !old.matches(new, in: $0) }
        }
        let changed = Set(new.masks.filter { old.mask($0.id) != $0 }.map(\.id))
        return SettingsSelection(
            items: Set(items.map(\.id)), masks: !changed.isEmpty,
            excludedMasks: changed.isEmpty ? [] : Set(new.masks.map(\.id)).subtracting(changed),
        )
    }

    /// Both selections: Auto Sync's steps, gathered while a sync runs.
    public func union(_ other: SettingsSelection) -> SettingsSelection {
        let masks = masks || other.masks
        let excluded = switch (self.masks, other.masks) {
        case (true, true): excludedMasks.intersection(other.excludedMasks)
        case (true, false): excludedMasks
        case (false, true): other.excludedMasks
        case (false, false): Set<UUID>()
        }
        return SettingsSelection(items: items.union(other.items), masks: masks, excludedMasks: excluded)
    }
}

/// Settings copied from a photo: the clipboard of Copy Settings and Paste.
public struct CopiedSettings: Sendable, Hashable {
    public var source: EditRecipe
    public var selection: SettingsSelection
    /// The photo they were copied from, if any.
    public var sourceURL: URL?

    public init(source: EditRecipe, selection: SettingsSelection, sourceURL: URL? = nil) {
        self.source = source
        self.selection = selection
        self.sourceURL = sourceURL
    }
}

public extension EditRecipe {
    /// This edit with `selection` of `source` pasted onto it. Each ticked item takes the source's
    /// values, defaults included, so a slider the source left alone resets this edit's. Masks merge
    /// by identity: a pasted mask replaces this edit's mask with the same id (pasted before from the
    /// same source) and is otherwise added, up to the layer limit, so pasting twice changes
    /// nothing. Everything else stays as it was, values written by a newer Redlamp included.
    func pasting(_ source: EditRecipe, _ selection: SettingsSelection) -> EditRecipe {
        var result = self
        for item in SettingsGroup.allItems where selection.includes(item) {
            for parameter in item.parameters {
                result[parameter] = source[parameter]
            }
            for field in item.fields {
                result.take(field, from: source)
            }
        }
        for mask in source.masks where selection.includes(mask: mask.id) {
            if let index = result.masks.firstIndex(where: { $0.id == mask.id }) {
                result.masks[index] = mask
            } else if result.masks.count < MaskLayer.maximumLayers {
                result.masks.append(mask)
            }
        }
        return result
    }

    /// The masks a paste of `selection` from `source` brings.
    static func pastedMasks(from source: EditRecipe, _ selection: SettingsSelection) -> Set<UUID> {
        Set(source.masks.map(\.id).filter(selection.includes(mask:)))
    }

    /// Whether `field` is the same in both edits.
    func matches(_ other: EditRecipe, in field: EditField) -> Bool {
        switch field {
        case .treatment: treatment == other.treatment
        case .baseLook: baseLook == other.baseLook && appliedRecipe == other.appliedRecipe
        case .whiteBalanceMode: whiteBalanceMode == other.whiteBalanceMode
        case .pointCurve: pointCurve == other.pointCurve
        case .crop: crop == other.crop
        case .orientation: orientation == other.orientation
        case .processVersion: processVersion == other.processVersion
        }
    }

    private mutating func take(_ field: EditField, from source: EditRecipe) {
        switch field {
        case .treatment: treatment = source.treatment
        case .baseLook:
            baseLook = source.baseLook
            appliedRecipe = source.appliedRecipe
        case .whiteBalanceMode: whiteBalanceMode = source.whiteBalanceMode
        case .pointCurve: pointCurve = source.pointCurve
        case .crop: crop = source.crop
        case .orientation: orientation = source.orientation
        case .processVersion: processVersion = source.processVersion
        }
    }
}
