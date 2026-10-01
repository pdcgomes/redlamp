import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// Detail, Lens Corrections, Transform, Effects and Calibration: mostly laid out for
/// fidelity and rendering in later phases. Their sliders come from the parameter schema,
/// so they light up when the engine marks a parameter live.
@MainActor
@_spi(Harness) public enum ReferencePanelViews {
    public static func detail(model: EditorModel) -> PanelSectionView {
        let rows = PanelRows(model: model)
        let sharpening: [ParameterID] = [.sharpenAmount, .sharpenRadius, .sharpenDetail, .sharpenMasking]
        let luminance: [ParameterID] = [.noiseLuminance, .noiseLuminanceDetail, .noiseLuminanceContrast]
        return rows.panel(
            .detail,
            badge: "Phase 2",
            rows: [rows.header("Sharpening", sharpening)]
                + rows.sliders(sharpening)
                + [rows.header("Noise Reduction", luminance)]
                + rows.sliders(luminance)
                + [rows.gap()]
                + rows.sliders([.noiseColor, .noiseColorDetail, .noiseColorSmoothness]),
        )
    }

    public static func lens(model: EditorModel) -> PanelSectionView {
        let rows = PanelRows(model: model)
        let manual: [ParameterID] = [.lensDistortion, .lensVignetting, .lensVignettingMidpoint]
        // In the panel's own stack SwiftUI leaves a point above the first checkbox (their
        // alignment insets) that a separately hosted one doesn't; the harness's Lens parity
        // scene checks it.
        return rows.panel(.lens, badge: "Phase 2", rows: [
            rows.native(LensToggle(title: "Remove Chromatic Aberration", help: nil).padding(.top, 1)),
            rows.native(LensToggle(
                title: "Enable Profile Corrections",
                help: "lensfun and LCP lens profiles arrive in Phase 2",
            )),
            rows.header("Manual", manual),
        ] + rows.sliders(manual))
    }

    public static func transform(model: EditorModel) -> PanelSectionView {
        let rows = PanelRows(model: model)
        return rows.panel(.transform, badge: "Phase 2", rows: [
            rows.controls("Upright", UprightButtons()),
            rows.header("Manual", PanelID.transform.parameters),
        ] + rows.sliders(PanelID.transform.parameters))
    }

    public static func effects(model: EditorModel) -> PanelSectionView {
        let rows = PanelRows(model: model)
        let vignette: [ParameterID] = [
            .vignetteAmount, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather, .vignetteHighlights,
        ]
        let grain: [ParameterID] = [.grainAmount, .grainSize, .grainRoughness, .grainColor]
        let halation: [ParameterID] = [.halationAmount, .halationSize]
        let bloom: [ParameterID] = [.bloomAmount, .bloomSize]
        return rows.panel(
            .effects,
            rows: [
                rows.header("Post-Crop Vignetting", vignette),
                rows.controls("Style", VignetteStylePicker()),
            ] + rows.sliders(vignette) + [rows.header("Grain", grain)] + rows.sliders(grain)
                + [rows.header("Halation", halation)] + rows.sliders(halation)
                + [rows.header("Bloom", bloom)] + rows.sliders(bloom)
                + [rows.header("Camera Recipe", PanelID.cameraRecipeParameters)] + rows
                .sliders(PanelID.cameraRecipeParameters),
        )
    }

    public static func calibration(model: EditorModel) -> PanelSectionView {
        let rows = PanelRows(model: model)
        let primaries: [(String, [ParameterID])] = [
            ("Red Primary", [.calibrationRedHue, .calibrationRedSaturation]),
            ("Green Primary", [.calibrationGreenHue, .calibrationGreenSaturation]),
            ("Blue Primary", [.calibrationBlueHue, .calibrationBlueSaturation]),
        ]
        return rows.panel(.calibration, badge: "Phase 2", rows: [
            rows.controls("Process", ProcessVersion()),
            rows.header("Shadows", [.calibrationShadowsTint]),
            rows.slider(.calibrationShadowsTint),
        ] + primaries.flatMap { title, parameters in [rows.header(title, parameters)] + rows.sliders(parameters) })
    }
}
