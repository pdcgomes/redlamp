import AppKit
import RedlampDesign

/// A button of the filter bar: a title or a symbol, in a colour of its own (a label's), lit while it's
/// on, acting as it's pressed, as the Library toolbar's buttons do. ⇧ and ⌘ held reach `onPress`.
final class FilterToggle: NSView {
    var onPress: ((NSEvent.ModifierFlags) -> Void)?
    var isOn = false {
        didSet {
            if isOn != oldValue {
                update()
            }
        }
    }

    var symbol: String? {
        didSet {
            if symbol != oldValue {
                image.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            }
        }
    }

    private let image = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let color: NSColor?

    init(symbol: String? = nil, title: String? = nil, color: NSColor? = nil, identifier: String, tip: String) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        if let symbol {
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            addSubview(image)
        }
        self.symbol = symbol
        if let title {
            label.stringValue = title
            label.font = Typography.caption.nsFont
            label.alignment = .center
            addSubview(label)
        }
        toolTip = tip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(tip)
        update()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The width its title or symbol needs.
    var fittingWidth: CGFloat {
        label.stringValue.isEmpty ? 22 : ceil(label.intrinsicContentSize.width) + 12
    }

    private func update() {
        let tint = color ?? (isOn ? Palette.label : Palette.secondaryLabel).nsColor
        image.contentTintColor = color.map { isOn ? $0 : $0.withAlphaComponent(0.55) } ?? tint
        label.textColor = tint
        layer?.backgroundColor = isOn ? NSColor(white: 1, alpha: 0.16).cgColor : nil
        layer?.borderColor = NSColor(white: 1, alpha: isOn ? 0.35 : 0).cgColor
        layer?.borderWidth = isOn ? 1 : 0
        setAccessibilityValue(isOn ? "on" : "off")
    }

    override func layout() {
        super.layout()
        image.frame = bounds.insetBy(dx: 3, dy: 2)
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onPress?(event.modifierFlags)
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?([])
        return true
    }
}

/// The width `label` needs for its text: its own padding included.
@MainActor
func filterWidth(_ label: NSTextField) -> CGFloat {
    ceil(label.intrinsicContentSize.width) + 4
}

/// A small text label for the bar.
@MainActor
func filterLabel(_ text: String, secondary: Bool = true) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Typography.caption.nsFont
    label.textColor = (secondary ? Palette.secondaryLabel : Palette.label).nsColor
    label.lineBreakMode = .byTruncatingTail
    return label
}

/// A pop-up of the bar, its menu's items calling back with their tags.
final class FilterPopUp: NSPopUpButton {
    var onChoose: ((Int) -> Void)?

    init(identifier: String, tip: String) {
        super.init(frame: .zero, pullsDown: false)
        controlSize = .small
        font = Typography.caption.nsFont
        bezelStyle = .flexiblePush
        isBordered = false
        toolTip = tip
        target = self
        action = #selector(chose)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(tip)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Sets its items, `(title, tag)`, a nil title for a separator, choosing the one tagged `chosen`.
    func set(_ items: [(title: String?, tag: Int)], chosen: Int?) {
        let menu = NSMenu()
        for item in items {
            guard let title = item.title else {
                menu.addItem(.separator())
                continue
            }
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            entry.tag = item.tag
            menu.addItem(entry)
        }
        if menu.items.map(\.title) != self.menu?.items.map(\.title) {
            self.menu = menu
        }
        if let chosen, let index = self.menu?.items.firstIndex(where: { $0.tag == chosen && !$0.isSeparatorItem }) {
            selectItem(at: index)
        }
    }

    @objc private func chose() {
        if let tag = selectedItem?.tag {
            onChoose?(tag)
        }
    }
}
