import AppKit
import RedlampDesign

/// The painter's button in the Keywording panel (LIB-21), beside the keyword set it paints while its field in the
/// grid's toolbar is empty: on while the painter is out (`KeywordPainter`).
final class KeywordPainterButton: NSButton {
    private weak var model: EditorModel?
    private var tracker: Tracker?

    init(model: EditorModel?) {
        self.model = model
        super.init(frame: .zero)
        title = "Painter"
        setButtonType(.pushOnPushOff)
        bezelStyle = .rounded
        controlSize = .small
        font = Typography.label.nsFont
        toolTip = "\(ShortcutAction.keywordPainter.title) (\(ShortcutAction.keywordPainter.combos.first?.display ?? "")): "
            + "click or drag over photos in the grid to put the keyword set's keywords on them, ⌥ to take them off"
        setAccessibilityIdentifier("keywording.painter")
        target = self
        action = #selector(pressed)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil, let model else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            let painter = model.keywordPainter
            let shown: NSControl.StateValue = painter.isOn ? .on : .off
            if state != shown {
                state = shown
            }
            let enabled = painter.isOn || painter.isAvailable
            if isEnabled != enabled {
                isEnabled = enabled
            }
        }
    }

    @objc private func pressed() {
        guard let model else { return }
        model.perform(.keywordPainter)
        state = model.keywordPainter.isOn ? .on : .off
    }
}
