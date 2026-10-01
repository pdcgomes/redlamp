import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The palette shrunk to one slider: ← → step it, ↑ ↓ move to the next slider, and a value
/// or a name can be typed. Its hints sit where they apply; the capsule holds the rest.
struct PaletteSliderBar: View {
    let palette: CommandPaletteModel
    let parameter: ParameterID
    let panelOpacity: Double
    let isInteractive: Bool
    @Environment(\.themeTokens) private var themeTokens
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = ThemeColors(themeTokens)
        let editor = palette.editor
        let spec = parameter.spec
        let live = palette.isLive(parameter)
        let neighbours = palette.neighbours(of: parameter)
        let panel = PanelID.allCases.first { $0.parameters.contains(parameter) }
        VStack(alignment: .trailing, spacing: 8) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: panel?.symbol ?? "slider.horizontal.3")
                        .font(.system(size: 14))
                        .foregroundStyle(colors.secondaryLabel)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(parameter.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(colors.value)
                            .lineLimit(1)
                        Text(AdjustmentSearch.searchable.first { $0.parameter == parameter }?.context ?? panel?
                            .title ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(colors.tertiaryLabel)
                            .lineLimit(1)
                    }
                    .frame(width: 150, alignment: .leading)
                    KeyCaps(["←"], dimmed: !live)
                    SliderTrack(
                        spec: spec,
                        value: editor.sliderValue(parameter),
                        onBegin: { editor.beginEdit(parameter) },
                        onChange: { editor.setSliderValue(parameter, $0) },
                        onEnd: { editor.endEdit() },
                        onReset: { editor.resetSlider(parameter) },
                    )
                    .disabled(!live)
                    .opacity(live ? 1 : 0.4)
                    KeyCaps(["→"], dimmed: !live)
                    HStack(spacing: 5) {
                        Text(editor.info == nil ? "–" : spec.formatted(editor.sliderValue(parameter)))
                            .font(.system(size: 14, weight: .medium).monospacedDigit())
                            .foregroundStyle(colors.value)
                        Circle()
                            .fill(colors.editedDot)
                            .frame(width: 5, height: 5)
                            .opacity(editor.info != nil && editor.isEdited(parameter) ? 1 : 0)
                    }
                    .frame(width: 68, alignment: .trailing)
                }
                HStack(spacing: 12) {
                    Color.clear.frame(width: 20, height: 1)
                    if let previous = neighbours.previous {
                        neighbour("↑", previous)
                    }
                    if let next = neighbours.next {
                        neighbour("↓", next)
                    }
                    Spacer(minLength: 8)
                    PaletteQueryField(
                        text: palette.text,
                        placeholder: "type a value or a name",
                        font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                        alignment: .right,
                        textColor: palette.typedIsInvalid ? .systemRed : colors.tokens.value.nsColor,
                        placeholderColor: colors.tokens.tertiaryLabel.nsColor,
                        colorScheme: colorScheme,
                        revision: palette.textRevision,
                        selectsAll: palette.selectsTextOnRevision,
                        focuses: isInteractive,
                        onChange: { palette.setText($0) },
                        onKey: { palette.handle($0) },
                    )
                    .frame(width: 180)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .modifier(FloatingPane(opacity: PaletteMetrics.paneOpacity(panelOpacity)))

            PaletteHintCapsule(hints: palette.hints)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(parameter.displayName) slider")
        .accessibilityValue(editor.info == nil ? "" : spec.formatted(editor.sliderValue(parameter)))
        .accessibilityHint(palette.hints.map { "\($0.title): \($0.keys.joined(separator: " "))" }
            .joined(separator: ", "))
    }

    private func neighbour(_ key: String, _ parameter: ParameterID) -> some View {
        HStack(spacing: 4) {
            KeyCaps([key])
            Text(parameter.displayName)
                .font(.system(size: 11.5))
                .foregroundStyle(ThemeColors(themeTokens).secondaryLabel)
                .lineLimit(1)
        }
    }
}
