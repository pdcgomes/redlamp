import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The Color Mixer: HSL (one attribute across the eight bands, or all three) or the
/// per-color mixer (one band's hue, saturation and luminance).
@MainActor
@_spi(Harness) public enum ColorMixerPanelView {
    public static func make(model: EditorModel) -> PanelSectionView {
        let rows = PanelRows(model: model)
        let state = ColorMixerState()
        let mixer = PaddingView(
            ControlRowView(label: "Mixer", controls: [rows.native(MixerPicker(state: state))]),
            bottom: 4,
        )
        let attribute = rows.native(AttributePicker(state: state).padding(.bottom, 4))
        let swatches = rows.native(BandSwatches(state: state).padding(.bottom, 6))

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
            }
        }

        let panel = rows.panel(.colorMixer, rows: content())
        state.onChange = { [weak panel] in panel?.setRows(content()) }
        return panel
    }
}
