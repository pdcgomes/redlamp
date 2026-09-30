import AppKit
import RedlampDesign
import SwiftUI

/// The left column in AppKit: the Navigator on top, then Presets, Snapshots and History.
final class SidebarColumnView: NSView {
    private let navigator: ColumnView
    private let lists: NSView

    init(model: EditorModel) {
        navigator = ColumnView(
            insets: NSEdgeInsets(top: 0, left: 12, bottom: 10, right: 12),
            views: [NavigatorPanelView(model: model)],
        )
        lists = NSHostingView(rootView: SidebarLists().environment(model))
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

    override func layout() {
        super.layout()
        let height = navigator.height(forWidth: bounds.width)
        navigator.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        lists.frame = CGRect(x: 0, y: height, width: bounds.width, height: max(bounds.height - height, 0))
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
