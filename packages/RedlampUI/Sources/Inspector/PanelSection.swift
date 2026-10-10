import AppKit
import SwiftUI

/// A collapsible Develop panel. Option-click the header for Solo Mode (only one panel
/// open), double-click to reset the panel. The switch at its leading edge turns the panel off
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
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PanelSwitch(panel: panel)
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
                EditedDot(panel: panel)
            }
            .padding(.horizontal, Theme.panelPadding)
            .frame(height: 32)
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
                .padding(.horizontal, Theme.panelPadding)
                .padding(.bottom, 14)
                .transition(.opacity)
            }

            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}

/// The header's on/off switch, or the room for one in Basic, so titles line up.
private struct PanelSwitch: View {
    let panel: PanelID
    @Environment(EditorModel.self) private var model

    var body: some View {
        let size = Theme.panelSwitchSize
        if panel.switchable != nil {
            let on = model.isOn(panel)
            let knob = size.height - 4
            Capsule()
                .fill(on ? Theme.trackFill : Theme.track)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(Theme.thumb).frame(width: knob, height: knob).padding(.horizontal, 2)
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .onTapGesture { model.setPanel(panel, on: !on) }
                .help("Turn \(panel.title) \(on ? "off" : "on")")
                .accessibilityElement()
                .accessibilityLabel(panel.title)
                .accessibilityValue(on ? "1" : "0")
                .accessibilityAddTraits(.isToggle)
                .accessibilityAction { model.setPanel(panel, on: !on) }
                .accessibilityIdentifier("panel.\(panel.rawValue).switch")
        } else {
            Color.clear.frame(width: size.width, height: size.height)
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
                .fill(Theme.editedDot)
                .frame(width: 4, height: 4)
                .help("This panel has edits")
        }
    }
}
