import AppKit
import RedlampDesign

/// An SF Symbol drawn in the frame SwiftUI gives it, at the image's full size; `NSImageView`
/// fits it to its (smaller) alignment rect. Clickable when given an action, as a plain
/// SwiftUI button would be.
final class SymbolImageView: LayerDrawnView {
    private let image: NSImage
    private let size: CGSize
    private let color: NSColor
    var onClick: (() -> Void)?
    var isEnabled = true {
        didSet { setNeedsContentDisplay() }
    }

    init(_ name: String, pointSize: CGFloat, weight: FontSpec.Weight = .regular, color: NSColor) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight.nsWeight))
            ?? NSImage()
        size = Symbol.layoutSize(name, pointSize: pointSize, weight: weight)
        self.color = color
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        size
    }

    override func drawContent(in _: CGRect) {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let tinted = image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [resolved.withAlphaComponent(1)]),
        ) ?? image
        Symbol.draw(tinted, in: bounds, alpha: resolved.alphaComponent * (isEnabled ? 1 : 0.5))
    }

    override func mouseDown(with _: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }
}
