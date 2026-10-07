import AppKit
import RedlampDesign

/// A folder's count at the end of its row in the Folders panel, drawn as a line of text in digits all as
/// wide: a new count redraws this view alone, and lays out its row again only when it's wider or narrower.
/// The library's counts change while folders are indexed and photos come and go, rows at a time.
final class FolderCountView: LayerDrawnView {
    static let font = FontSpec(size: Typography.caption.size, monospacedDigits: true)

    var text: String {
        didSet {
            guard text != oldValue else { return }
            setNeedsContentDisplay()
            let width = TextLine.width(text, font: Self.font)
            guard width != size.width else { return }
            size.width = width
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
    }

    private var size: CGSize

    init(_ text: String) {
        self.text = text
        size = CGSize(width: TextLine.width(text, font: Self.font), height: TextLine.lineHeight(Self.font))
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        size
    }

    override func drawContent(in _: CGRect) {
        TextLine.draw(
            text, font: Self.font, color: Palette.tertiaryLabel.nsColor, in: bounds, alignment: .right,
            scale: backingScale,
        )
    }
}
