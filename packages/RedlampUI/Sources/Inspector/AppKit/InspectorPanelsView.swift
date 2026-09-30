import AppKit
import RedlampDesign
import SwiftUI

/// The scrolling column of Develop panels, in AppKit.
///
/// Panels ported to AppKit update only the controls whose values change. Panels not yet
/// ported are each hosted on their own, so their SwiftUI updates stay small.
final class InspectorPanelsView: NSView {
    private let scrollView = NSScrollView()
    private let document: InspectorDocumentView

    init(model: EditorModel) {
        func hosted(_ panel: some View) -> NSView {
            HostedPanelView(rootView: AnyView(panel.environment(model)))
        }
        document = InspectorDocumentView(views: [
            BasicPanelView.make(model: model),
            ToneCurvePanelView.make(model: model),
            ColorMixerPanelView.make(model: model),
            hosted(ColorGradingPanel()),
            ReferencePanelViews.detail(model: model),
            ReferencePanelViews.lens(model: model),
            ReferencePanelViews.transform(model: model),
            ReferencePanelViews.effects(model: model),
            ReferencePanelViews.calibration(model: model),
        ])
        super.init(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = document
        addSubview(scrollView)
        document.onHeightChange = { [weak self] in self?.sizeDocument() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        sizeDocument()
    }

    private func sizeDocument() {
        let width = scrollView.contentSize.width
        let size = CGSize(width: width, height: document.height(forWidth: width))
        if document.frame.size != size {
            document.setFrameSize(size)
        }
        document.layoutSubtreeIfNeeded()
    }
}

/// The scroll view's document: the panels, top to bottom.
final class InspectorDocumentView: ColumnView, ColumnHost {
    var onHeightChange: () -> Void = {}

    init(views: [NSView]) {
        super.init(views: views)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func columnContentDidChange() {
        onHeightChange()
    }
}

/// A SwiftUI panel hosted in the AppKit column, reporting its height as it changes.
///
/// Its height is what SwiftUI chooses at the column's width with no height limit, as in
/// a scroll view: the minimum (`fittingSize`) would collapse flexible content such as the
/// square tone curve to nothing.
final class HostedPanelView: NSView, HeightProviding {
    private let controller: NSHostingController<AnyView>
    private var observation: NSKeyValueObservation?

    init(rootView: AnyView) {
        controller = NSHostingController(rootView: rootView)
        controller.sizingOptions = [.preferredContentSize]
        super.init(frame: .zero)
        addSubview(controller.view)
        observation = controller.observe(\.preferredContentSize) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.invalidateColumnLayout() }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    override func layout() {
        super.layout()
        controller.view.frame = bounds
    }
}

/// Hosts the panel column in the SwiftUI inspector, filling the space it is given.
struct InspectorPanelsHost: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context _: Context) -> InspectorPanelsView {
        InspectorPanelsView(model: model)
    }

    func updateNSView(_: InspectorPanelsView, context _: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: InspectorPanelsView, context _: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
