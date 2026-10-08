import AppKit
import RedlampDesign

/// The Library module's Library panel (LIB-23), above Folders, as Lightroom Classic's Catalog panel is, and its
/// Collections panel, below them: each open or closed as it was left, kept between launches.
@MainActor
enum SourcePanels {
    static func library(model: EditorModel) -> PanelSectionView {
        section(.library, model: model, rows: [LibraryOutlineView(model: model)])
    }

    /// The collection list, with a + in its header that makes a collection, a smart collection or a set.
    static func collections(model: EditorModel) -> PanelSectionView {
        let add = SymbolImageView("plus", pointSize: 11, color: Palette.secondaryLabel.nsColor)
        add.toolTip = "New Collection, Smart Collection or Collection Set"
        add.setAccessibilityRole(.button)
        add.setAccessibilityLabel("New Collection, Smart Collection or Collection Set")
        add.setAccessibilityIdentifier("sources.collections.add")
        add.onClick = { [weak add] in
            guard let add else { return }
            let menu = newMenu(model: model)
            menu.popUp(positioning: nil, at: CGPoint(x: 0, y: add.bounds.height + 4), in: add)
        }
        let section = section(.collections, model: model, accessory: add, rows: [CollectionOutlineView(model: model)])
        section.headerMenu = { newMenu(model: model) }
        return section
    }

    /// New Collection…, New Smart Collection… and New Collection Set…, as their actions are in the File menu.
    static func newMenu(model: EditorModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in [ShortcutAction.newCollection, .newSmartCollection, .newCollectionSet] {
            let item = NSMenuItem(title: action.title) { model.perform(action) }
            item.isEnabled = model.library.service?.isReady == true
            menu.addItem(item)
        }
        return menu
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
