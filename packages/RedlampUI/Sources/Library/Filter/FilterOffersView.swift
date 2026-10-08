import AppKit
import RedlampDesign
import RedlampLibrary

/// The offers for a filter that finds none of the source's photos (LIB-18), as buttons: a name of the library's in
/// a misspelt word's place ("Did you mean Lisbon? 2 photos"), then the term whose removal brings back the most;
/// a click on one changes the query. It follows the filter alone and is as wide as its buttons, so it goes
/// wherever the query's text goes; the filter bar shows it in its header.
final class FilterOffersView: NSView {
    /// Told when the buttons' titles change, for the view holding it to lay it out again.
    var onResize: (() -> Void)?

    private let model: EditorModel
    private var tracker: Tracker?
    private let buttons: [(kind: FilterOffer.Kind, button: FilterToggle)]
    private var shown: [FilterOffer] = []

    static let gap: CGFloat = 4

    init(model: EditorModel) {
        self.model = model
        buttons = [
            (.suggestion, FilterToggle(title: "", identifier: "library.filter.suggestion", tip: "")),
            (.removal, FilterToggle(title: "", identifier: "library.filter.removal", tip: "")),
        ]
        super.init(frame: .zero)
        for (kind, button) in buttons {
            button.isHidden = true
            button.onPress = { [weak self] _ in self?.model.libraryFilters?.take(kind) }
            addSubview(button)
        }
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = window == nil ? nil : Tracker { [weak self] in self?.update() }
    }

    /// The buttons as the filter's offers have them.
    private func update() {
        let offers = model.libraryFilters?.offers ?? []
        guard offers != shown else { return }
        shown = offers
        for (kind, button) in buttons {
            let offer = offers.first { $0.kind == kind }
            button.isHidden = offer == nil
            button.title = offer?.title ?? ""
            button.toolTip = offer?.help
            button.setAccessibilityLabel(offer?.title)
        }
        isHidden = offers.isEmpty
        needsLayout = true
        onResize?()
    }

    /// The width its buttons need.
    var fittingWidth: CGFloat {
        let widths = buttons.filter { !$0.button.isHidden }.map(\.button.fittingWidth)
        return widths.reduce(0, +) + Self.gap * CGFloat(max(widths.count - 1, 0))
    }

    /// The buttons side by side, each narrowed alike when there's less room than they need.
    override func layout() {
        super.layout()
        let needed = fittingWidth
        let scale = needed > bounds.width && needed > 0 ? bounds.width / needed : 1
        var x: CGFloat = 0
        for (_, button) in buttons where !button.isHidden {
            let width = floor(button.fittingWidth * scale)
            button.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + Self.gap
        }
    }
}
