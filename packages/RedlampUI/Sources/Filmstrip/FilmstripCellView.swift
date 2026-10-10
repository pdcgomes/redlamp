import AppKit
import QuartzCore
import RedlampDesign
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary

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
    /// The edit its thumbnail shows, nil for the photo's embedded preview.
    private(set) var shownEdit: EditDigest?
    /// The library renders the photo's edit (LIB-17), so its embedded preview is marked until then.
    var rendersEdit = false {
        didSet { badges.uneditedPreview = showsUneditedPreview }
    }

    /// What the cell shows of the stacks it's the first cell of (LIB-28), as the grid's cells do.
    var stackBadges: (count: GridBadges.Kind?, pair: GridBadges.Kind?) {
        get { badges.stackBadges }
        set { badges.stackBadges = newValue }
    }

    /// A frame of a focus stack the app suggests merging (LIB-28), marked as the grid's cells mark it.
    var isFocusSuggested = false {
        didSet {
            guard isFocusSuggested != oldValue else { return }
            badges.isFocusSuggested = isFocusSuggested
            describe()
        }
    }

    /// A click, with the modifier keys held (⌘ and ⇧ select several photos).
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    /// The photo's context menu (`FilmstripMenu`).
    var onMenu: (() -> NSMenu?)?
    private let background = CALayer()
    private let thumbnail = CALayer()
    private let badges = FilmstripBadgesView()

    /// The active photo: the one open.
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            updateBackground()
        }
    }

    /// Selected with the active photo, for Sync and Paste.
    var isInSelection = false {
        didSet {
            guard isInSelection != oldValue else { return }
            updateBackground()
        }
    }

    /// Ringed while its context menu is open: the photo the menu acts on.
    private(set) var isMenuTarget = false {
        didSet {
            guard isMenuTarget != oldValue else { return }
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

    /// Shows `item`; `image` is its thumbnail if already in memory, showing `edit`.
    func configure(_ item: LibraryItem, image: CGImage?, edit: EditDigest? = nil) {
        let changedPhoto = item.url != self.item?.url
        self.item = item
        if changedPhoto || image != nil {
            setImage(image, edit: edit)
        }
        if changedPhoto {
            isMenuTarget = false
        }
        badges.item = item
        badges.hasImage = thumbnail.contents != nil
        badges.uneditedPreview = showsUneditedPreview
        layer?.opacity = item.metadata.flag == .reject ? 0.45 : 1
        setAccessibilityLabel(item.name)
        setAccessibilityIdentifier("filmstrip.\(item.url.lastPathComponent)")
        describe()
    }

    /// The tooltip and what VoiceOver reads after the name, as the grid's cells say them.
    private func describe() {
        let suggested = isFocusSuggested ? "suggested for a focus stack" : nil
        toolTip = [item?.name, suggested].compactMap(\.self).joined(separator: ", ")
        setAccessibilityValue(suggested)
    }

    func setImage(_ image: CGImage?, edit: EditDigest? = nil) {
        thumbnail.contents = image
        shownEdit = image == nil ? nil : edit
        badges.hasImage = image != nil
        badges.uneditedPreview = showsUneditedPreview
    }

    var image: CGImage? {
        thumbnail.contents.map { $0 as! CGImage } // swiftlint:disable:this force_cast
    }

    /// An edited photo the library renders shows its embedded preview, and is marked so.
    var showsUneditedPreview: Bool {
        item?.hasEdits == true && rendersEdit && shownEdit == nil
    }

    private func updateBackground() {
        background.backgroundColor = NSColor(white: isSelected ? 0.22 : isInSelection ? 0.19 : 0.14, alpha: 1).cgColor
        if isMenuTarget {
            background.borderWidth = 2
            background.borderColor = Palette.accent.cgColor
        } else {
            background.borderWidth = isSelected ? 1.5 : isInSelection ? 1 : 0
            background.borderColor = NSColor(white: 1, alpha: isSelected ? 0.85 : 0.4).cgColor
        }
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
        // Control-click is a right-click, not a click with a modifier.
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        onClick?(event.modifierFlags)
    }

    override func menu(for _: NSEvent) -> NSMenu? {
        onMenu?()
    }

    override func willOpenMenu(_: NSMenu, with _: NSEvent) {
        isMenuTarget = true
    }

    override func didCloseMenu(_: NSMenu, with _: NSEvent?) {
        isMenuTarget = false
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    /// VoiceOver's Show Menu: the same menu, under the photo.
    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = onMenu?() else { return false }
        isMenuTarget = true
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: bounds.height), in: self)
        isMenuTarget = false
        return true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }
}

/// The cell's badges: edited, flag or reject, stars, colour or custom label, the mark, focus stack or a focus stack
/// suggested, a stack's count and a pair's extensions (LIB-28), and a cloud for photos only in iCloud Drive.
final class FilmstripBadgesView: LayerDrawnView {
    var item: LibraryItem? {
        didSet {
            guard badges(item) != badges(oldValue) else { return }
            setNeedsContentDisplay()
        }
    }

    var stackBadges: (count: GridBadges.Kind?, pair: GridBadges.Kind?) = (nil, nil) {
        didSet {
            guard stackBadges.count != oldValue.count || stackBadges.pair != oldValue.pair else { return }
            setNeedsContentDisplay()
        }
    }

    var isFocusSuggested = false {
        didSet {
            guard isFocusSuggested != oldValue else { return }
            setNeedsContentDisplay()
        }
    }

    var hasImage = false {
        didSet {
            guard hasImage != oldValue, item?.isLocal == false else { return }
            setNeedsContentDisplay()
        }
    }

    /// The edited badge marks the embedded preview showing until the edit is rendered (LIB-17).
    var uneditedPreview = false {
        didSet {
            guard uneditedPreview != oldValue, item?.hasEdits == true else { return }
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
        if let colour = GridBadges.color(of: badges.metadata) {
            context.setFillColor(colour.cgColor)
            let bar = CGRect(x: 6, y: 2, width: rect.width - 12, height: 3)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.fillPath()
        }
        // The grid's image of it, round, so the flipped context draws it as it is.
        if badges.metadata.mark, let mark = GridBadges.image(.mark, scale: scale) {
            context.draw(mark, in: CGRect(x: rect.width - 17, y: 1, width: 16, height: 16))
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
        // A focus stack suggested takes a stack document's place, as in the grid.
        let suggested = !badges.stack && isFocusSuggested
        if badges.stack {
            Symbol.draw(
                "square.stack.3d.down.right.fill", pointSize: 8, color: white.opacity(0.85),
                centeredAt: CGPoint(x: rect.width - 25, y: 9), scale: scale,
            )
        } else if suggested, let image = GridBadges.image(.focusSuggestion, scale: scale) {
            drawUpright(image, in: CGRect(x: rect.width - 33, y: 1, width: 16, height: 16), context)
        }
        if let count = stackBadges.count, let image = GridBadges.image(count, scale: scale) {
            let right = rect.width - (badges.stack || suggested ? 34 : 18)
            drawUpright(
                image,
                in: CGRect(origin: CGPoint(x: right - count.size.width, y: 2), size: count.size),
                context,
            )
        }
        if let pair = stackBadges.pair, let image = GridBadges.image(pair, scale: scale) {
            drawUpright(image, in: CGRect(origin: CGPoint(x: 18, y: 2), size: pair.size), context)
        }
        if badges.edited {
            let circle = CGRect(x: rect.width - 22, y: rect.height - 22, width: 16, height: 16)
            context.setFillColor(shade.cgColor)
            context.fillEllipse(in: circle)
            Symbol.draw(
                uneditedPreview ? "ellipsis" : "slider.horizontal.3", pointSize: 8,
                weight: uneditedPreview ? .bold : .semibold, color: white.opacity(0.85),
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

    /// Draws one of the grid's images, made right way up, in this flipped context.
    private func drawUpright(_ image: CGImage, in frame: CGRect, _ context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: frame.minY + frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: frame)
        context.restoreGState()
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
