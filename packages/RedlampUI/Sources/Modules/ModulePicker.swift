import AppKit
import RedlampDesign

/// The module picker in the toolbar, as Lightroom Classic has it: the modules by name, the one shown
/// brighter, each a click away. A click switches at once: the picker takes the press itself rather than
/// tracking the mouse as a button would.
final class ModulePickerView: NSView {
    private let model: EditorModel
    private let buttons: [AppModule: NSButton]
    private var tracker: Tracker?

    private static let spacing: CGFloat = 14
    private static let padding: CGFloat = 10
    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    init(model: EditorModel) {
        self.model = model
        var buttons: [AppModule: NSButton] = [:]
        for module in AppModule.allCases {
            let button = NSButton(title: module.title, target: nil, action: nil)
            button.isBordered = false
            button.setButtonType(.momentaryChange)
            button.font = Self.font
            button.toolTip = "\(module.title) (\(module.action.combos.first?.display ?? ""))"
            button.setAccessibilityIdentifier("module.\(module.rawValue)")
            buttons[module] = button
        }
        self.buttons = buttons
        super.init(frame: .zero)
        for module in AppModule.allCases {
            guard let button = buttons[module] else { continue }
            button.target = self
            button.action = #selector(choose(_:))
            addSubview(button)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Module")
        setFrameSize(fittingSize)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        let widths = AppModule.allCases.compactMap { buttons[$0]?.intrinsicContentSize.width }
        let height = buttons.values.map(\.intrinsicContentSize.height).max() ?? 22
        return NSSize(
            width: widths.reduce(0, +) + Self.spacing * CGFloat(max(widths.count - 1, 0)) + Self.padding * 2,
            height: max(height, 24),
        )
    }

    override func layout() {
        super.layout()
        var x = Self.padding
        for module in AppModule.allCases {
            guard let button = buttons[module] else { continue }
            let size = button.intrinsicContentSize
            button.frame = CGRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x += size.width + Self.spacing
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            let shown = model.module
            for (module, button) in buttons {
                let color = (module == shown ? Palette.label : Palette.tertiaryLabel).nsColor
                button.attributedTitle = NSAttributedString(
                    string: module.title, attributes: [.foregroundColor: color, .font: Self.font],
                )
                button.setAccessibilityValue(module == shown ? "shown" : nil)
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let button = buttons.values
            .first(where: { $0.frame.insetBy(dx: -Self.spacing / 2, dy: -6).contains(point) })
        else { return }
        choose(button)
    }

    @objc private func choose(_ sender: NSButton) {
        guard let module = buttons.first(where: { $0.value === sender })?.key else { return }
        model.perform(module.action)
    }
}

@MainActor
enum ModulePicker {
    static func item(_ identifier: NSToolbarItem.Identifier, model: EditorModel) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Module"
        item.toolTip = "Library (⌥⌘1) or Develop (⌥⌘2)"
        item.view = ModulePickerView(model: model)
        return item
    }
}
