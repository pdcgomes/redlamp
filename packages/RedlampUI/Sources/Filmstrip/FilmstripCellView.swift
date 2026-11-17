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
    /// The long edge its thumbnail was decoded at (`ThumbnailLoader.longEdge`): smaller than the cells' size asks
    /// for, it's shown until the larger one comes.
    private(set) var shownLongEdge = 0
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

    /// A photo left in Apple Photos that Photos has no thumbnail of without iCloud (LIB-59): marked with the cloud,
    /// as a photo only in iCloud Drive is.
    var isInCloud: Bool {
        get { badges.isInCloud }
        set { badges.isInCloud = newValue }
    }

    /// A click, with the modifier keys held (⌘ and ⇧ select several photos): VoiceOver's press.
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    /// A press on the cell, with the modifier keys held, and the drag and release that follow it, which the strip
    /// makes a click or a drag of photos (`FilmstripStripView+Drag`).
    var onPress: ((NSEvent) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onRelease: ((NSEvent) -> Void)?
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

    /// Ringed while photos dragged over it would move to its place in their open stack.
    var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
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

    /// Shows `item`; `image` is its thumbnail if already in memory, showing `edit`, decoded at `longEdge`.
    func configure(_ item: LibraryItem, image: CGImage?, edit: EditDigest? = nil, longEdge: Int = 0) {
        let changedPhoto = item.url != self.item?.url
        self.item = item
        if changedPhoto || image != nil {
            setImage(image, edit: edit, longEdge: longEdge)
        }
        if changedPhoto {
            isMenuTarget = false
            isDropTarget = false
        }
        badges.item = item
        badges.hasImage = thumbnail.contents != nil
        badges.uneditedPreview = showsUneditedPreview
        // Only the photo dims: a reject's mark keeps its strength, to read on a light photo.
        thumbnail.opacity = item.metadata.flag == .reject ? 0.45 : 1
        setAccessibilityLabel(item.title)
        setAccessibilityIdentifier("filmstrip.\(item.accessibilityName)")
        describe()
    }

    /// The tooltip and what VoiceOver reads after the name, as the grid's cells say them.
    private func describe() {
        let suggested = isFocusSuggested ? "suggested for a focus stack" : nil
        toolTip = [item?.title, suggested].compactMap(\.self).joined(separator: ", ")
        setAccessibilityValue(suggested)
    }

    func setImage(_ image: CGImage?, edit: EditDigest? = nil, longEdge: Int = 0) {
        thumbnail.contents = image
        shownEdit = image == nil ? nil : edit
        shownLongEdge = image == nil ? 0 : longEdge
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

    /// The tile and its edge as the grid's cells have theirs, in the theme's colours.
    private func updateBackground() {
        background.backgroundColor = isSelected ? LibraryLook.activeTile : isInSelection ? LibraryLook.selectedTile
            : LibraryLook.tile
        if isMenuTarget || isDropTarget {
            background.borderWidth = 2
            background.borderColor = LibraryLook.ring
        } else {
            background.borderWidth = isSelected ? 1.5 : isInSelection ? 1 : 0
            background.borderColor = isSelected ? LibraryLook.activeEdge : LibraryLook.selectedEdge
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
        onPress?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) {
        onRelease?(event)
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

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick([])
        return true
    }
}

/// The cell's badges: edited, flag or reject, stars, colour or custom label, the mark, focus stack or a focus stack
/// suggested, a stack's count and a pair's extensions (LIB-28), a version's mark (LIB-48), and a cloud for photos only
/// in iCloud Drive, and those left in Apple Photos that Photos has no thumbnail of without iCloud (LIB-59).
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
            guard hasImage != oldValue, item?.isLocal == false || isInCloud else { return }
            setNeedsContentDisplay()
        }
    }

    var isInCloud = false {
        didSet {
            guard isInCloud != oldValue else { return }
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
        var version = false
    }

    private func badges(_ item: LibraryItem?) -> Badges? {
        item.map {
            Badges(
                edited: $0.hasEdits,
                metadata: $0.metadata,
                stack: SupportedFormats.isStack($0.url),
                cloud: !$0.isLocal,
                version: $0.version != nil,
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
        // The grid's, on its disc, which reads on a light photo as well as a dark one.
        if let flag = badges.metadata.flag, let image = GridBadges.image(GridBadges.Kind(flag), scale: scale) {
            drawUpright(image, in: CGRect(x: 1, y: 1, width: 16, height: 16), context)
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
        if badges.version, let image = GridBadges.image(.version, scale: scale) {
            drawUpright(image, in: CGRect(x: 4, y: rect.height - 33, width: 16, height: 16), context)
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
        if badges.cloud || isInCloud, !hasImage {
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
