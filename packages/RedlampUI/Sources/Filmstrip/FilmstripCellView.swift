import AppKit
import QuartzCore
import RedlampDesign
import RedlampDocument
import RedlampEngineAPI

/// A filmstrip cell: the thumbnail is a layer's contents, composited by Core Animation, and the
/// badges are drawn into their own layer only when they change. Cells are reused as the strip
/// scrolls; `configure` rebinds one to another photo.
final class FilmstripItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FilmstripItem")

    var cell: FilmstripCellView {
        view as! FilmstripCellView // swiftlint:disable:this force_cast
    }

    /// The thumbnail request this cell is waiting on.
    var request: UInt64?

    override func loadView() {
        view = FilmstripCellView(frame: CGRect(origin: .zero, size: FilmstripCellView.size))
    }
}

final class FilmstripCellView: NSView {
    static let size = CGSize(width: 96, height: 70)
    private static let inset: CGFloat = 4

    private(set) var item: LibraryItem?
    var onClick: (() -> Void)?
    private let background = CALayer()
    private let thumbnail = CALayer()
    private let badges = FilmstripBadgesView()

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            updateBackground()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        background.cornerRadius = 4
        background.borderColor = NSColor(white: 1, alpha: 0.85).cgColor
        thumbnail.contentsGravity = .resizeAspect
        thumbnail.minificationFilter = .trilinear
        for layer in [background, thumbnail] {
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
            self.layer?.addSublayer(layer)
        }
        addSubview(badges)
        updateBackground()
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

    /// Shows `item`; `image` is its thumbnail if already in memory.
    func configure(_ item: LibraryItem, image: CGImage?) {
        let changedPhoto = item.url != self.item?.url
        self.item = item
        if changedPhoto || image != nil {
            setImage(image)
        }
        badges.item = item
        badges.hasImage = thumbnail.contents != nil
        toolTip = item.name
        layer?.opacity = item.metadata.flag == .reject ? 0.45 : 1
        setAccessibilityLabel(item.name)
    }

    func setImage(_ image: CGImage?) {
        thumbnail.contents = image
        badges.hasImage = image != nil
    }

    var image: CGImage? {
        thumbnail.contents.map { $0 as! CGImage } // swiftlint:disable:this force_cast
    }

    private func updateBackground() {
        background.backgroundColor = NSColor(white: isSelected ? 0.22 : 0.14, alpha: 1).cgColor
        background.borderWidth = isSelected ? 1.5 : 0
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        thumbnail.frame = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        thumbnail.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        badges.frame = bounds
    }

    override func mouseDown(with _: NSEvent) {
        onClick?()
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }
}

/// The cell's badges: edited, flag or reject, stars, colour label, focus stack, and a cloud for
/// photos only in iCloud Drive.
final class FilmstripBadgesView: LayerDrawnView {
    var item: LibraryItem? {
        didSet {
            guard badges(item) != badges(oldValue) else { return }
            setNeedsContentDisplay()
        }
    }

    var hasImage = false {
        didSet {
            guard hasImage != oldValue, item?.isLocal == false else { return }
            setNeedsContentDisplay()
        }
    }

    private struct Badges: Equatable {
        var edited = false
        var metadata = PhotoMetadata()
        var stack = false
        var cloud = false
    }

    private func badges(_ item: LibraryItem?) -> Badges? {
        item.map {
            Badges(
                edited: $0.hasEdits,
                metadata: $0.metadata,
                stack: SupportedFormats.isStack($0.url),
                cloud: !$0.isLocal,
            )
        }
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func drawContent(in rect: CGRect) {
        guard let badges = badges(item), let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        let white = RGBA(white: 1)
        let shade = NSColor(white: 0, alpha: 0.55)
        if let label = badges.metadata.label {
            context.setFillColor(label.nsColor.cgColor)
            let bar = CGRect(x: 6, y: 2, width: rect.width - 12, height: 3)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.fillPath()
        }
        switch badges.metadata.flag {
        case .pick:
            Symbol.draw("flag.fill", pointSize: 8, color: white, centeredAt: CGPoint(x: 9, y: 9), scale: scale)
        case .reject:
            Symbol.draw(
                "xmark", pointSize: 8, weight: .bold, color: white, centeredAt: CGPoint(x: 9, y: 9), scale: scale,
            )
        case nil:
            break
        }
        if badges.stack {
            Symbol.draw(
                "square.stack.3d.down.right.fill", pointSize: 8, color: white.opacity(0.85),
                centeredAt: CGPoint(x: rect.width - 9, y: 9), scale: scale,
            )
        }
        if badges.edited {
            let circle = CGRect(x: rect.width - 22, y: rect.height - 22, width: 16, height: 16)
            context.setFillColor(shade.cgColor)
            context.fillEllipse(in: circle)
            Symbol.draw(
                "slider.horizontal.3", pointSize: 8, weight: .semibold, color: white.opacity(0.85),
                centeredAt: CGPoint(x: circle.midX, y: circle.midY), scale: scale,
            )
        }
        if badges.metadata.rating > 0 {
            let count = CGFloat(badges.metadata.rating)
            let capsule = CGRect(x: 4, y: rect.height - 15, width: 8 + count * 7, height: 11)
            context.setFillColor(shade.cgColor)
            context.addPath(CGPath(roundedRect: capsule, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil))
            context.fillPath()
            for index in 0 ..< badges.metadata.rating {
                Symbol.draw(
                    "star.fill", pointSize: 6, color: white.opacity(0.9),
                    centeredAt: CGPoint(x: capsule.minX + 7.5 + CGFloat(index) * 7, y: capsule.midY), scale: scale,
                )
            }
        }
        if badges.cloud, !hasImage {
            Symbol.draw(
                "icloud.and.arrow.down", pointSize: 14, color: white.opacity(0.6),
                centeredAt: CGPoint(x: rect.midX, y: rect.midY), scale: scale,
            )
        }
    }
}

extension ColorLabel {
    var nsColor: NSColor {
        switch self {
        case .red: NSColor(red: 0.9, green: 0.25, blue: 0.25, alpha: 1)
        case .yellow: NSColor(red: 0.95, green: 0.8, blue: 0.2, alpha: 1)
        case .green: NSColor(red: 0.3, green: 0.8, blue: 0.35, alpha: 1)
        case .blue: NSColor(red: 0.3, green: 0.5, blue: 0.95, alpha: 1)
        case .purple: NSColor(red: 0.65, green: 0.4, blue: 0.9, alpha: 1)
        }
    }
}
