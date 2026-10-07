import Foundation
import RedlampColor
import RedlampEngineAPI

/// The designs behind the bundled film-style Base Looks, one per camera-card slot.
///
/// `redlamp recipe build-pack` turns these into the tables in Resources/BaseLooks; the
/// shipped tables are what edits pin, so a changed design must ship as a new version.
public enum StarterPackLooks {
    public static let tableSize = 25
    public static let version = 1

    public static func id(for slot: FilmSlot) -> String {
        "\(RecipeNamespace.bundled)/film/\(slot.rawValue)"
    }

    /// Band order: red, orange, yellow, green, aqua, blue, purple, magenta.
    public static func design(for slot: FilmSlot) -> LookDesign {
        var d = LookDesign()
        switch slot {
        case .standard:
            d.contrast = 0.12
            d.saturation = 1.05
            d.chromaScales = [1, 1, 1, 1.03, 1, 1.05, 1, 1]
        case .vividSlide:
            d.contrast = 0.32
            d.saturation = 1.24
            d.density = 0.45
            d.hueShifts = [3, 0, -2, -6, -4, 4, 0, 0]
            d.chromaScales = [1.05, 1, 1.05, 1.15, 1.1, 1.12, 1.05, 1.1]
            d.lightnessShifts = [0, 0, 0, -0.01, -0.01, -0.03, 0, 0]
        case .softSlide:
            d.contrast = 0.04
            d.saturation = 1.04
            d.chromaScales = [1, 0.94, 1, 1.02, 1.04, 1.08, 1, 1]
            d.lightnessShifts = [0, 0.012, 0.005, 0, 0, 0, 0, 0]
            d.highlightDesaturation = 0.12
        case .chrome:
            d.contrast = 0.3
            d.saturation = 0.8
            d.density = 0.5
            d.hueShifts = [4, 0, -4, -10, -6, -8, 0, 0]
            d.chromaScales = [0.85, 0.92, 0.78, 0.7, 0.8, 0.95, 0.85, 0.85]
            d.lightnessShifts = [-0.01, 0, 0, -0.01, -0.01, -0.04, 0, 0]
            d.highlightDesaturation = 0.2
            d.shadowDesaturation = 0.18
            d.shadowTint = [-0.004, -0.003]
        case .negativeHigh:
            d.contrast = 0.18
            d.saturation = 0.95
            d.chromaScales = [1, 0.95, 0.95, 0.95, 1, 1, 1, 1]
            d.highlightTint = [0.002, 0.005]
        case .negativeStandard:
            d.contrast = -0.12
            d.saturation = 0.88
            d.fade = 0.01
            d.chromaScales = [1, 0.95, 0.95, 0.92, 1, 1, 1, 1]
            d.shadowTint = [-0.002, -0.004]
        case .negativeClassic:
            d.contrast = 0.38
            d.saturation = 0.9
            d.fade = 0.02
            d.hueShifts = [-6, -2, 6, 10, 4, 2, 0, -4]
            d.chromaScales = [1.05, 0.95, 0.85, 0.8, 0.9, 0.95, 1, 1]
            d.lightnessShifts = [0, 0, 0, 0, 0, -0.03, 0, 0]
            d.shadowDesaturation = 0.1
            d.shadowTint = [-0.012, -0.004]
            d.highlightTint = [0.006, 0.01]
        case .negativeNostalgic:
            d.contrast = 0.05
            d.saturation = 0.9
            d.fade = 0.02
            d.whiteRoll = 0.02
            d.hueShifts = [0, 0, 0, 4, 0, -6, 0, 0]
            d.chromaScales = [1, 1.1, 1.08, 0.85, 0.9, 0.85, 1, 1]
            d.midtoneTint = [0.004, 0.01]
            d.highlightTint = [0.008, 0.02]
        case .cinema:
            d.contrast = -0.25
            d.saturation = 0.72
            d.fade = 0.015
            d.hueShifts = [0, 0, 0, 8, 0, 0, 0, 0]
            d.chromaScales = [1, 0.92, 0.9, 0.75, 0.9, 0.9, 1, 1]
            d.shadowTint = [-0.01, -0.008]
            d.highlightTint = [0.002, 0.006]
        case .bleach:
            d.contrast = 0.55
            d.saturation = 0.45
            d.density = 0.3
            d.highlightDesaturation = 0.3
            d.shadowDesaturation = 0.3
            d.shadowTint = [-0.003, -0.004]
        case .monochrome:
            d.contrast = 0.22
            d.monochrome = .init(weights: [Luma.rec2020Double.x, Luma.rec2020Double.y, Luma.rec2020Double.z])
        case .monochromeYellow:
            d.contrast = 0.26
            d.monochrome = .init(weights: [0.42, 0.55, 0.03])
        case .monochromeRed:
            d.contrast = 0.32
            d.monochrome = .init(weights: [0.8, 0.2, 0])
        case .monochromeGreen:
            d.contrast = 0.2
            d.monochrome = .init(weights: [0.18, 0.78, 0.04])
        case .sepia:
            d.contrast = 0.1
            d.fade = 0.02
            d.monochrome = .init(weights: [Luma.rec2020Double.x, Luma.rec2020Double.y, Luma.rec2020Double.z])
        }
        return d
    }

    public static func package(for slot: FilmSlot) throws -> BaseLookPackage {
        let table = try LookSynthesizer.table(for: design(for: slot), size: tableSize)
        return BaseLookPackage(
            id: id(for: slot), version: version, name: slot.name, summary: slot.summary, slot: slot.rawValue,
            parameters: BaseLookParameters(contrast: 1, saturation: 1, warmth: 0, isMonochrome: slot.isMonochrome),
            table: table,
        )
    }
}
