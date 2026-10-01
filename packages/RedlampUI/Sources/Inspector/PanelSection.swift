import AppKit
import SwiftUI

/// A collapsible Develop panel. Option-click the header for Solo Mode (only one panel
/// open), double-click to reset the panel.
struct PanelSection<Content: View>: View {
    let panel: PanelID
    var badge: String?
    @ViewBuilder var content: Content

    @Environment(EditorModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let expanded = model.expandedPanels.contains(panel)
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
                    .foregroundStyle(hovering ? Theme.labelHover : Theme.value)
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
            .onTapGesture(count: 2) { model.resetParameters(panel.parameters, name: "Reset \(panel.title)") }
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) {
                    model.togglePanel(panel, solo: NSEvent.modifierFlags.contains(.option))
                }
            }
            .contextMenu {
                Button("Reset \(panel.title)") { model.resetParameters(panel.parameters, name: "Reset \(panel.title)") }
                Divider()
                Toggle("Solo Mode", isOn: Bindable(model).soloMode)
                Button("Expand All Panels") { model.expandedPanels = Set(PanelID.allCases) }
                Button("Collapse All Panels") { model.expandedPanels = [] }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    content
                }
                .padding(.horizontal, Theme.panelPadding)
                .padding(.bottom, 14)
                .transition(.opacity)
            }

            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}

/// Its own view so that a slider drag, which changes whether the panel is edited, re-evaluates
/// just the dot rather than the whole panel.
private struct EditedDot: View {
    let panel: PanelID
    @Environment(EditorModel.self) private var model

    var body: some View {
        if panel.parameters.contains(where: model.isEdited) {
            Circle()
                .fill(Theme.editedDot)
                .frame(width: 4, height: 4)
                .help("This panel has edits")
        }
    }
}
