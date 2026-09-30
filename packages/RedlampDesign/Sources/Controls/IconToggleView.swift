import AppKit

/// A small borderless icon button that shows an "on" state with the accent color and a
/// selection fill (the White Balance eyedropper).
public final class IconToggleView: NSView {
    public var isOn = false {
        didSet {
            if isOn != oldValue {
                needsDisplay = true
            }
        }
    }

    public var isEnabled = true {
        didSet {
            if isEnabled != oldValue {
                alphaValue = isEnabled ? 1 : 0.35
            }
        }
    }

    public var onClick: @MainActor () -> Void = {}

    private let symbol: String
    private let size: CGSize

    public init(symbol: String, size: CGSize = CGSize(width: 22, height: 20)) {
        self.symbol = symbol
        self.size = size
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public var isFlipped: Bool {
        true
    }

    override public var intrinsicContentSize: NSSize {
        size
    }

    override public func draw(_: NSRect) {
        if isOn {
            Palette.selection.nsColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let color = isOn ? Palette.accent : Palette.label.nsColor
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color])),
            )
        else { return }
        let imageSize = image.size
        image.draw(in: CGRect(
            x: (bounds.width - imageSize.width) / 2,
            y: (bounds.height - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height,
        ))
    }

    override public func mouseDown(with _: NSEvent) {
        guard isEnabled else { return }
        onClick()
    }
}
