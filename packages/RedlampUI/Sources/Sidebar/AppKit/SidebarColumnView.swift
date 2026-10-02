import AppKit
import RedlampDesign
import SwiftUI

/// The left column in AppKit: the Navigator on top, then Recipes, Snapshots and History,
/// scrolling beneath it. All four are panels like the inspector's: click a header to collapse
/// it, Option-click to show only that one.
final class SidebarColumnView: NSView, ColumnHost {
    private let navigator: PanelSectionView
    private let lists: SidebarListView

    init(model: EditorModel) {
        navigator = PanelSectionView(navigator: model)
        lists = SidebarListView(model: model)
        super.init(frame: .zero)
        addSubview(navigator)
        addSubview(lists)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    func columnContentDidChange() {
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = navigator.height(forWidth: bounds.width)
        navigator.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        lists.frame = CGRect(x: 0, y: height, width: bounds.width, height: max(bounds.height - height, 0))
    }
}

extension PanelSectionView {
    /// A left-column panel bound to the editor: expanded or collapsed with
    /// `expandedSidebarSections`, and a header menu to expand or collapse them all.
    convenience init(
        section: SidebarSection,
        model: EditorModel,
        accessory: NSView? = nil,
        insets: NSEdgeInsets = PanelSectionView.bodyInsets,
        rows: [NSView],
    ) {
        self.init(
            title: section.title,
            symbol: section.symbol,
            accessory: accessory,
            insets: insets,
            rows: rows,
            actions: Actions(
                isExpanded: { model.expandedSidebarSections.contains(section) },
                isEdited: { false },
                toggle: { solo in model.toggleSidebarSection(section, solo: solo) },
                reset: {},
            ),
        )
        headerMenu = {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Expand All Panels") {
                model.expandedSidebarSections = Set(SidebarSection.allCases)
            })
            menu.addItem(NSMenuItem(title: "Collapse All Panels") { model.expandedSidebarSections = [] })
            return menu
        }
    }
}

/// Hosts the AppKit sidebar column in the editor window, filling its space.
struct SidebarColumnHost: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context _: Context) -> SidebarColumnView {
        SidebarColumnView(model: model)
    }

    func updateNSView(_: SidebarColumnView, context _: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: SidebarColumnView, context _: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
