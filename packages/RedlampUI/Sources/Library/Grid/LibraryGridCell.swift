import AppKit
import QuartzCore
import RedlampDocument

/// A grid cell: the thumbnail is a layer's contents, composited by Core Animation, and the badges are the
/// filmstrip's, drawn only when they change. Cells are reused as the grid scrolls; `configure` rebinds one
/// to another photo.
final class LibraryGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("LibraryGridItem")

    var cell: LibraryGridCellView {
        view as! LibraryGridCellView // swiftlint:disable:this force_cast
    }

    /// The thumbnail request this cell is waiting on.
    var request: UInt64?

    override func loadView() {
        view = LibraryGridCellView(frame: CGRect(origin: .zero, size: LibraryGridLayout.cellSize))
    }
}

final class LibraryGridCellView: NSView {
    private static let inset: CGFloat = 9

    private(set) var item: LibraryItem?
    /// A click, with the modifier keys held (⌘ and ⇧ select several photos).
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    /// A double-click: the photo in the loupe.
    var onOpen: (() -> Void)?
    private let background = CALayer()
    private let thumbnail = CALayer()
    private let badges = FilmstripBadgesView()

    /// The active photo.
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            updateBackground()
        }
    }

    /// Selected with the active photo.
    var isInSelection = false {
        didSet {
            guard isInSelection != oldValue else { return }
            updateBackground()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        background.cornerRadius = 4
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
        setAccessibilityIdentifier("grid.\(item.url.lastPathComponent)")
    }

    func setImage(_ image: CGImage?) {
        thumbnail.contents = image
        badges.hasImage = image != nil
    }

    var image: CGImage? {
        thumbnail.contents.map { $0 as! CGImage } // swiftlint:disable:this force_cast
    }

    private func updateBackground() {
        background.backgroundColor = NSColor(white: isSelected ? 0.3 : isInSelection ? 0.24 : 0.17, alpha: 1).cgColor
        background.borderWidth = isSelected ? 1.5 : isInSelection ? 1 : 0
        background.borderColor = NSColor(white: 1, alpha: isSelected ? 0.85 : 0.4).cgColor
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

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onOpen?()
        } else {
            onClick?(event.modifierFlags)
        }
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?([])
        return true
    }
}
