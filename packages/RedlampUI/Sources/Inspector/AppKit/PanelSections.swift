import AppKit
import RedlampDesign
import RedlampEngineAPI

extension EditorModel: ParameterEditing {}

extension PanelSectionView {
    /// A Develop panel bound to the editor: expanded state, the edited dot, reset, Solo
    /// Mode and the header's context menu.
    convenience init(panel: PanelID, model: EditorModel, badge: String? = nil, rows: [NSView]) {
        self.init(
            title: panel.title,
            badge: badge,
            rows: rows,
            actions: Actions(
                isExpanded: { model.expandedPanels.contains(panel) },
                isEdited: { panel.parameters.contains(where: model.isEdited) },
                toggle: { solo in model.togglePanel(panel, solo: solo) },
                reset: { model.resetParameters(panel.parameters, name: "Reset \(panel.title)") },
            ),
        )
        headerMenu = {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Reset \(panel.title)") {
                model.resetParameters(panel.parameters, name: "Reset \(panel.title)")
            })
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Solo Mode", state: model.soloMode ? .on : .off) { model.soloMode.toggle() })
            menu.addItem(NSMenuItem(title: "Expand All Panels") { model.expandedPanels = Set(PanelID.allCases) })
            menu.addItem(NSMenuItem(title: "Collapse All Panels") { model.expandedPanels = [] })
            return menu
        }
    }
}
