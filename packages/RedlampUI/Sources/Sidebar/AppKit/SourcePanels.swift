import AppKit
import RedlampDesign

/// The Library module's Library panel (LIB-23), above Folders, as Lightroom Classic's Catalog panel is: open or
/// closed as it was left, kept between launches.
@MainActor
enum SourcePanels {
    static func library(model: EditorModel) -> PanelSectionView {
        section(.library, model: model, rows: [LibraryOutlineView(model: model)])
    }

    private static func section(
        _ panel: LibrarySources.Panel, model: EditorModel, accessory: NSView? = nil, rows: [NSView],
    ) -> PanelSectionView {
        let sources = model.librarySources
        let section = PanelSectionView(
            title: panel.title, symbol: panel.symbol, accessory: accessory,
            insets: NSEdgeInsets(top: 0, left: 0, bottom: Metrics.panelBottomPadding, right: 0), rows: rows,
            actions: PanelSectionView.Actions(
                isExpanded: { sources.isExpanded(panel) },
                isEdited: { false },
                toggle: { solo in sources.toggle(panel, solo: solo) },
                reset: {},
            ),
        )
        section.identify(as: "sources.\(panel.rawValue)")
        return section
    }
}
