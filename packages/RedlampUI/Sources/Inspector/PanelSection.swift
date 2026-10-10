import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// A collapsible Develop panel, drawn as a card. Option-click the header for Solo Mode (only one
/// panel open), double-click to reset the panel. The eye at its trailing edge turns the panel off
/// or on (UX-30); while it's off, its title and rows are dimmed and stay usable.
struct PanelSection<Content: View>: View {
    let panel: PanelID
    var badge: String?
    @ViewBuilder var content: Content

    @Environment(EditorModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let expanded = model.expandedPanels.contains(panel)
        let on = model.isOn(panel)
        let shape = RoundedRectangle(cornerRadius: Theme.panelCardRadius, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondaryLabel)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Image(systemName: panel.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryLabel)
                    .frame(width: Theme.panelSymbolSlot)
                    .padding(.trailing, -2)
                Text(panel.title)
                    .font(Theme.panelTitleFont)
                    .foregroundStyle(
                        on ? (hovering ? Theme.labelHover : Theme.value)
                            : (hovering ? Theme.secondaryLabel : Theme.tertiaryLabel),
                    )
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.secondaryLabel)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.selection))
                }
                Spacer()
                HStack(spacing: 2) {
                    EditedDot(panel: panel)
                    PanelEye(panel: panel)
                }
                // The eye's glyph, not its hit target, ends at the padding.
                .padding(.trailing, -3)
            }
            .padding(.horizontal, Theme.panelCardPadding)
            .frame(height: 32)
            .background(hovering ? Theme.cardHover : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { model.resetPanel(panel) }
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) {
                    model.togglePanel(panel, solo: NSEvent.modifierFlags.contains(.option))
                }
            }
            .contextMenu {
                Button("Reset \(panel.title)") { model.resetPanel(panel) }
                if panel.switchable != nil {
                    Button("Turn \(panel.title) \(on ? "Off" : "On")") { model.setPanel(panel, on: !on) }
                }
                Divider()
                Toggle("Solo Mode", isOn: Bindable(model).soloMode)
                Button("Expand All Panels") { model.expandedPanels = Set(PanelID.allCases) }
                Button("Collapse All Panels") { model.expandedPanels = [] }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    content
                }
                .opacity(on ? 1 : Theme.switchedOffOpacity)
                .padding(.horizontal, Theme.panelCardPadding)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
        .environment(\.valueColumnWidth, Self.valueColumnWidth(panel))
        .background(Theme.card, in: shape)
        .overlay(shape.strokeBorder(Theme.divider, lineWidth: 1))
        .clipShape(shape)
    }
}

extension PanelSection {
    /// The panel's value column, as `PanelSectionView` works it out from its slider rows.
    static func valueColumnWidth(_ panel: PanelID) -> CGFloat {
        let parameters = panel.parameters + (panel == .colorMixer ? ParameterID.pointColorParameters : [])
        return ValueFieldView.columnTextWidth(for: parameters.map(\.spec))
    }
}

/// The header's eye, or the room for one in Basic, so the edited dots line up.
private struct PanelEye: View {
    let panel: PanelID
    @Environment(EditorModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let side = Theme.panelEyeTarget
        if panel.switchable != nil {
            let on = model.isOn(panel)
            Image(systemName: on ? "eye" : "eye.slash")
                .font(.system(size: Theme.panelEyePointSize))
                .foregroundStyle(hovering ? Theme.labelHover : on ? Theme.tertiaryLabel : Theme.secondaryLabel)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture { model.setPanel(panel, on: !on) }
                .help("Turn \(panel.title) \(on ? "off" : "on")")
                .accessibilityElement()
                .accessibilityLabel(panel.title)
                .accessibilityValue(on ? "1" : "0")
                .accessibilityAddTraits(.isToggle)
                .accessibilityAction { model.setPanel(panel, on: !on) }
                .accessibilityIdentifier("panel.\(panel.rawValue).switch")
        } else {
            Color.clear.frame(width: side, height: side)
        }
    }
}

/// Its own view so that a slider drag, which changes whether the panel is edited, re-evaluates
/// just the dot rather than the whole panel.
private struct EditedDot: View {
    let panel: PanelID
    @Environment(EditorModel.self) private var model

    var body: some View {
        if model.isEdited(panel) {
            Circle()
                .fill(Theme.panelEditedDot)
                .frame(width: Theme.editedDotSize, height: Theme.editedDotSize)
                .help("This panel has edits")
        }
    }
}
