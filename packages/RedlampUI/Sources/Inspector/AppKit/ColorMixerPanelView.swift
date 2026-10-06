import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The Color Mixer: HSL (one attribute across the eight bands, or all three), the per-color
/// mixer (one band's hue, saturation and luminance), or Point Color (swatches picked on the
/// photo, each with its shift, uniformity and range).
@MainActor
@_spi(Harness) public enum ColorMixerPanelView {
    public static func make(model: EditorModel, mixer initial: ColorMixerPanel.Mixer = .hsl) -> PanelSectionView {
        let rows = PanelRows(model: model)
        let state = ColorMixerState(mixer: initial)
        let mixer = PaddingView(
            ControlRowView(label: "Mixer", controls: [rows.native(MixerPicker(state: state))]),
            bottom: 4,
        )
        let attribute = PaddingView(
            ControlRowView(label: "Adjust", controls: [rows.native(AttributePicker(state: state))]),
            bottom: 4,
        )
        let swatches = rows.native(BandSwatches(state: state).padding(.bottom, 6))
        let pointColorSwatches = rows.native(PointColorSwatches().padding(.bottom, 2))
        let visualize = rows.native(PointColorVisualizeToggle().padding(.top, 4))
        let picked = { @MainActor in model.selectedPointColorSwatch != nil }

        func content() -> [NSView] {
            switch state.mixer {
            case .hsl:
                let attributeRows: [NSView] = if state.attribute == .all {
                    [ColorMixerPanel.Attribute.hue, .saturation, .luminance].flatMap { group in
                        let parameters = ColorBand.allCases.map { group.parameter(for: $0) }
                        return [rows.header(group.rawValue, parameters)] + rows.sliders(parameters)
                    }
                } else {
                    rows.sliders(ColorBand.allCases.map { state.attribute.parameter(for: $0) })
                }
                return [mixer, attribute] + attributeRows
            case .color:
                let band = state.band
                return [
                    mixer,
                    swatches,
                    rows.slider(band.hueParameter, label: "Hue"),
                    rows.slider(band.saturationParameter, label: "Saturation"),
                    rows.slider(band.luminanceParameter, label: "Luminance"),
                ]
            case .pointColor:
                let groups = PointColorGroup.all.flatMap { group -> [NSView] in
                    let sliders: [NSView] = group.parameters.map {
                        rows.slider($0, label: PointColorGroup.label($0), enabled: picked)
                    }
                    return [rows.header(group.title, group.parameters)] + sliders
                }
                return [mixer, pointColorSwatches] + groups + [visualize]
            }
        }

        let panel = rows.panel(.colorMixer, rows: content())
        state.onChange = { [weak panel] in
            if state.mixer != .pointColor {
                model.leavePointColor()
            }
            panel?.setRows(content())
        }
        return panel
    }
}
