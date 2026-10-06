import AppKit
import QuartzCore
import RedlampDesign
import RedlampDocument

/// The Library loupe (E): the active photo large, from its thumbnail at once and its screen-size preview once
/// that's decoded. It reads nothing while it isn't shown. LIB-16 adds zoom, Compare and Survey.
final class LibraryLoupeView: NSView {
    private static let inset: CGFloat = 20

    private let model: EditorModel
    private let photo = CALayer()
    private let caption = NSTextField(labelWithString: "")
    private var tracker: Tracker?
    /// The photo shown, and whether its preview is in.
    private var shown: URL?
    private(set) var showsPreview = false

    init(model: EditorModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        photo.contentsGravity = .resizeAspect
        photo.minificationFilter = .trilinear
        photo.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(photo)
        caption.font = Typography.caption.nsFont
        caption.textColor = Palette.secondaryLabel.nsColor
        caption.lineBreakMode = .byTruncatingMiddle
        addSubview(caption)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("library.loupe")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {}

    /// The image on screen, for the tests.
    var image: CGImage? {
        photo.contents.map { $0 as! CGImage } // swiftlint:disable:this force_cast
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            let selection = model.selection
            guard model.module == .library, model.libraryView == .loupe else { return }
            show(selection)
        }
    }

    private func show(_ url: URL?) {
        guard url != shown else { return }
        shown = url
        showsPreview = false
        guard let url, let item = model.library.item(for: url) else {
            photo.contents = nil
            caption.stringValue = ""
            setAccessibilityLabel(nil)
            return
        }
        caption.stringValue = item.name
        setAccessibilityLabel(item.name)
        if let preview = model.previews.cached(url) {
            photo.contents = preview
            showsPreview = true
            return
        }
        photo.contents = model.thumbnailLoader.cached(item)
        if photo.contents == nil {
            model.thumbnailLoader.request(item) { [weak self] image in
                guard let self, shown == url, !showsPreview, let image else { return }
                photo.contents = image
            }
        }
        model.previews.request(item) { [weak self] preview in
            guard let self, shown == url, let preview else { return }
            photo.contents = preview
            showsPreview = true
        }
    }

    override func layout() {
        super.layout()
        let height = caption.intrinsicContentSize.height
        caption.frame = CGRect(x: Self.inset, y: 8, width: max(bounds.width - Self.inset * 2, 0), height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.frame = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        photo.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
}
