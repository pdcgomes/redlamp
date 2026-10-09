import AppKit
import QuartzCore
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary

/// A grid cell: layers only, no view, so a cell scrolling into view sets a few layers' frames and contents
/// and AppKit has no view to add, lay out, track or describe. The thumbnail and the text of an expanded
/// cell are images made off the main thread; the badges are images shared by every cell
/// (`GridBadges`), each in its own layer at its own place, kept for clicking them.
@MainActor
final class LibraryGridCell {
    let root = CALayer()
    private let background = CALayer()
    private let thumbnail = CALayer()
    private var text: CALayer?
    private var label: CALayer?
    /// An expanded cell's colour label chip, to click.
    private var chip: CALayer?
    private var badges: [Badge: CALayer] = [:]

    private enum Badge: Hashable {
        case flag, stack, edited, rating, cloud, mark, stackCount, pairText, proposal
    }

    /// The dashed frame of a photo a Library Health check's batch acts on (LIB-40).
    private var proposalFrame: CAShapeLayer?

    /// What the Library Health check shown proposes for the photo, and found in it (LIB-40): a pill over the
    /// thumbnail, and a dashed frame around it when the check's batch acts on it, in every style and size.
    var healthMark: HealthMark? {
        didSet {
            if healthMark != oldValue {
                showBadges(of: item)
            }
        }
    }

    /// A frame of a focus stack the app suggests merging (LIB-28).
    var isFocusSuggested = false {
        didSet {
            if isFocusSuggested != oldValue {
                showBadges(of: item)
            }
        }
    }

    /// What the cell shows of the stacks it's the first cell of (LIB-28): a burst's or a stack made by hand's
    /// count, and a raw and its JPEG's other extensions.
    var stackBadges: (count: GridBadges.Kind?, pair: GridBadges.Kind?) = (nil, nil) {
        didSet {
            if stackBadges.count != oldValue.count || stackBadges.pair != oldValue.pair {
                showBadges(of: item)
            }
        }
    }

    /// The row it shows.
    var row = -1
    private(set) var item: LibraryItem?
    /// The thumbnail request it's waiting on, and the edge it asked for.
    var request: UInt64?
    private(set) var edge = 0
    /// The edit its thumbnail shows, nil for the photo's embedded preview.
    private(set) var shownEdit: EditDigest?
    /// The library renders the photo's edit (LIB-17), so its embedded preview is marked until then.
    var rendersEdit = false {
        didSet {
            if rendersEdit != oldValue {
                showBadges(of: item)
            }
        }
    }

    /// What its text image shows.
    var textKey: GridText.Key?

    private(set) var geometry = GridCellGeometry(size: CGFloat(GridSize.standard), style: .compact)
    private var scale: CGFloat = 2

    /// The active photo.
    private(set) var isActive = false
    /// Selected with the active photo.
    private(set) var isInSelection = false
    /// Its context menu is open.
    var isMenuTarget = false {
        didSet {
            if isMenuTarget != oldValue {
                updateBackground()
            }
        }
    }

    /// A keyword dragged over it would tag it, or the painter has painted it in the stroke under way.
    var isDropTarget = false {
        didSet {
            if isDropTarget != oldValue {
                updateBackground()
            }
        }
    }

    init() {
        background.cornerRadius = 4
        thumbnail.contentsGravity = .resizeAspect
        for layer in [root, background, thumbnail] {
            layer.actions = Self.noActions
        }
        root.addSublayer(background)
        root.addSublayer(thumbnail)
        updateBackground()
    }

    static let noActions: [String: any CAAction] = [
        "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "hidden": NSNull(),
        "backgroundColor": NSNull(), "borderWidth": NSNull(), "borderColor": NSNull(), "frame": NSNull(),
    ]

    var image: CGImage? {
        thumbnail.contents.map { $0 as! CGImage } // swiftlint:disable:this force_cast
    }

    /// An expanded cell's text as shown, for the tests.
    var textImage: CGImage? {
        guard let text, !text.isHidden else { return nil }
        return text.contents.map { $0 as! CGImage } // swiftlint:disable:this force_cast
    }

    /// The badges shown, for the tests.
    var badgesShown: Int {
        badges.values.count { !$0.isHidden } + (label?.isHidden == false ? 1 : 0)
    }

    /// An edited photo the library renders shows its embedded preview, and is marked so.
    var showsUneditedPreview: Bool {
        item?.hasEdits == true && rendersEdit && shownEdit == nil
    }

    /// Lays the cell out at `frame` for `geometry`, on a screen of `scale`.
    func place(_ frame: CGRect, geometry: GridCellGeometry, scale: CGFloat) {
        root.frame = frame
        guard geometry != self.geometry || scale != self.scale || background.frame.size != frame.size else { return }
        self.geometry = geometry
        self.scale = scale
        background.frame = CGRect(origin: .zero, size: frame.size)
        thumbnail.frame = geometry.image
        for layer in [root, background, thumbnail] + Array(badges.values)
            + [text, label, chip, proposalFrame].compactMap(\.self) {
            layer.contentsScale = scale
        }
        if let item {
            showBadges(of: item)
        }
    }

    /// Shows `item` in row `row`; `image` is its thumbnail if it's in memory, showing `edit`.
    func configure(_ item: LibraryItem, row: Int, image: CGImage?, edge: Int, edit: EditDigest? = nil) {
        let changedPhoto = item.url != self.item?.url || row != self.row
        self.item = item
        self.row = row
        if changedPhoto || image != nil {
            setImage(image, edge: image == nil ? 0 : edge, edit: edit)
        }
        if changedPhoto {
            text?.contents = nil
            textKey = nil
            isMenuTarget = false
            isDropTarget = false
        }
        root.opacity = item.metadata.flag == .reject ? 0.45 : 1
        showBadges(of: item)
    }

    func setImage(_ image: CGImage?, edge: Int, edit: EditDigest? = nil) {
        thumbnail.contents = image
        self.edge = edge
        let marked = showsUneditedPreview
        shownEdit = image == nil ? nil : edit
        if item?.isLocal == false || showsUneditedPreview != marked {
            showBadges(of: item)
        }
    }

    func setText(_ image: CGImage?, for key: GridText.Key) {
        guard geometry.style == .expanded else { return }
        let layer = text ?? makeLayer { text = $0 }
        layer.frame = geometry.text
        layer.contents = image
        layer.isHidden = image == nil
        textKey = key
    }

    func select(active: Bool, inSelection: Bool) {
        guard active != isActive || inSelection != isInSelection else { return }
        isActive = active
        isInSelection = inSelection
        updateBackground()
    }

    /// Out of sight, waiting to show another photo.
    func recycle() {
        root.isHidden = true
        item = nil
        row = -1
        stackBadges = (nil, nil)
        healthMark = nil
    }

    /// The proposal badge shown, for the tests.
    var proposalShown: GridBadges.Kind? {
        guard let layer = badges[.proposal], !layer.isHidden, let healthMark else { return nil }
        return GridBadges.proposal(healthMark, width: geometry.image.width)
    }

    /// The proposal badge's frame in the cell and the dashed frame's, while they're shown, for the tests.
    var proposalFrames: (badge: CGRect, frame: CGRect?)? {
        guard let layer = badges[.proposal], !layer.isHidden else { return nil }
        return (layer.frame, proposalFrame?.isHidden == false ? proposalFrame?.path?.boundingBoxOfPath : nil)
    }

    /// The stack badge at `point`, in the cell: whether it's a raw and its JPEG's rather than a stack's count; nil
    /// for none.
    func stackBadge(at point: CGPoint) -> Bool? {
        for (badge, pair) in [(Badge.stackCount, false), (.pairText, true)] {
            if let layer = badges[badge], !layer.isHidden, layer.frame.insetBy(dx: -3, dy: -3).contains(point) {
                return pair
            }
        }
        return nil
    }

    private func updateBackground() {
        background.backgroundColor = NSColor(white: isActive ? 0.3 : isInSelection ? 0.24 : 0.17, alpha: 1).cgColor
        if isMenuTarget || isDropTarget {
            background.borderWidth = 2
            background.borderColor = NSColor.controlAccentColor.cgColor
        } else {
            background.borderWidth = isActive ? 1.5 : isInSelection ? 1 : 0
            background.borderColor = NSColor(white: 1, alpha: isActive ? 0.85 : 0.4).cgColor
        }
    }

    // MARK: - Badges

    /// An expanded cell shows a place for each badge a click sets, lit or not.
    private func showBadges(of item: LibraryItem?) {
        let shows = geometry.style != .none
        let slots = geometry.style == .expanded && item != nil
        let metadata = item?.metadata ?? PhotoMetadata()
        let flag: GridBadges.Kind? = switch metadata.flag {
        case .pick: .pick
        case .reject: .reject
        case nil: slots ? .flagSlot : nil
        }
        set(.flag, shows ? flag : nil, centre: geometry.flag)
        let document = item.map { SupportedFormats.isStack($0.url) } == true
        set(
            .stack,
            shows && document ? .stack : shows && isFocusSuggested ? .focusSuggestion : nil,
            centre: geometry.stack,
        )
        set(.mark, shows && metadata.mark ? .mark : slots ? .markSlot : nil, centre: geometry.mark)
        let edited: GridBadges.Kind = showsUneditedPreview ? .uneditedPreview : .edited
        set(.edited, shows && item?.hasEdits == true ? edited : nil, centre: geometry.edited)
        let rating: GridBadges.Kind? = slots ? .ratingSlots(metadata.rating)
            : shows && metadata.rating > 0 ? .rating(metadata.rating) : nil
        set(.rating, rating, left: geometry.rating)
        set(.cloud, item?.isLocal == false && thumbnail.contents == nil ? .cloud : nil, centre: CGPoint(
            x: geometry.image.midX, y: geometry.image.midY,
        ))
        showStackBadges(besideDocument: shows && badges[.stack]?.isHidden == false)
        showProposal()
        let colour = GridBadges.color(of: metadata)
        if shows, let colour {
            let layer = label ?? makeLayer { label = $0 }
            layer.frame = geometry.label
            layer.cornerRadius = 1.5
            layer.backgroundColor = colour.cgColor
            layer.isHidden = false
        } else {
            label?.isHidden = true
        }
        if slots, let frame = geometry.labelChip {
            let layer = chip ?? makeLayer { chip = $0 }
            layer.frame = frame
            layer.cornerRadius = 2.5
            layer.backgroundColor = colour?.cgColor
            layer.borderWidth = colour == nil ? 1 : 0
            layer.borderColor = NSColor(white: 1, alpha: 0.3).cgColor
            layer.isHidden = false
        } else {
            chip?.isHidden = true
        }
        text?.isHidden = geometry.style != .expanded || text?.contents == nil
    }

    /// A stack's count and a pair's extensions, shown in every style, since a cell standing for several photos
    /// acts on them all: in a compact cell along its top, the count left of the mark (and of a focus stack's
    /// badge, `besideDocument`) and the extensions right of the flag; over an expanded cell's thumbnail's top left
    /// corner, side by side.
    private func showStackBadges(besideDocument: Bool) {
        let (count, pair) = stackBadges
        guard item != nil else {
            set(.stackCount, nil)
            set(.pairText, nil)
            return
        }
        if geometry.style == .expanded {
            let image = geometry.image
            let countWidth = count.map { $0.size.width + 3 } ?? 0
            set(.stackCount, count, left: CGPoint(x: image.minX + 3, y: image.minY + 10))
            set(.pairText, pair, left: CGPoint(x: image.minX + 3 + countWidth, y: image.minY + 10))
        } else {
            let right = geometry.size - (besideDocument ? 34 : 18)
            set(.stackCount, count, left: CGPoint(x: right - (count?.size.width ?? 0), y: 9))
            set(.pairText, pair, left: CGPoint(x: 18, y: 9))
        }
    }

    /// A Library Health check's proposal, in every style, as the photo's decision is what its list is for: the pill
    /// over the thumbnail's middle, or in an expanded cell along its bottom, clear of the badges in its corners; and
    /// the dashed frame just outside the thumbnail, inside the selection's outline.
    private func showProposal() {
        guard let healthMark, item != nil else {
            set(.proposal, nil)
            proposalFrame?.isHidden = true
            return
        }
        let image = geometry.image
        let kind = GridBadges.proposal(healthMark, width: image.width)
        let centre = geometry.style == .expanded
            ? CGPoint(x: image.midX, y: image.maxY - kind.size.height / 2 - 4)
            : CGPoint(x: image.midX, y: image.midY)
        set(.proposal, kind, centre: centre)
        guard healthMark.isFramed else {
            proposalFrame?.isHidden = true
            return
        }
        let frame = proposalFrame ?? makeProposalFrame()
        let outline = image.insetBy(dx: -2.5, dy: -2.5)
        if frame.path?.boundingBoxOfPath != outline {
            frame.path = CGPath(roundedRect: outline, cornerWidth: 3, cornerHeight: 3, transform: nil)
        }
        frame.strokeColor = GridBadges.frameColor(of: healthMark.proposal)
        frame.isHidden = false
    }

    private func makeProposalFrame() -> CAShapeLayer {
        let frame = CAShapeLayer()
        frame.actions = Self.noActions.merging(["path": NSNull(), "strokeColor": NSNull()]) { first, _ in first }
        frame.fillColor = nil
        frame.lineWidth = 1.5
        frame.lineDashPattern = [4, 3]
        frame.contentsScale = scale
        root.insertSublayer(frame, above: thumbnail)
        proposalFrame = frame
        return frame
    }

    private func set(_ badge: Badge, _ kind: GridBadges.Kind?, centre: CGPoint? = nil, left: CGPoint? = nil) {
        guard let kind else {
            badges[badge]?.isHidden = true
            return
        }
        let layer = badges[badge] ?? makeLayer { badges[badge] = $0 }
        let size = kind.size
        let origin = centre.map { CGPoint(x: $0.x - size.width / 2, y: $0.y - size.height / 2) }
            ?? left.map { CGPoint(x: $0.x, y: $0.y - size.height / 2) } ?? .zero
        layer.frame = CGRect(origin: origin, size: size)
        layer.contents = GridBadges.image(kind, scale: scale)
        layer.isHidden = false
    }

    private func makeLayer(_ keep: (CALayer) -> Void) -> CALayer {
        let layer = CALayer()
        layer.actions = Self.noActions
        layer.contentsScale = scale
        root.addSublayer(layer)
        keep(layer)
        return layer
    }
}
